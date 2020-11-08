struct GitLocation
    rev::String
    url::String
    subdir::Union{Nothing, String}
    tree_hash::SHA1
end

struct ManifestPkg{T}
    name::String
    uuid::UUID
    location_info::Union{Nothing, String, SHA1, GitLocation} # stdlib, path, tree_sha, git-repo
    # make lazy..?
    version::Union{Nothing, VersionNumber} # stdlib, version
    deps::Set{UUID}
    pinned::Bool
end

default_pinned() = false

struct Manifest{T}
    path::String
    pkgs::Dict{UUID, ManifestPkg{T}}
    julia_version::Union{VersionNumber, Nothing}
end

Base.get(m::Manifest, u::UUID, default) = get(m.pkgs, u, default)
Base.getindex(m::Manifest, u::UUID) = m.pkgs[u]

function Base.copy(m::Manifest)
    Manifest(
        m.path,
        copy(m.pkgs),
        m.julia_version,
    )
end

function Manifest(manifest_path::String)
    manifest_path = realpath(manifest_path)

    d = TOML.parsefile(manifest_path)

    # We first check if we have a condensed form, in that case
    # we collect all the name => uuid mappings
    name_to_uuid = Dict{String, UUID}()
    condensed = nothing
    julia_version = nothing
    for (name, infos) in d
        if name === "julia_version"
            julia_version = VersionNumber(infos::String)
            continue
        end

        infos::Vector{Any}
        for info in infos
            info::Dict{String, Any}
            # We only use this in the compressed case so
            # it is fine to overwrite the key name
            name_to_uuid[name] = UUID(info["uuid"]::String)
        end
    end

    pkgs = Dict{UUID, ManifestPkg{VersionNumber}}()
    for (name, infos) in d
        for info in infos
            info::Dict{String, Any}

            # UUID
            uuid = UUID(info["uuid"]::String)

            # Deps
            # The deps can be given in condensed form if there are no
            # packages with duplicated names in the manifest
            deps_toml = get(info, "deps", nothing)::Union{Nothing, Vector{String}, Dict{String, Any}}
            uuids = Set{UUID}()
            if deps_toml isa Vector{String}
                for dep in deps_toml
                    push!(uuids, name_to_uuid[dep])
                end
            elseif deps_toml isa Dict{String, Any}
                for (_, uuid) in deps_toml
                    push!(uuids, UUID(uuid::String))
                end
            else
                @assert deps_toml === nothing
            end

            # Git repo info
            repo_rev = get(info, "repo-rev", nothing)::Union{Nothing, String}
            repo_url = get(info, "repo-url", nothing)::Union{Nothing, String}
            repo_subdir = get(info, "repo-subdir", nothing)::Union{Nothing, String}
            if (repo_rev === nothing) ⊻ (repo_url === nothing)
                error("todo")
            end

            # Location info
            path = get(info, "path", nothing)::Union{String, Nothing}
            tree_hash = get(info, "git-tree-sha1", nothing)::Union{String, Nothing}

            if repo_rev !== nothing && path != nothing
                # TODO: Error
            end

            if repo_rev !== nothing && tree_hash !== nothing
                # TODO: Error
            end

            if path !== nothing && tree_hash !== nothing
                # TODO: Error
            end

            location_info = nothing

            if repo_rev !== nothing
                location_info = GitLocation(repo_rev, repo_url, repo_subdir, SHA1(tree_hash))
            elseif path !== nothing
                location_info = path
            elseif tree_hash !== nothing
                location_info = SHA1(tree_hash)
            else
                # assert stdlib?
            end

            # Version
            version = get(info, "version", nothing)::Union{String, Nothing}
            version !== nothing && (version = VersionNumber(version))

            # Pinned
            pinned = get(info, "pinned", default_pinned())::Bool

            pkg = ManifestPkg{VersionNumber}(name, uuid, location_info, version, uuids, pinned)
            pkgs[uuid] = pkg
        end
    end
    # TODO: consistency check
    return Manifest(manifest_path, pkgs, julia_version)
end

prune_manifest!(m::Manifest, keep::Set{UUID}) = _prune_manifest!(m, copy(keep))
function _prune_manifest!(m::Manifest, keep::Set{UUID})
    while !isempty(keep)
        clean = true
        for (uuid, pkg) in m.pkgs
            uuid in keep || continue
            for dep_uuid in pkg.deps
                dep_uuid in keep && continue
                push!(keep, dep_uuid)
                clean = false
            end
        end
        clean && break
    end
    deletions = setdiff(keys(m.pkgs), keep)
    foreach(k -> delete!(m.pkgs, k), deletions)
    return m
end


function destructure(m::Manifest)
    d = Dict{String, Any}()

    # Deps
    count = Dict{String, Int}()
    for (uuid, pkg) in m.pkgs
        n = get!(count, pkg.name, 0)
        count[pkg.name] = n+1
    end
    unique_names = Set(findall(isequal(1), count))

    for (uuid, pkg) in m.pkgs
        infos = get!(Vector{Any}, d, pkg.name)
        d_pkg = Dict{String, Any}()
        push!(infos, d_pkg)

        # UUID
        d_pkg["uuid"] = string(pkg.uuid)

        # Deps
        if !isempty(pkg.deps)
            write_condensed = all(in(unique_names), (m.pkgs[uuid].name for uuid in pkg.deps))
            if write_condensed
                d_pkg["deps"] = sort!(String[m.pkgs[uuid].name for uuid in pkg.deps])
            else
                d_pkg["deps"] = Dict{String, Any}(m.pkgs[uuid].name => string(uuid) for uuid in pkg.deps)
            end
        end

        # Location info
        loc = pkg.location_info
        if loc isa String
            d_pkg["path"] = loc
        elseif loc isa SHA1
            d_pkg["git-tree-sha1"] = string(loc)
        elseif loc isa GitLocation
            d_pkg["git-tree-sha1"] = string(loc.tree_hash)
            d_pkg["repo-rev"] = loc.rev
            d_pkg["repo-url"] = loc.url
            if loc.subdir !== nothing
                d_pkg["subdir"] = loc.subdir
            end
        else
            @assert loc === nothing
        end

        # Version
        if pkg.version !== nothing
            d_pkg["version"] = string(pkg.version)
        end

        # Pinned
        if pkg.pinned !== default_pinned()
            d_pkg["pinned"] = pkg.pinned
        end
    end

    if m.julia_version !== nothing
        d["julia_version"] = string(m.julia_version)
    end

    return d
end

# TODO: use this when writing the manifest?
# default_version = VersionNumber(VERSION.major, VERSION.minor, VERSION.patch)
write_manifest(m::Manifest) = write_manifest(m.path, m)
function write_manifest(path::String, m::Manifest)
    d = destructure(m)
    str = sprint() do io
        print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
        TOML.print(io, d, sorted=true)
    end
    write(path, str)
end

# "API"

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



function Base.pathof(m::ManifestPkg)
    m.location_info isa String && return m.location_info
    m.location_info isa GitLocation && return find_installed(m.name, m.uuid, m.location_info.tree_hash)
    # is_stdlib(m.uuid) && return joinpath(Sys.STDLIB, pkg.name)
    find_installed(m.name, m.uuid, m.tree_hash)
end

is_fixed(m::ManifestPkg) = m.location_info isa String || m.location_info isa GitLocation || m.pinned

