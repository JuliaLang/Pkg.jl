# This file is a part of Julia. License is MIT: https://julialang.org/license

# Adapter between the dependency graph that `Operations.deps_graph` produces
# and the exact SAT-based resolver from Resolver.jl. This is Pkg's default
# resolver; the legacy maxsum resolver is selected with JULIA_PKG_RESOLVER=maxsum.
module SATResolve

import Resolver
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
# Version lists are ordered most-preferred-first (descending), which is the
# preference order the resolver optimizes against. Returns the data dict and
# the list of required packages. With `apply_reqs = false` the requirement
# version specs are left out of the data (used for diagnosis, which wants
# user constraints attributed separately).
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
        preferred_versions::Dict{UUID, VersionNumber};
        apply_reqs::Bool = true,
    )
    data = Dict{UUID, PkgData}()
    vnmap = Dict{UUID, VersionSpec}()
    reg_result = Dict{UUID, VersionSpec}()
    for (uuid, all_versions) in pkg_versions
        (haskey(fixed, uuid) || uuid == JULIA_UUID) && continue
        vers = sort(all_versions, rev = true)
        # direct requirements restrict which versions exist at all
        apply_reqs && haskey(reqs, uuid) && filter!(in(reqs[uuid]), vers)
        # prefer an already-loaded version, like the legacy resolver
        pref = get(preferred_versions, uuid, nothing)
        if pref !== nothing
            i = findfirst(==(pref), vers)
            i !== nothing && i != 1 && pushfirst!(deleteat!(vers, i), pref)
        end
        deps_list = deps_compressed[uuid]
        compat_list = compat_compressed[uuid]
        weak_deps_list = weak_deps_compressed[uuid]
        weak_compat_list = weak_compat_compressed[uuid]
        versions_per_reg = pkg_versions_per_registry[uuid]
        depends = Dict{VersionNumber, Vector{UUID}}()
        compat = Dict{VersionNumber, Dict{UUID, VersionSpec}}()
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
                    # package below; julia_version === nothing means "any julia"
                    julia_version === nothing || (comp_v[q] = spec)
                    continue
                end
                comp_v[q] = spec
                # weak dependencies constrain versions (via compat above) but
                # do not force installation
                is_weak = any(Registry.is_weak_dep(wd, v, q) for wd in weak_deps_list)
                is_weak || push!(strong, q)
            end
            depends[v] = sort!(strong)
            compat[v] = comp_v
        end
        data[uuid] = Resolver.PkgData(vers, depends, compat)
    end
    # fixed packages (project, dev'd, pinned): a single version whose
    # requirements are dependency edges plus compat
    for (uuid, fx) in fixed
        uuid == JULIA_UUID && continue
        strong = sort!(UUID[q for q in keys(fx.requires) if q ∉ fx.weak && q != JULIA_UUID])
        comp_v = Dict{UUID, VersionSpec}()
        for (q, spec) in fx.requires
            q == JULIA_UUID && julia_version === nothing && continue
            comp_v[q] = spec
        end
        data[uuid] = Resolver.PkgData(
            [fx.version], Dict(fx.version => strong), Dict(fx.version => comp_v)
        )
    end
    # julia itself: a required single-version package that julia compat
    # entries resolve against
    if julia_version !== nothing
        data[JULIA_UUID] = Resolver.PkgData(
            [julia_version],
            Dict(julia_version => UUID[]),
            Dict(julia_version => Dict{UUID, VersionSpec}())
        )
    end
    rlist = collect(keys(reqs))
    union!(rlist, keys(fixed))
    julia_version === nothing || push!(rlist, JULIA_UUID)
    sort!(unique!(rlist))
    return data, rlist
end

# Fast path: try to give every package reachable through first-choice versions
# its first choice. When that assignment is conflict-free it is the optimal
# solution for any package priority order (no package can do better than its
# first choice), so the SAT solver is not needed. Returns a package =>
# version-index dict, or `nothing` on any dead end.
function greedy_solution(info::Dict{UUID, <:Resolver.PkgInfo}, reqs::Vector{UUID})
    for u in reqs
        haskey(info, u) || return nothing
    end
    sol = Dict{UUID, Int}()
    queue = copy(reqs)
    while !isempty(queue)
        p = pop!(queue)
        haskey(sol, p) && continue
        info_p = info[p]
        isempty(info_p.versions) && return nothing
        # check p's first choice against everything chosen so far
        for (q, j) in sol
            b = get(info_p.interacts, q, -1)
            b == -1 && continue
            info_p.conflicts[1, b + j] && return nothing
        end
        sol[p] = 1
        # follow the strong dependencies of the chosen version
        for (k, q) in enumerate(info_p.depends)
            info_p.conflicts[1, k] || continue
            haskey(info, q) || return nothing
            haskey(sol, q) || push!(queue, q)
        end
    end
    return sol
end

# package priority order for the resolver's lexicographic optimization
priority(uuid_to_name::Dict{UUID, String}) = u -> (get(uuid_to_name, u, ""), u)

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
        diagnose_unsat::Bool = true,
    )
    data, rlist = build_pkg_data(
        deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed,
        pkg_versions, pkg_versions_per_registry, reqs, fixed, julia_version, preferred_versions
    )
    # a requirement whose version spec matches no available version can never
    # resolve; report it directly instead of running the full diagnosis
    impossible = String[]
    for u in rlist
        (u == JULIA_UUID || haskey(fixed, u)) && continue
        isempty(data[u].versions) || continue
        id = pkgID(u, uuid_to_name)
        avail = get(pkg_versions, u, VersionNumber[])
        if isempty(avail)
            push!(impossible, " * $id: no versions are available (they may all be yanked, or filtered by offline mode)")
        else
            vers = range_compressed_versionspec(copy(avail))
            push!(impossible, " * $id: no available version matches the requirement `$(reqs[u])`, available versions are: $vers")
        end
    end
    if !isempty(impossible)
        throw(ResolverError(string("Unsatisfiable requirements detected:\n", join(impossible, "\n"))))
    end
    info = Resolver.pkg_info(data, rlist)
    # a requirement without any candidate version (e.g. an impossible version
    # spec) is dropped from `info` entirely; that resolve can only fail
    sol = if any(u -> !haskey(info, u) || isempty(info[u].versions), rlist)
        nothing
    elseif (sol_inds = greedy_solution(info, rlist)) !== nothing
        Dict{UUID, VersionNumber}(p => info[p].versions[i] for (p, i) in sol_inds)
    else
        Resolver.resolve(info, rlist; by = priority(uuid_to_name))
    end
    if sol === nothing
        msg = "Unsatisfiable requirements detected"
        if diagnose_unsat
            report = unsat_diagnosis(
                deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed,
                pkg_versions, pkg_versions_per_registry, uuid_to_name, reqs, fixed,
                julia_version, preferred_versions
            )
            report !== nothing && (msg = string(msg, ":\n", report))
        end
        throw(ResolverError(msg))
    end
    # match the legacy resolver's output: fixed packages and julia are not returned
    delete!(sol, JULIA_UUID)
    for uuid in keys(fixed)
        delete!(sol, uuid)
    end
    return sol
end

# Restrict `data` to the strong-dependency closure of `roots`; the diagnosis
# scales with problem size, and packages only reachable through weak edges
# cannot contribute to a conflict story rooted in the requirements.
function strong_closure(data::Dict{UUID, PkgData}, roots::Vector{UUID})
    keep = Set{UUID}()
    queue = UUID[u for u in roots if haskey(data, u)]
    while !isempty(queue)
        u = pop!(queue)
        u in keep && continue
        push!(keep, u)
        for deps_v in values(data[u].depends), q in deps_v
            q in keep || !haskey(data, q) || push!(queue, q)
        end
    end
    return filter!(kv -> first(kv) in keep, data)
end

# Explain an unsatisfiable resolve with Resolver.diagnose: conflict clusters,
# verified fixes and upstream suggestions. Returns the rendered report with
# package names substituted for UUIDs, or `nothing` if no diagnosis could be
# produced.
function unsat_diagnosis(
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
        max_fixes::Integer = 8,
    )
    # rebuild without the requirement specs baked in so the diagnosis can
    # blame them and suggest relaxing them
    data, _ = build_pkg_data(
        deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed,
        pkg_versions, pkg_versions_per_registry, reqs, fixed, julia_version, preferred_versions;
        apply_reqs = false
    )
    # synthetic fixed packages that are not themselves required (the project)
    # only restate the requirements, which are attributed to the user via `reqs`
    for uuid in keys(fixed)
        haskey(reqs, uuid) || delete!(data, uuid)
    end
    diag_reqs = UUID[u for u in keys(reqs) if haskey(data, u)]
    julia_version === nothing || push!(diag_reqs, JULIA_UUID)
    sort!(unique!(diag_reqs))
    data = strong_closure(data, diag_reqs)
    # requirement version specs become user compat the diagnosis can suggest relaxing
    usercompat = Dict{UUID, Vector{VersionNumber}}()
    for (u, spec) in reqs
        haskey(data, u) || continue
        allowed = VersionNumber[v for v in data[u].versions if v in spec]
        length(allowed) < length(data[u].versions) && (usercompat[u] = allowed)
    end
    dg = try
        Resolver.diagnose(data, diag_reqs; compat = usercompat, max_fixes)
    catch err
        err isa ArgumentError || rethrow()
        return nothing
    end
    report = sprint(show, MIME("text/plain"), dg)
    names = Dict{String, String}(string(u) => n for (u, n) in uuid_to_name)
    names[string(JULIA_UUID)] = "julia"
    uuid_re = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    return replace(report, uuid_re => m -> get(names, m, m))
end

end # module
