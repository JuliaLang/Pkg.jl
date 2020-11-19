module Resolving

using ..Environments
using ..RegistryHandling
using ..Resolve
using ..Versions
using ..Pkg # remove

using .Environments: Environment, Project, Manifest, Dependency, is_fixed
using .RegistryHandling: Registry

using UUIDs
import Base: SHA1


#=
Base.@kwdef mutable struct GitRepo
    source::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing
    subdir::Union{String, Nothing} = nothing
end

Base.:(==)(r1::GitRepo, r2::GitRepo) =
    r1.source == r2.source && r1.rev == r2.rev && r1.subdir == r2.subdir

isurl(r::String) = occursin(URL_regex, r)

Base.@kwdef mutable struct PackageSpec
    name::Union{Nothing,String} = nothing
    uuid::Union{Nothing,UUID} = nothing
    version::VersionTypes = VersionSpec()
    tree_hash::Union{Nothing,SHA1} = nothing
    repo::GitRepo = GitRepo()
    path::Union{Nothing,String} = nothing
    pinned::Bool = false
    mode::PackageMode = PKGMODE_PROJECT
end
=#

const STDLIBS = Dict{UUID, Project}()
# m.uuid isa stdlib && return joinpath(Sys.STDLIB, pkg.name)
function load_stdlibs()
    empty!(STDLIBS)
    for name in readdir(Sys.STDLIB)
        # TODO Check if project file exist?
        stdlib_path = joinpath(Sys.STDLIB, name)
        env = Environment(joinpath(Sys.STDLIB, name))
        env.project === nothing && continue
        if env.project.pkg === nothing
            error("expected a project for stdlib ", name, " at ", repr(stdlib_path))
        end
        STDLIBS[env.project.pkg.uuid] = env.project
    end
    return
end
is_stdlib(uuid::UUID) = uuid in keys(STDLIBS)


# TODO: Remove
struct FixedPkg
    uuid::UUID
    name::String
    version::VersionNumber
    deps::Dict{UUID, Dependency}
end

function collect_fixed_pkgs(env::Environment)
    fixed_pkgs = Dict{UUID, FixedPkg}()
    pkg = env.project.pkg
    if pkg !== nothing
        fixed_pkgs[pkg.uuid] = FixedPkg(pkg.uuid, pkg.name, pkg.version, env.project.deps)
    end
    m = env.manifest
    if m !== nothing
        for (uuid, pkg) in m.pkgs
            if is_fixed(pkg)
                # TODO: Recursive
                path = pathof(pkg)
                @assert path !== nothing
                if !isdir(path)
                    error("internal error: expected path ", repr(path), " to exist")
                end
                env = Environment(path)
                # TODO; check if one of these deps are unknown and then if the package
                # has a manifest and use from there
                if uuid in keys(fixed_pkgs)
                    error("duplicated uuid for fixed package, ", string(uuid))
                end
                fixed_pkgs[uuid] = FixedPkg(uuid, pkg.name, pkg.version, env.project.deps)
            end
        end
    end
    return fixed_pkgs
end


const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
function resolve(env::Environment, regs::Vector{Registry}, extra_compat::Dict{UUID, VersionSpec}=Dict{UUID, VersionSpec}())
    load_stdlibs() # TODO: Remove
    julia_version = VERSION
    # @assert all extra compat is on project deps
    @assert issubset(keys(extra_compat), keys(env.project.deps))
    fixed = collect_fixed_pkgs(env)

    # TODO, resolver policy
    reqs = Resolve.Requires(pkg.uuid => get(VersionSpec, extra_compat, pkg.uuid)
                            for pkg in values(env.project.deps))

    delete!(reqs, JULIA_UUID)
    fixed_resolve = Dict{UUID,Resolve.Fixed}()

    for (_, pkg) in fixed
        fixed_resolve[pkg.uuid] = Resolve.Fixed(pkg.version, Dict(dep.uuid => dep.compat for (uuid, dep) in pkg.deps))
    end

    all_versions, all_compat = deps_graph(regs, reqs, fixed_resolve)
    all_versions[JULIA_UUID] = Set([julia_version])

    @show all_compat[UUID("34cfe95a-1eb2-52ea-b672-e2afdf69b78f")]

    error()
    uuid_to_name = Dict{UUID, String}()
    foreach(dep -> uuid_to_name[dep.uuid] = dep.name, values(env.project.deps))
    foreach(dep -> uuid_to_name[dep.uuid] = dep.name, values(fixed))
    for uuid in keys(all_compat)
        if is_stdlib(uuid)
            stdlib = STDLIBS[uuid]
            uuid_to_name[stdlib.pkg.uuid] = stdlib.pkg.name
        else
            name = Pkg.Types.registered_name(regs, uuid)
            name === nothing && error("cannot find name corresponding to UUID $(uuid) in a registry")
            uuid_to_name[uuid] = name
        end
    end
    if env.project.pkg !== nothing
        uuid_to_name[env.project.pkg.uuid] = env.project.pkg.name
    end

    graph = Resolve.Graph(all_versions, all_compat, uuid_to_name, reqs, fixed_resolve, false, julia_version)
    resolved_versions = Resolve.resolve(graph)
    @show resolved_versions

    # Create a new Project + manifest
    
    p_new = copy(env.project)
    #=
    for pkg in new_pkgs
        push!(p_new, 
    end
    =#

    # We can have:
    #   packages can have been removed
    #   package can have changed version / changed deps
    #   packages can have been added
    #   what can not change:
    #       git tracking
    #       path tracking
    #
    m_new = copy(env.manifest)
    # for pkg in input pkgs
    # if is_fixed 
    
    foreach(uuid -> delete!(m_new.pkgs), keys(fixed))
    foreach(uuid -> delete!(m_new.pkgs), keys(resolved_versions))
    for (uuid, v) in resolved_versions
        uuid == JULIA_UUID && continue
        # The registry could have been changed so even if we get
        # the same version here, we still need to update the
        # dependencies
        pkg = get(m_new, uuid, nothing)
        name = uuid_to_name[uuid]
        sha = tree_hash(regs, uuid)
        pinned = pkg === nothing ? false : pkg.pinned
        deps = keys(all_compat[uuid_resolved][v])
        m_new[uuid] = ManifestPkg(name, uuid, sha, v, deps, false)

        # else if it is fixed the deps are in

        @show deps
    end


end

function tree_hash(regs::Vector{Registry}, uuid::UUID)
    hash = nothing
    for reg in regs
        reg_pkg = get(reg, uuid, nothing)
        reg_pkg === nothing && continue
        pkg_info = RegistryHandling.registry_info(reg_pkg)
        version_info = get(pkg_info.version_info, pkg.version, nothing)
        version_info === nothing && continue
        hash′ = version_info.git_tree_sha1
        if hash !== nothing
            hash == hash′ || error("hash mismatch in registries for $(pkg.name) at version $(pkg.version)")
        end
        hash = hash′
    end
    return hash
end




get_or_make!(d::Dict{K,V}, k::K) where {K,V} = get!(V, d, k)

function deps_graph(registries::Vector{Registry},
                    reqs::Resolve.Requires, fixed::Dict{UUID,Resolve.Fixed}, julia_version=VERSION)
    uuids = Set{UUID}()
    union!(uuids, keys(reqs))
    union!(uuids, keys(fixed))
    for fixed_uuids in map(fx->keys(fx.requires), values(fixed))
        union!(uuids, fixed_uuids)
    end

    seen = Set{UUID}()

    all_versions = Dict{UUID,Set{VersionNumber}}()
    # pkg -> version -> (dependency => compat):
    all_compat = Dict{UUID,Dict{VersionNumber,Dict{UUID,VersionSpec}}}()

    for (fp, fx) in fixed
        all_versions[fp] = Set([fx.version])
        all_compat[fp]   = Dict(fx.version => Dict{UUID,VersionSpec}())
    end

    while true
        unseen = setdiff(uuids, seen)
        isempty(unseen) && break
        for uuid in unseen
            push!(seen, uuid)
            uuid in keys(fixed) && continue
            all_versions_u = get_or_make!(all_versions, uuid)
            all_compat_u   = get_or_make!(all_compat,   uuid)

            # Collect deps + compat for stdlib
            if is_stdlib(uuid)
                proj = STDLIBS[uuid]

                v = something(proj.pkg.version, VERSION)
                push!(all_versions_u, v)

                # TODO look at compat section for stdlibs?
                all_compat_u_vr = get_or_make!(all_compat_u, v)
                for other_uuid in keys(proj.deps)
                    push!(uuids, other_uuid)
                    all_compat_u_vr[other_uuid] = VersionSpec()
                end
            else
                for reg in registries
                    pkg = get(reg, uuid, nothing)
                    pkg === nothing && continue
                    info = RegistryHandling.registry_info(pkg)
                    for (v, uncompressed_data) in RegistryHandling.uncompressed_data(info)
                        # Filter yanked and if we are in offline mode also downloaded packages
                        # TODO, pull this into a function
                        #=
                        Pkg.RegistryHandling.isyanked(info, v) && continue
                        if Pkg.OFFLINE_MODE[]
                            pkg_spec = PackageSpec(name=pkg.name, uuid=pkg.uuid, version=v, tree_hash=Pkg.RegistryHandling.treehash(info, v))
                            is_package_downloaded(env.project_file, pkg_spec) || continue
                        end
                        =#

                        push!(all_versions_u, v)
                        all_compat_u[v] = uncompressed_data
                        union!(uuids, keys(uncompressed_data))
                    end
                end
            end
        end
    end

    #=
    for uuid in uuids
        uuid == JULIA_UUID && continue
        if !haskey(uuid_to_name, uuid)
            name = registered_name(registries, uuid)
            name === nothing && pkgerror("cannot find name corresponding to UUID $(uuid) in a registry")
            uuid_to_name[uuid] = name
            entry = manifest_info(env.manifest, uuid)
            entry ≡ nothing && continue
            uuid_to_name[uuid] = entry.name
        end
    end
    =#

    return all_versions, all_compat
end
end
