module Environments

using TOML
using Base: UUID, SHA1
using ..Pkg.Versions
using ..Pkg: Resolve
using ..Pkg

# export Environment, Project, Manifest

include("project.jl")
include("manifest.jl")

struct Environment
    path::String
    project::Union{Nothing, Project}
    manifest::Union{Nothing, Manifest{VersionNumber}}
end

function Base.copy(env::Environment)
    Environment(env.path, env.project  === nothing ? nothing : copy(env.project),
                          env.manifest === nothing ? nothing : copy(env.manifest)
    )
end

function Environment(dir::String)
    project_path = nothing
    for name in Base.project_names
        candidate_path = joinpath(dir, name)
        if isfile(candidate_path)
            project_path = candidate_path
            break
        end
    end
    project = project_path === nothing ? nothing : Project(project_path)

    manifest_path = nothing
    for name in Base.manifest_names
        candidate_path = joinpath(dir, name)
        if isfile(candidate_path)
            manifest_path = candidate_path
            break
        end
    end
    manifest = manifest_path === nothing ? nothing : Manifest(manifest_path)
    return Environment(dir, project, manifest)
end

function prune_manifest!(env::Environment)
    project_uuids = Set{UUID}(keys(env.project.deps))
    if env.project.pkg != nothing
        push!(project_uuids, env.project.pkg.uuid)
    end
    prune_manifest!(env.manifest, project_uuids)
end

write_environment(env::Environment) = write_environment(env.path, env)
function write_environment(path::String, env::Environment)
    mkpath(path)
    prune_manifest!(env)

    # Then write
    n = 0
    n += write_project(path, env.project)
    n += write_manifest(path, env.manifest)
    return n
end

function find_installed(name::String, uuid::UUID, sha1::SHA1)
    slug_default = Base.version_slug(uuid, sha1)
    # 4 used to be the default so look there first
    for slug in (slug_default, Base.version_slug(uuid, sha1, 4))
        for depot in Base.DEPOT_PATH #Pkg.depots()
            path = abspath(depot, "packages", name, slug)
            ispath(path) && return path
        end
    end
    return nothing
end



    m.uuid isa stdlib && return joinpath(Sys.STDLIB, pkg.name)
function load_stdlib()
    stdlib = Dict{UUID,String}()
    for name in readdir(Sys.STDLIB)

        env = Environment(joinpah(Sys.STDLIB, name))
        env.project === nothing && continue
        nothing === uuid && continue
        stdlib[UUID(uuid)] = name
    end
    return stdlib
end


function pathof(m::ManifestPkg)
    is_stdlib(m.uuid) && return joinpath(Sys.STDLIB, pkg.name)
    m.path !== nothing && return m.path
    
    find_installed(m.name, pkg.uuid, pkg.tree_hash)

end

is_fixed(m::ManifestPkg) = m.location_info isa String || m.location_info isa GitLocation || m.pinned
struct FixedPkg
    uuid::UUID
    deps::Dict{UUID, Dependency}
end

function collect_fixed_pkgs(env::Environment)
    # @assert is_fixed_instantiated(env.manifest)
    m = env.manifest
    fixed_pkgs = FixedPkg[]
    for (uuid, pkg) in m.pkgs
        loc = pkg.location_info
        is_fixed = loc isa GitLocation || loc isa String
        if is_fixed
            # TODO: Recursive
            path = loc isa GitLocation ? find_installed(pkg.name, pkg.uuid, loc.git_tree_sha1) : loc
            @assert path !== nothing
            env = Environment(path)
            # TODO; check if one of these deps are unknown and then if the package
            # has a manifest and use from there
            push!(fixed_pkgs, FixedPkg(uuid, env.project.deps))
        end
    end
    return fixed_pkgs
end

function resolve(env::Environment, regs::Vector{Registry}, extra_compat::Dict{UUID, VersionSpec}=Dict{UUID, VersionSpec}())
    # @assert all extra compat is on project deps
    @assert issubset(keys(extra_compat), keys(env.project.deps))
    fixed = collect_fixed_pkgs(env)
    # TODO, resolver policy
    reqs = Resolve.Requires(pkg.uuid => get(VersionSpec, extra_compat, pkg.uuid) 
                            for pkg in values(env.project.deps))
    if env.project.pkg !== nothing
        reqs[env.project.pkg.uuid] = VersionSpec(env.project.pkg.version)
    end

    fixed_resolve = Dict{UUID,Resolve.Fixed}()
    for pkg in fixed
        fixed_resolve[uuid] = Fixed(pkg.verion => Dict(dep.uuid => dep.compat for dep in pkg.deps))
    end

    deps_graph(regs, reqs, fixed)
en




# stdlib registry...


function deps_graph(regs::Vector{Registries}, reqs::Resolve.Requires, fixed::Dict{UUID,Resolve.Fixed})
    uuids = Set{UUID}()
    union!(uuids, keys(reqs))
    union!(uuids, keys(fixed))
    for fix in values(fixed)    #       in map(fx->keys(fx.requires), values(fixed))
        union!(uuids, keys(fixed))
    end

    seen = Set{UUID}()

    all_versions = Dict{UUID,Set{VersionNumber}}()
    all_compat = Dict{UUID,Dict{VersionNumber,Dict{UUID,VersionSpec}}}()    # pkg -> version -> dep -> compat

    for (fp, fx) in fixed
        all_versions[fp] = Set([fx.version])
        all_compat[fp]   = Dict(fx.version => Dict{VersionNumber,Dict{UUID,VersionSpec}}())
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
            # THIS CRAP!!!!!!!!!!!!!!!
            if is_stdlib(uuid)
                path = Types.stdlib_path(stdlibs()[uuid])
                proj_file = projectfile_path(path; strict=true)
                @assert proj_file !== nothing
                proj = read_package(proj_file)

                v = something(proj.version, VERSION)
                push!(all_versions_u, v)


                # TODO look at compat section for stdlibs?
                all_compat_u_vr = get_or_make!(all_compat_u, v)
                for (_, other_uuid) in proj.deps
                    all_compat_u_vr[other_uuid] = VersionSpec()
                end
            else
                for reg in registries
                    pkg = reg[uuid]
                    info = Pkg.RegistryHandling.registry_info(pkg)
                    for (v, uncompressed_data) in Pkg.RegistryHandling.uncompressed_data(info)
                        push!(all_versions_u, v)
                        all_compat_u[v] = uncompressed_data
                        union!(uuids, keys(uncompressed_data))
                    end
                end
            end
        end
    end

    return Resolve.Graph(all_versions, all_compat, uuid_to_name, reqs, fixed, #=verbose=# ctx.graph_verbose, ctx.julia_version),
           all_compat
end


    #=

    all_versions, all_compat = deps_graph(fixed, reqs)

    only non fixed -> all in registry
    deps, 
    graph = 
    resolve
    update manifest with v + 


    graph = deps_graph(...)
    versions = resolve()

    # @init m.version = v
    for v in versions
    =#

end
