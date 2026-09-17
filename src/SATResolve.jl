# This file is a part of Julia. License is MIT: https://julialang.org/license

# Adapter between the dependency graph that `Operations.deps_graph` produces
# and the exact SAT-based resolver from Resolver.jl. This is Pkg's default
# resolver; the legacy maxsum resolver is selected with JULIA_PKG_RESOLVER=maxsum.
module SATResolve

import Resolver
import Resolver.Diagnostics
using UUIDs
import ..Registry, ..Types
using ..Versions: VersionSpec, VersionRange
using ..Resolve: ResolverError, Fixed, Requires, pkgID, range_compressed_versionspec

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

const DepsCompressed = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}
const CompatCompressed = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}

const PkgData = Resolver.PkgData{
    UUID, VersionNumber, VersionSpec,
    Vector{VersionNumber},
    Dict{VersionNumber, Vector{UUID}},
    Dict{VersionNumber, Dict{UUID, VersionSpec}},
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
        compat_sources::Dict{String, Dict{UUID, VersionSpec}},
    )
    # The requirement version specs, the compat of the projects and the pins
    # are the user's own constraints: they go to the resolver as such, so a
    # failed resolve can attribute them and suggest relaxing them.
    compat = Dict{UUID, VersionSpec}()
    # In a workspace, a requirement's spec is the intersection of the compat
    # entries of every project file. Each file's entry goes to the resolver as
    # a constraint of its own, so that a failed resolve can name the file whose
    # entry to relax; the spec itself is passed only where it says more than
    # the entries do (an explicit version request, say).
    sourced = Dict{Symbol, Dict{UUID, VersionSpec}}()
    pin = Dict{UUID, VersionNumber}()
    for (u, spec) in reqs
        (u == JULIA_UUID || haskey(fixed, u)) && continue
        if haskey(pinned, u)
            pin[u] = pinned[u]
            continue
        end
        sources = [file => c[u] for (file, c) in compat_sources if haskey(c, u)]
        if isempty(sources)
            compat[u] = spec
            continue
        end
        # what a spec admits is decided on the versions there are, since
        # VersionSpec equality is syntactic
        vers = get(pkg_versions, u, VersionNumber[])
        admitted(s::VersionSpec) = Set{VersionNumber}(v for v in vers if v in s)
        by_spec = admitted(spec)
        by_files = mapreduce(admitted ∘ last, intersect, sources)
        # the files' entries are attributed only where the spec honours them:
        # a stdlib's spec is let float regardless of what the files say
        if by_spec ⊈ by_files
            compat[u] = spec
            continue
        end
        for (file, s) in sources
            length(admitted(s)) == length(vers) && continue # admits everything
            get!(Dict{UUID, VersionSpec}, sourced, Resolver.compat_kind(file))[u] = s
        end
        by_spec == by_files || (compat[u] = spec)
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
            # a project's compat on a package attributed to its file already
            # is not folded in a second time as the user's
            any(c -> haskey(c, q), values(sourced)) && continue
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
                    # shipped with this julia (see the Resolve.Graph constructor)
                    if Types.is_stdlib(q) && !(q in Types.UPGRADABLE_STDLIBS_UUIDS)
                        stdlib_ver = Types.stdlib_version(q, julia_version)
                        if stdlib_ver !== nothing && !isempty(spec) && !(stdlib_ver in spec)
                            continue
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
    return data, rlist, compat, sourced, pin
end

# package priority order for the resolver's lexicographic optimization
priority(uuid_to_name::Dict{UUID, String}) = u -> (get(uuid_to_name, u, ""), u)

# Version preference: newest first, except that an already-loaded version of a
# package is preferred over everything else (like the legacy resolver). The
# resolver detects packages whose list is already in this order for free, so
# only the packages with a preferred version cost anything.
function version_order(preferred_versions::Dict{UUID, VersionNumber})
    isempty(preferred_versions) && return nothing
    return function (u::UUID)
        pref = get(preferred_versions, u, nothing)
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
        compat_sources::Dict{String, Dict{UUID, VersionSpec}} = Dict{String, Dict{UUID, VersionSpec}}(),
        req_sources::Dict{UUID, Vector{String}} = Dict{UUID, Vector{String}}(),
        diagnose_unsat::Bool = true,
    )
    data, rlist, compat, sourced, pin = build_pkg_data(
        deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed,
        pkg_versions, pkg_versions_per_registry, reqs, fixed, julia_version, pinned, compat_sources
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
        else
            for (kind, c) in sourced
                haskey(c, u) && !any(in(c[u]), avail) || continue
                vers = range_compressed_versionspec(copy(avail))
                push!(impossible, " * $id: no available version matches the compat `$(c[u])` in $(Resolver.compat_source(kind)), available versions are: $vers")
            end
        end
    end
    if !isempty(impossible)
        throw(ResolverError(string("Unsatisfiable requirements detected:\n", join(impossible, "\n"))))
    end
    # in a workspace the requirements say which project files list them, so
    # that a fix dropping one can say where to drop it from
    reqs_with_sources = isempty(req_sources) ? rlist :
        [u => get(req_sources, u, String[]) for u in rlist]
    prob = Resolver.Problem(reqs_with_sources; compat, pin, sourced...)
    ans = Resolver.resolve(
        data, prob;
        by = priority(uuid_to_name), order = version_order(preferred_versions),
        diagnose = diagnose_unsat, upstream = diagnose_unsat
    )
    if ans isa Diagnostics.Diagnosis
        report = sprint(show, MIME("text/plain"), named(ans, display_names(uuid_to_name)))
        # the report opens with "Unsatisfiable — N conflicts...:"
        throw(ResolverError(replace(report, r"^Unsatisfiable" => "Unsatisfiable requirements detected")))
    elseif ans === nothing
        throw(ResolverError("Unsatisfiable requirements detected"))
    end
    sol = ans::Dict{UUID, VersionNumber}
    # match the legacy resolver's output: fixed packages and julia are not returned
    delete!(sol, JULIA_UUID)
    for uuid in keys(fixed)
        delete!(sol, uuid)
    end
    return sol
end

## rendering a diagnosis with package names

# The name a package is shown under in a report: its name, or `name [uuid8]`
# when several packages in the graph share it.
function display_names(uuid_to_name::Dict{UUID, String})
    counts = Dict{String, Int}()
    for name in values(uuid_to_name)
        counts[name] = get(counts, name, 0) + 1
    end
    return function (u::UUID)
        u == JULIA_UUID && return "julia"
        name = get(uuid_to_name, u, nothing)
        name === nothing && return pkgID(u, uuid_to_name)
        return counts[name] == 1 ? name : pkgID(u, uuid_to_name)
    end
end

# A diagnosis is plain data keyed by UUID; rebuild it over display names so the
# resolver's own report renders readably (its `show` prints `string(p)`).
# The synthetic julia requirement is not something the user can act on, so
# fixes that ask to drop it are left out, as is julia itself from the
# versions a fix would allow.
function named(d::Diagnostics.Diagnosis, name::Function)
    return Diagnostics.Diagnosis(
        [
            Diagnostics.Conflict{String, VersionNumber}(
                    String[name(p) for p in c.reqs],
                    [
                        Diagnostics.Line{String}(
                            named(l.clause, name), String[name(p) for p in l.through],
                            l.given, l.proof, l.pivot === nothing ? nothing : name(l.pivot)
                        )
                        for l in c.lines
                    ],
                    Dict{String, Vector{VersionNumber}}(name(p) => vs for (p, vs) in c.versions),
                    Dict{String, Vector{Vector{Symbol}}}(name(p) => ks for (p, ks) in c.excluded),
                    named(c.fixes, name),
                    Tuple{Vector{Vector{Diagnostics.Action{String}}}, Vector{Diagnostics.Action{String}}}[
                        ([[named(a, name) for a in b] for b in bs], [named(a, name) for a in us])
                        for (bs, us) in c.blocks if !any(is_julia_action, us) && !any(b -> any(is_julia_action, b), bs)
                    ],
                    named(c.upstream, name),
                    Dict{String, Vector{Tuple{Int, Vector{Int}}}}(name(p) => sh for (p, sh) in c.shadows)
                )
                for c in d.conflicts
        ],
        [
            Diagnostics.Alternative{String, VersionNumber}(
                    a.conflicts, a.avoided, [named(m, name) for m in a.menus]
                )
                for a in d.alternatives if !any(m -> all(f -> any(is_julia_action, f.actions), m), a.menus)
        ],
        d.others
    )
end

is_julia_action(a::Diagnostics.Action) = a.pkg == JULIA_UUID

named(a::Diagnostics.Action, name::Function) = Diagnostics.Action(a.kind, name(a.pkg))

named(sol::Dict{UUID, VersionNumber}, name::Function) =
    Dict{String, VersionNumber}(name(p) => v for (p, v) in sol if p != JULIA_UUID)

named(ups::Vector{<:Diagnostics.Upstream}, name::Function) =
    [
    Diagnostics.Upstream{String, VersionNumber}(
            name(u.pkg), u.latest, name(u.dep), u.supports, u.supported, named(u.solution, name)
        )
        for u in ups
]

named(fixes::Vector{<:Diagnostics.Fix}, name::Function) =
    [
    Diagnostics.Fix{String, VersionNumber}([named(a, name) for a in fix.actions], named(fix.solution, name))
        for fix in fixes if !any(is_julia_action, fix.actions)
]

# a clause is a set of literals keyed by package; renaming re-sorts to keep
# it in normal form
named(c::Resolver.Clauses.Clause, name::Function) =
    Resolver.Clauses.Clause{String}(sort!([name(p) => m for (p, m) in c.lits]; by = first))

end # module
