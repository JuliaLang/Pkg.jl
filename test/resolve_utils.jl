# This file is a part of Julia. License is MIT: https://julialang.org/license

module ResolveUtils

using Test
using UUIDs
import ..Pkg # ensure we are using the correct Pkg
using Pkg.Types
using Pkg.Resolve
using Pkg.Resolve: add_reqs!, simplify_graph!, Fixed, Requires

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
    all_compat = Dict{UUID, Dict{VersionNumber, Dict{UUID, VersionSpec}}}()
    all_compat_w = Dict{UUID, Dict{VersionNumber, Set{UUID}}}()

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
    for (p, preq) in deps
        u = uuid(p)
        deps_pkgs = Dict{String, Set{VersionNumber}}()
        for (vn, vreq) in deps[p], rp in keys(vreq)
            push!(get!(Set{VersionNumber}, deps_pkgs, rp), vn)
        end
        all_compat[u] = Dict{VersionNumber, Dict{UUID, VersionSpec}}()
        for (vn, vreq) in preq
            all_compat[u][vn] = Dict{UUID, VersionSpec}()
            for (rp, rvs) in vreq
                all_compat[u][vn][uuid(rp)] = rvs
                # weak dependency?
                if haskey(deps_w, p) && haskey(deps_w[p], vn) && (rp ∈ deps_w[p][vn])
                    # same as push!(all_compat_w[u][vn], uuid(rp)) but create keys as needed
                    push!(get!(Set{UUID}, get!(Dict{VersionNumber, Set{UUID}}, all_compat_w, u), vn), uuid(rp))
                end
            end
        end
    end
    return Graph(all_compat, all_compat_w, uuid_to_name, Requires(), fixed, VERBOSE)
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
