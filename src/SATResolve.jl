# This file is a part of Julia. License is MIT: https://julialang.org/license

# Adapter between the dependency graph that `Operations.deps_graph` produces
# and the exact SAT-based resolver from Resolver.jl. This is Pkg's default
# resolver; the legacy maxsum resolver is selected with JULIA_PKG_RESOLVER=maxsum.
module SATResolve

import ..Resolver
import ..Resolver.Diagnostics
using UUIDs
import ..Registry, ..Types
using ..Versions: VersionSpec, VersionRange
using ..Resolve: ResolverError, Fixed, Requires, pkgID, range_compressed_versionspec

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
const JULIA_NAME = "julia"

const DepsCompressed = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}
const CompatCompressed = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}

const PkgData = Resolver.PkgData{
    UUID, VersionNumber, VersionSpec,
    Vector{VersionNumber},
    Dict{VersionNumber, Vector{UUID}},
    Dict{VersionNumber, Dict{UUID, VersionSpec}},
}

# The resolver is run on packages keyed by their display names (see
# `display_names`) rather than by UUID: its report shows them anyway, and with
# a single package type its code is compiled into Pkg's image once rather than
# again for the report.
const NamedPkgData = Resolver.PkgData{
    String, VersionNumber, VersionSpec,
    Vector{VersionNumber},
    Dict{VersionNumber, Vector{String}},
    Dict{VersionNumber, Dict{String, VersionSpec}},
}

# Convert `deps_graph` output into Resolver.jl's `PkgData` representation.
# Only the strong-dependency closure of the requirements is built: a package
# reachable through weak edges alone can never be installed, so the compat
# entries pointing at it are vacuous and Resolver.jl ignores constraints on
# packages it does not know. Version lists are ordered newest-first, which is
# the canonical preference order; the requirement version specs are not baked
# in but passed to the resolver as user constraints, so a failed resolve can
# attribute them. Returns the data dict, the list of required packages and the
# user's version constraints: compat specs and pins.
function build_pkg_data(
        deps_compressed::DepsCompressed,
        compat_compressed::CompatCompressed,
        weak_deps_compressed::DepsCompressed,
        weak_compat_compressed::CompatCompressed,
        pkg_versions::Dict{UUID, Vector{VersionNumber}},
        pkg_versions_per_registry::Dict{UUID, Vector{Set{VersionNumber}}},
        reqs::Requires,
        fixed::Dict{UUID, Fixed},
        julia_version::Union{VersionNumber, Nothing},
        pinned::Dict{UUID, VersionNumber},
    )
    # The requirement version specs, the compat of the projects and the pins
    # are the user's own constraints: they go to the resolver as such, so a
    # failed resolve can attribute them and suggest relaxing them.
    compat = Dict{UUID, VersionSpec}()
    pin = Dict{UUID, VersionNumber}()
    for (u, spec) in reqs
        (u == JULIA_UUID || haskey(fixed, u)) && continue
        if haskey(pinned, u)
            pin[u] = pinned[u]
        else
            compat[u] = spec
        end
    end
    rlist = collect(keys(reqs))
    # The active and workspace projects are fixed packages but not
    # requirements: their deps are already requirements and their compat is
    # the user's, so they are folded into the constraints rather than
    # modelled as packages.
    for (uuid, fx) in fixed
        (uuid == JULIA_UUID || haskey(reqs, uuid)) && continue
        for (q, spec) in fx.requires
            q == JULIA_UUID && julia_version === nothing && continue
            q ∉ fx.weak && push!(rlist, q)
            compat[q] = intersect(get(compat, q, VersionSpec()), spec)
        end
    end
    julia_version === nothing || push!(rlist, JULIA_UUID)
    sort!(unique!(rlist))
    # a constraint that admits everything is no constraint
    filter!(kv -> last(kv) != VersionSpec(), compat)
    for u in keys(pin)
        delete!(compat, u)
    end

    data = Dict{UUID, PkgData}()
    vnmap = Dict{UUID, VersionSpec}()
    reg_result = Dict{UUID, VersionSpec}()
    queue = copy(rlist)
    while !isempty(queue)
        uuid = pop!(queue)
        haskey(data, uuid) && continue
        if uuid == JULIA_UUID
            # julia itself: a required single-version package that julia
            # compat entries resolve against
            data[uuid] = Resolver.PkgData(
                [julia_version],
                Dict(julia_version => UUID[]),
                Dict(julia_version => Dict{UUID, VersionSpec}())
            )
        elseif haskey(fixed, uuid)
            # fixed packages (dev'd, pinned, tracking a repo): a single
            # version whose requirements are dependency edges plus compat
            fx = fixed[uuid]
            strong = sort!(UUID[q for q in keys(fx.requires) if q ∉ fx.weak && q != JULIA_UUID])
            comp_v = Dict{UUID, VersionSpec}()
            for (q, spec) in fx.requires
                q == JULIA_UUID && julia_version === nothing && continue
                comp_v[q] = spec
            end
            data[uuid] = Resolver.PkgData(
                [fx.version], Dict(fx.version => strong), Dict(fx.version => comp_v)
            )
            append!(queue, strong)
        elseif !haskey(pkg_versions, uuid)
            # a dependency the graph knows nothing about (e.g. not installed
            # in offline mode): a package without versions, so that whatever
            # depends on it is uninstallable and the failure gets diagnosed
            data[uuid] = Resolver.PkgData(
                VersionNumber[], Dict{VersionNumber, Vector{UUID}}(),
                Dict{VersionNumber, Dict{UUID, VersionSpec}}()
            )
        else
            vers = sort(pkg_versions[uuid], rev = true)
            deps_list = deps_compressed[uuid]
            compat_list = compat_compressed[uuid]
            weak_deps_list = weak_deps_compressed[uuid]
            weak_compat_list = weak_compat_compressed[uuid]
            versions_per_reg = pkg_versions_per_registry[uuid]
            depends = Dict{VersionNumber, Vector{UUID}}()
            compat_v = Dict{VersionNumber, Dict{UUID, VersionSpec}}()
            for v in vers
                Registry.query_compat_for_version_multi_registry!(
                    vnmap, reg_result, deps_list, compat_list,
                    weak_deps_list, weak_compat_list, versions_per_reg, v
                )
                strong = UUID[]
                comp_v = Dict{UUID, VersionSpec}()
                for (q, spec) in vnmap
                    q == uuid && continue
                    # like the legacy resolver, ignore registry compat on a
                    # non-upgradable stdlib when it excludes the stdlib version
                    # shipped with this julia (see the Resolve.Graph constructor);
                    # the dependency edge itself is kept so the stdlib still
                    # ends up in the manifest deps (#4801)
                    if Types.is_stdlib(q) && !(q in Types.UPGRADABLE_STDLIBS_UUIDS)
                        stdlib_ver = Types.stdlib_version(q, julia_version)
                        if stdlib_ver !== nothing && !isempty(spec) && !(stdlib_ver in spec)
                            spec = VersionSpec()
                        end
                    end
                    if q == JULIA_UUID
                        # julia compat is enforced against the synthetic julia
                        # package; julia_version === nothing means "any julia"
                        julia_version === nothing || (comp_v[q] = spec)
                        continue
                    end
                    comp_v[q] = spec
                    # weak dependencies constrain versions (via compat above)
                    # but do not force installation
                    is_weak = any(Registry.is_weak_dep(wd, v, q) for wd in weak_deps_list)
                    is_weak && continue
                    push!(strong, q)
                    haskey(data, q) || push!(queue, q)
                end
                depends[v] = sort!(strong)
                compat_v[v] = comp_v
            end
            data[uuid] = Resolver.PkgData(vers, depends, compat_v)
        end
    end
    return data, rlist, compat, pin
end

# package priority order for the resolver's lexicographic optimization: by
# name, then UUID
function priority(uuid_to_name::Dict{UUID, String}, uuid_of::Dict{String, UUID})
    return function (p::String)
        u = uuid_of[p]
        return (get(uuid_to_name, u, ""), u)
    end
end

# Version preference: newest first, except that an already-loaded version of a
# package is preferred over everything else (like the legacy resolver). The
# resolver detects packages whose list is already in this order for free, so
# only the packages with a preferred version cost anything.
function version_order(preferred_versions::Dict{UUID, VersionNumber}, uuid_of::Dict{String, UUID})
    isempty(preferred_versions) && return nothing
    return function (p::String)
        pref = get(preferred_versions, uuid_of[p], nothing)
        pref === nothing && return (a::VersionNumber, b::VersionNumber) -> a > b
        return function (a::VersionNumber, b::VersionNumber)
            a == pref && return b != pref
            b == pref && return false
            return a > b
        end
    end
end

function resolve_versions(
        deps_compressed::DepsCompressed,
        compat_compressed::CompatCompressed,
        weak_deps_compressed::DepsCompressed,
        weak_compat_compressed::CompatCompressed,
        pkg_versions::Dict{UUID, Vector{VersionNumber}},
        pkg_versions_per_registry::Dict{UUID, Vector{Set{VersionNumber}}},
        uuid_to_name::Dict{UUID, String},
        reqs::Requires,
        fixed::Dict{UUID, Fixed},
        julia_version::Union{VersionNumber, Nothing},
        preferred_versions::Dict{UUID, VersionNumber};
        pinned::Dict{UUID, VersionNumber} = Dict{UUID, VersionNumber}(),
        diagnose_unsat::Bool = true,
    )
    data, rlist, compat, pin = build_pkg_data(
        deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed,
        pkg_versions, pkg_versions_per_registry, reqs, fixed, julia_version, pinned
    )
    # a requirement whose version spec or pin matches no available version can
    # never resolve; report it directly, with the versions that do exist
    impossible = String[]
    for u in rlist
        (u == JULIA_UUID || haskey(fixed, u)) && continue
        haskey(data, u) || continue
        avail = data[u].versions
        id = pkgID(u, uuid_to_name)
        if isempty(avail)
            push!(impossible, " * $id: no versions are available (they may all be yanked, or filtered by offline mode)")
        elseif haskey(pin, u) && pin[u] ∉ avail
            vers = range_compressed_versionspec(copy(avail))
            push!(impossible, " * $id: pinned at $(pin[u]), which is not available, available versions are: $vers")
        elseif haskey(compat, u) && !any(in(compat[u]), avail)
            vers = range_compressed_versionspec(copy(avail))
            push!(impossible, " * $id: no available version matches the requirement `$(compat[u])`, available versions are: $vers")
        end
    end
    if !isempty(impossible)
        throw(ResolverError(string("Unsatisfiable requirements detected:\n", join(impossible, "\n"))))
    end
    name = display_names(uuid_to_name)
    named_data = Dict{String, NamedPkgData}(name(u) => named(d, name) for (u, d) in data)
    uuid_of = Dict{String, UUID}()
    for u in keys(data)
        n = name(u)
        get!(uuid_of, n, u) == u || error("packages $u and $(uuid_of[n]) have the same display name $n")
    end
    prob = Resolver.Problem(
        String[name(u) for u in rlist];
        compat = Dict{String, VersionSpec}(name(u) => spec for (u, spec) in compat),
        pin = Dict{String, VersionNumber}(name(u) => v for (u, v) in pin),
    )
    ans = Resolver.resolve(
        named_data, prob;
        by = priority(uuid_to_name, uuid_of), order = version_order(preferred_versions, uuid_of),
        diagnose = diagnose_unsat, upstream = diagnose_unsat
    )
    if ans isa Diagnostics.Diagnosis
        report = sprint(show, MIME("text/plain"), without_julia(ans))
        # the report opens with "Unsatisfiable — N conflicts...:"
        throw(ResolverError(replace(report, r"^Unsatisfiable" => "Unsatisfiable requirements detected")))
    elseif ans === nothing
        throw(ResolverError("Unsatisfiable requirements detected"))
    end
    sol = Dict{UUID, VersionNumber}()
    for (n, v) in ans::Dict{String, VersionNumber}
        u = uuid_of[n]
        # match the legacy resolver's output: fixed packages and julia are not returned
        (u == JULIA_UUID || haskey(fixed, u)) && continue
        sol[u] = v
    end
    return sol
end

named(d::PkgData, name) = Resolver.PkgData(
    d.versions,
    Dict{VersionNumber, Vector{String}}(v => String[name(q) for q in qs] for (v, qs) in d.depends),
    Dict{VersionNumber, Dict{String, VersionSpec}}(
        v => Dict{String, VersionSpec}(name(q) => spec for (q, spec) in c) for (v, c) in d.compat
    ),
)

## rendering a diagnosis with package names

# The name a package is known by to the resolver and shown under in its report:
# its name, or `name [uuid8]` when several packages in the graph share it.
function display_names(uuid_to_name::Dict{UUID, String})
    counts = Dict{String, Int}()
    for name in values(uuid_to_name)
        counts[name] = get(counts, name, 0) + 1
    end
    # (julia is shown as `julia`, so a package of that name is not)
    haskey(uuid_to_name, JULIA_UUID) || (counts[JULIA_NAME] = get(counts, JULIA_NAME, 0) + 1)
    return function (u::UUID)
        u == JULIA_UUID && return JULIA_NAME
        name = get(uuid_to_name, u, nothing)
        name === nothing && return pkgID(u, uuid_to_name)
        return counts[name] == 1 ? name : pkgID(u, uuid_to_name)
    end
end

# The synthetic julia requirement is not something the user can act on, so
# fixes that ask to drop it are left out, as is julia itself from the
# versions a fix would allow.
function without_julia(d::Diagnostics.Diagnosis{String, VersionNumber})
    return Diagnostics.Diagnosis(
        [
            Diagnostics.Conflict{String, VersionNumber}(
                    c.reqs, c.lines, c.versions, c.excluded, without_julia(c.fixes),
                    Tuple{Vector{Vector{Diagnostics.Action{String}}}, Vector{Diagnostics.Action{String}}}[
                        (bs, us) for (bs, us) in c.blocks if !any(is_julia_action, us) && !any(b -> any(is_julia_action, b), bs)
                    ],
                    without_julia(c.upstream), c.shadows
                )
                for c in d.conflicts
        ],
        [
            Diagnostics.Alternative{String, VersionNumber}(
                    a.conflicts, a.avoided, [without_julia(m) for m in a.menus]
                )
                for a in d.alternatives if !any(m -> all(f -> any(is_julia_action, f.actions), m), a.menus)
        ],
        d.others
    )
end

is_julia_action(a::Diagnostics.Action{String}) = a.pkg == JULIA_NAME

without_julia(sol::Dict{String, VersionNumber}) = filter(((p, _),) -> p != JULIA_NAME, sol)

without_julia(ups::Vector{Diagnostics.Upstream{String, VersionNumber}}) =
    [
    Diagnostics.Upstream{String, VersionNumber}(
            u.pkg, u.latest, u.dep, u.supports, u.supported, without_julia(u.solution)
        )
        for u in ups
]

without_julia(fixes::Vector{Diagnostics.Fix{String, VersionNumber}}) =
    [
    Diagnostics.Fix{String, VersionNumber}(fix.actions, without_julia(fix.solution))
        for fix in fixes if !any(is_julia_action, fix.actions)
]

end # module
