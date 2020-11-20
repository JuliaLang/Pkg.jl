module Resolving

using ..Environments
using ..RegistryHandling
using ..Resolve
using ..Versions

import ..PackageSpec
import ..Pkg # remove

using .Environments: Environment, Project, Manifest, Dependency, is_fixed
using .RegistryHandling: Registry

using UUIDs
import Base: SHA1


stdlib_dir() = normpath(joinpath(Sys.BINDIR::String, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"))
stdlib_path(stdlib::String) = joinpath(stdlib_dir(), stdlib)


const _STDLIBS = Ref{Dict{UUID, Project}}()
# m.uuid isa stdlib && return joinpath(Sys.STDLIB, pkg.name)
function load_stdlibs()
    isassigned(_STDLIBS) && return
    stdlibs = Dict{UUID, Project}()
    for name in readdir(stdlib_dir())
        # TODO Check if project file exist?
        path = stdlib_path(name)
        env = Environment(path)
        env.project === nothing && continue
        if env.project.pkg === nothing
            error("expected a project for stdlib ", name, " at ", repr(path))
        end
        stdlibs[env.project.pkg.uuid] = env.project
    end
    _STDLIBS[] = stdlibs
    return
end
stdlibs() = (load_stdlibs(); _STDLIBS[])
is_stdlib(uuid::UUID) = uuid in keys(stdlibs())


# TODO: Remove
struct FixedPkg
    uuid::UUID
    name::String
    version::VersionNumber
    deps::Dict{UUID, Dependency}
end


#recurse_path_pkgs!(env::Environment)

function collect_fixed_pkgs(env::Environment)
    # If the environment is a package, it is fixed
    fixed_pkgs = Dict{UUID, FixedPkg}()
    pkg = env.project.pkg
    if pkg !== nothing
        fixed_pkgs[pkg.uuid] = FixedPkg(pkg.uuid, pkg.name, pkg.version, env.project.deps)
    end

    # Collect all fixed packages from the manifest
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

             #   if env.manifest !== nothing


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

function resolve(env′::Environment, regs::Vector{Registry}, extra_packages::Vector{PackageSpec} = PackageSpec[])
    load_stdlibs() # TODO: Remove
    julia_version = VERSION

    env = copy(env′)

    # Overwrite the packages in the environment with the extra packages
    for pkg in extra_packages
        project = env.project
        dep′ = get(project.deps, pkg.uuid, nothing)
        compat, compat_str = dep′ === nothing ? (VersionSpec(), "") : (dep′.compat, dep′.compat_str)
        dep = Environments.Dependency(pkg.name, pkg.uuid, compat, compat_str)
        project.deps[pkg.uuid] = dep
    end

    # This collect all fixed packages, and also puts newly discovered fixed packages from
    # recursively walking manifests into the manifest of env
    fixed = collect_fixed_pkgs(env)

    # TODO, resolver policy
    reqs = Resolve.Requires(pkg.uuid => pkg.compat for pkg in values(env.project.deps))

    delete!(reqs, JULIA_UUID)
    fixed_resolve = Dict{UUID,Resolve.Fixed}()

    for (_, pkg) in fixed
        fixed_resolve[pkg.uuid] = Resolve.Fixed(pkg.version, Dict(dep.uuid => dep.compat for (uuid, dep) in pkg.deps))
    end

    all_versions, all_compat = deps_graph(regs, reqs, fixed_resolve)
    all_compat[JULIA_UUID] = Dict(julia_version => Dict{VersionNumber,Dict{UUID,VersionSpec}}())
    all_versions[JULIA_UUID] = Set([julia_version])

    uuid_to_name = Dict{UUID, String}()
    foreach(dep -> uuid_to_name[dep.uuid] = dep.name, values(env.project.deps))
    foreach(dep -> uuid_to_name[dep.uuid] = dep.name, values(fixed))
    for uuid in keys(all_compat)
        uuid in keys(uuid_to_name) && continue
        if is_stdlib(uuid)
            stdlib = stdlibs()[uuid]
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

    # Create a new Project + manifest

    # After the resolve step the following changes can have been made:
    #   packages can have been removed
    #   package can have changed version / changed deps
    #   packages can have been added
    # fixed packages been changed

    m_new = env.manifest
    # for pkg in input pkgs
    # if is_fixed

    foreach(uuid -> delete!(m_new.pkgs, uuid), keys(fixed))
    foreach(uuid -> delete!(m_new.pkgs, uuid), keys(resolved_versions))
    for (uuid, v) in resolved_versions
        uuid == JULIA_UUID && continue
        # The registry could have been changed so even if we get
        # the same version here, we still need to update the
        # dependencies
        pkg = get(m_new, uuid, nothing)
        name = uuid_to_name[uuid]
        sha = tree_hash(regs, uuid, v)
        pinned = pkg === nothing ? false : pkg.pinned
        deps = keys(all_compat[uuid][v])
        m_new.pkgs[uuid] = Environments.ManifestPkg(name, uuid, sha, v, deps, pinned)
    end

    return env
end

function tree_hash(regs::Vector{Registry}, uuid::UUID, v::VersionNumber)
    hash = nothing
    for reg in regs
        reg_pkg = get(reg, uuid, nothing)
        reg_pkg === nothing && continue
        pkg_info = RegistryHandling.registry_info(reg_pkg)
        version_info = get(pkg_info.version_info, v, nothing)
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
                    reqs::Resolve.Requires, fixed::Dict{UUID,Resolve.Fixed};
                    julia_version::Union{Nothing, VersionNumber}=VERSION, offline_mode::Bool=false)
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
                proj = stdlibs()[uuid]

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
                        RegistryHandling.isyanked(info, v) && continue
                        #=
                        if offline_mode
                            uuid=pkg.uuid
                            tree_hash=Pkg.RegistryHandling.treehash(info, v)
                            isdir(...) || continue
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
    return all_versions, all_compat
end

end # module
