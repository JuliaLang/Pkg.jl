# This file is a part of Julia. License is MIT: https://julialang.org/license

module ResolveUtils

using Test
using UUIDs
import ..Pkg # ensure we are using the correct Pkg
using Pkg.Types
using Pkg.Resolve
using Pkg.Resolve: add_reqs!, simplify_graph!, Fixed, Requires
using Pkg.Resolve: Graph, ResolverError, uuid_julia, is_julia, add_fixed!, propagate_constraints!,
    disable_unreachable!, prune_graph!, compute_eq_classes!, push_snapshot!, pop_snapshot!,
    simplify_graph_soft!, greedysolver, maxsum, verify_solution, compute_output_dict

export sanity_tst, resolve_tst, VERBOSE

# print info, stats etc.
const VERBOSE = false

# auxiliary functions
const uuid_package = UUID("cfb74b52-ec16-5bb7-a574-95d9e393895e")
pkguuid(p::String) = uuid5(uuid_package, p)
function storeuuid(p::String, uuid_to_name::Dict{UUID, String})
    uuid = p == "julia" ? Resolve.uuid_julia : pkguuid(p)
    if haskey(uuid_to_name, uuid)
        @assert uuid_to_name[uuid] == p
    else
        uuid_to_name[uuid] = p
    end
    return uuid
end
wantuuids(want_data) = Dict{UUID, VersionNumber}(pkguuid(p) => v for (p, v) in want_data)

"""
    graph = graph_from_data(deps_data)

Generate a package dependency graph from the entries in the array `deps_data`, where each entry
is an array of the form `["PkgName", v"x.y.z", "DependencyA", v"Ax.Ay.Az", ...]`.
This states that the package "PkgName" with version `v"x.y.z"` depends on "DependencyA" with the
specified compatibility information. The last entry of the array can optionally be `:weak`.
"""
function graph_from_data(deps_data)
    uuid_to_name = Dict{UUID, String}()
    uuid(p) = storeuuid(p, uuid_to_name)
    fixed = Dict{UUID, Fixed}()

    deps = Dict{String, Dict{VersionNumber, Dict{String, VersionSpec}}}()
    deps_w = Dict{String, Dict{VersionNumber, Set{String}}}()
    for d in deps_data
        p, vn, r = d[1], d[2], d[3:end]
        if !haskey(deps, p)
            deps[p] = Dict{VersionNumber, Dict{String, VersionSpec}}()
        end
        if !haskey(deps[p], vn)
            deps[p][vn] = Dict{String, VersionSpec}()
        end
        isempty(r) && continue
        rp = r[1]
        weak = length(r) > 1 && r[end] == :weak
        rvs = VersionSpec(r[2:(end - weak)]...)
        deps[p][vn][rp] = rvs
        if weak
            # same as push!(deps_w[p][vn], rp) but create keys as needed
            push!(get!(Set{String}, get!(Dict{VersionNumber, Set{String}}, deps_w, p), vn), rp)
        end
    end
    # Build pkg_versions map
    pkg_versions = Dict{UUID, Vector{VersionNumber}}()
    for (p, preq) in deps
        u = uuid(p)
        pkg_versions[u] = sort!(collect(keys(preq)))
    end

    # Convert per-version data to compressed format
    # For tests, each version gets its own VersionRange
    all_deps_compressed = Dict{UUID, Dict{VersionRange, Set{UUID}}}()
    all_compat_compressed = Dict{UUID, Dict{VersionRange, Dict{UUID, VersionSpec}}}()
    all_weak_deps_compressed = Dict{UUID, Dict{VersionRange, Set{UUID}}}()
    all_weak_compat_compressed = Dict{UUID, Dict{VersionRange, Dict{UUID, VersionSpec}}}()

    for (p, preq) in deps
        u = uuid(p)
        all_deps_compressed[u] = Dict{VersionRange, Set{UUID}}()
        all_compat_compressed[u] = Dict{VersionRange, Dict{UUID, VersionSpec}}()
        all_weak_deps_compressed[u] = Dict{VersionRange, Set{UUID}}()
        all_weak_compat_compressed[u] = Dict{VersionRange, Dict{UUID, VersionSpec}}()

        for (vn, vreq) in preq
            # Create a single-version range for this version
            vrange = VersionRange(vn, vn)
            deps_set = Set{UUID}()
            compat_dict = Dict{UUID, VersionSpec}()
            weak_deps_set = Set{UUID}()
            weak_compat_dict = Dict{UUID, VersionSpec}()

            for (rp, rvs) in vreq
                dep_uuid = uuid(rp)
                push!(deps_set, dep_uuid)
                compat_dict[dep_uuid] = rvs

                # weak dependency?
                if haskey(deps_w, p) && haskey(deps_w[p], vn) && (rp ∈ deps_w[p][vn])
                    push!(weak_deps_set, dep_uuid)
                    weak_compat_dict[dep_uuid] = rvs
                end
            end

            all_deps_compressed[u][vrange] = deps_set
            all_compat_compressed[u][vrange] = compat_dict
            if !isempty(weak_deps_set)
                all_weak_deps_compressed[u][vrange] = weak_deps_set
                all_weak_compat_compressed[u][vrange] = weak_compat_dict
            end
        end
    end

    # Wrap in vectors for multi-registry support (tests simulate a single registry)
    all_deps_compressed_vec = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
        u => [d] for (u, d) in all_deps_compressed
    )
    all_compat_compressed_vec = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
        u => [c] for (u, c) in all_compat_compressed
    )
    all_weak_deps_compressed_vec = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}(
        u => [d] for (u, d) in all_weak_deps_compressed
    )
    all_weak_compat_compressed_vec = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}(
        u => [c] for (u, c) in all_weak_compat_compressed
    )

    # Create pkg_versions_per_registry (single registry with all versions)
    pkg_versions_per_registry = Dict{UUID, Vector{Set{VersionNumber}}}(
        u => [Set(versions)] for (u, versions) in pkg_versions
    )

    return Graph(all_deps_compressed_vec, all_compat_compressed_vec, all_weak_deps_compressed_vec, all_weak_compat_compressed_vec, pkg_versions, pkg_versions_per_registry, uuid_to_name, Requires(), fixed, VERBOSE)
end
function reqs_from_data(reqs_data, graph::Graph)
    reqs = Dict{UUID, VersionSpec}()
    function uuid_check(p)
        uuid = pkguuid(p)
        @assert graph.data.uuid_to_name[uuid] == p
        return uuid
    end
    for r in reqs_data
        p = uuid_check(r[1])
        reqs[p] = VersionSpec(r[2:end])
    end
    return reqs
end
struct SanitySortKey{G, P}
    gadj::G
    pdict::P
end

(key::SanitySortKey)(pv) = -length(key.gadj[key.pdict[pv[1]]])

"""
Scan the graph for (explicit or implicit) contradictions. Returns a list of problematic
(package,version) combinations.
"""
function sanity_check(graph::Graph, sources::Set{UUID} = Set{UUID}(), verbose::Bool = true)
    req_inds = graph.req_inds
    fix_inds = graph.fix_inds

    id(p) = pkgID(p, graph)

    isempty(req_inds) || @warn("sanity check called on a graph with non-empty requirements")
    if !any(is_julia(graph, fp0) for fp0 in fix_inds)
        @warn("sanity check called on a graph without julia requirement, adding it")
        add_fixed!(graph, Dict(uuid_julia => Fixed(VERSION)))
    end
    if length(fix_inds) ≠ 1
        @warn("sanity check called on a graph with extra fixed requirements (besides julia)")
    end

    isources = isempty(sources) ?
        Set{Int}(1:graph.np) :
        Set{Int}(graph.data.pdict[p] for p in sources)

    propagate_constraints!(graph)
    disable_unreachable!(graph, isources)
    prune_graph!(graph)
    compute_eq_classes!(graph)

    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    data = graph.data
    pkgs = data.pkgs
    pdict = data.pdict
    pvers = data.pvers
    eq_classes = data.eq_classes

    problematic = Tuple{String, VersionNumber}[]

    np == 0 && return problematic

    vers = [(pkgs[p0], pvers[p0][v0]) for p0 in 1:np for v0 in 1:(spp[p0] - 1)]
    sort!(vers, by = SanitySortKey(gadj, pdict))

    nv = length(vers)

    svdict = Dict{Tuple{UUID, VersionNumber}, Int}(vers[i] => i for i in 1:nv)

    checked = falses(nv)

    last_str_len = 0

    for (i, (p, vn)) in enumerate(vers)
        if verbose
            frac_compl = i / nv
            print("\r", " "^last_str_len, "\r")
            progr_msg = string(lpad(i, 3, '0'), "/", lpad(nv, 3, '0'), " (", round(Int, 100 * frac_compl), "%) — problematic so far: ", length(problematic))
            print(progr_msg)
            last_str_len = length(progr_msg)
        end

        length(gadj[pdict[p]]) == 0 && break
        checked[i] && continue

        push_snapshot!(graph)

        # enforce package version
        # TODO: use add_reqs! instead...
        p0 = graph.data.pdict[p]
        v0 = graph.data.vdict[p0][vn]
        fill!(graph.gconstr[p0], false)
        graph.gconstr[p0][v0] = true
        push!(graph.req_inds, p0)

        ok = false
        try
            simplify_graph_soft!(graph, Set{Int}([p0]), log_events = false)
        catch err
            isa(err, ResolverError) || rethrow()
            @goto done
        end

        ok, sol = greedysolver(graph)
        ok && @goto done
        maxsum_result, sol = maxsum(graph)
        ok = maxsum_result == :ok

        @label done

        if !ok
            for vneq in eq_classes[p][vn]
                push!(problematic, (id(p), vneq))
            end
        else
            @assert verify_solution(sol, graph)
            sol_dict = compute_output_dict(sol, graph)
            for (sp, svn) in sol_dict
                j = svdict[sp, svn]
                checked[j] = true
            end
        end

        # state reset
        empty!(graph.req_inds)
        pop_snapshot!(graph)
    end
    if verbose
        print("\r", " "^last_str_len, "\r")
        println("found $(length(problematic)) problematic versions")
    end
    return sort!(problematic)
end

function sanity_tst(deps_data, expected_result; pkgs = [])
    if VERBOSE
        println()
        @info("sanity check")
        # @show deps_data
        # @show pkgs
    end
    graph = graph_from_data(deps_data)
    id(p) = pkgID(pkguuid(p), graph)
    result = sanity_check(graph, Set(pkguuid(p) for p in pkgs), VERBOSE)

    length(result) == length(expected_result) || return false
    expected_result_uuid = [(id(p), vn) for (p, vn) in expected_result]
    for r in result
        r ∈ expected_result_uuid || return false
    end
    return true
end
sanity_tst(deps_data; kw...) = sanity_tst(deps_data, []; kw...)

function resolve_tst(deps_data, reqs_data, want_data = nothing; validate_versions = true)
    if VERBOSE
        println()
        @info("resolving")
        # @show deps_data
        # @show reqs_data
    end
    graph = graph_from_data(deps_data)
    reqs = reqs_from_data(reqs_data, graph)
    add_reqs!(graph, reqs)
    simplify_graph!(graph; validate_versions)
    want = resolve(graph)

    id(u) = pkgID(u, graph)
    wd = wantuuids(want_data)
    if want ≠ wd
        for (u, vn) in want
            if u ∉ keys(wd)
                @info "resolver decided to install $(id(u)) (v$vn), package wasn't expected"
            elseif vn ≠ wd[u]
                @info "version mismatch for $(id(u)), resolver wants v$vn, expected v$(wd[u])"
            end
        end
        for (u, vn) in wd
            if u ∉ keys(want)
                @info "was expecting the resolver to install $(id(u)) (v$vn)"
            end
        end
        return false
    else
        return true
    end
end

end
