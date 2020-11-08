module Resolving

using ..Environments
using ..RegistryHandling
using ..Resolve
using ..Versions

using .Environments: Environment, Project, Manifest, Dependency
using .RegistryHandling: Registry

using UUIDs
import Base: SHA1


const STDLIBS = Dict{UUID, Project}()
# m.uuid isa stdlib && return joinpath(Sys.STDLIB, pkg.name)
function load_stdlibs()
    empty!(STDLIBS)
    for name in readdir(Sys.STDLIB)
        # TODO Check if project file exist?
        env = Environment(joinpath(Sys.STDLIB, name))
        env.project === nothing && continue
        @assert env.project.pkg !== nothing
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
    fixed_pkgs = FixedPkg[]
    pkg = env.project.pkg
    if pkg !== nothing
        push!(fixed_pkgs, FixedPkg(pkg.uuid, pkg.name, pkg.version, env.project.deps))
    end
    # @assert is_fixed_instantiated(env.manifest)
    m = env.manifest
    for (uuid, pkg) in m.pkgs
        #loc = pkg.location_info
        #is_fixed = loc isa GitLocation || loc isa String
        if Environments.is_fixed(pkg)
            # TODO: Recursive
            path = pathof(pkg)  
            @assert path !== nothing
            @show path
            env = Environment(path)
            # TODO; check if one of these deps are unknown and then if the package
            # has a manifest and use from there
            push!(fixed_pkgs, FixedPkg(uuid, pkg.name, pkg.version, env.project.deps))
        end
    end
    return fixed_pkgs
end

#=
function resolve(env::Environment, regs::Vector{Registry})
    # first collect fixed (those tracking by path or git-rev)

    # then collect fixed based on resolver strategy

    # then collect fixed based on current package

    # then collect required from project
    # with a 

    # then recurse registry
end
=#

get_or_make!(d::Dict{K,V}, k::K) where {K,V} = get!(d, k) do; V() end

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
    
    @assert length(Set(pkg.uuid for pkg in fixed)) == length(fixed) "duplicated uuid collected"
    for pkg in fixed
        fixed_resolve[pkg.uuid] = Resolve.Fixed(pkg.version, Dict(dep.uuid => dep.compat for (uuid, dep) in pkg.deps))
    end

    deps_graph(regs, reqs, fixed_resolve)
end

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
            stdlib = get(STDLIBS, uuid, nothing)
            if stdlib !== nothing
                v = something(stdlib.pkg.version, VERSION)
                push!(all_versions_u, v)

                # TODO look at compat section for stdlibs?
                all_compat_u[v] = Dict(uuid => dep.compat for (uuid, dep) in stdlib.deps)
            else
                for reg in registries
                    pkg = get(reg, uuid, nothing)
                    pkg === nothing && continue
                    info = RegistryHandling.registry_info(pkg)
                    for (v, compat_info) in RegistryHandling.compat_info(info)
                        # Filter yanked and if we are in offline mode also downloaded packages
                        # TODO, pull this into a function
                        RegistryHandling.isyanked(info, v) && continue
                        #=
                        if Pkg.OFFLINE_MODE[]
                            pkg_spec = PackageSpec(name=pkg.name, uuid=pkg.uuid, version=v, tree_hash=Registry.treehash(info, v))
                            is_package_downloaded(env.project_file, pkg_spec) || continue
                        end
                        =#

                        push!(all_versions_u, v)
                        all_compat_u[v] = compat_info
                        union!(uuids, keys(compat_info))
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
