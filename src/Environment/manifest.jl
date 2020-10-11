struct GitRepoInfo
    rev::String
    url::String
    subdir::Union{Nothing, String}
end

struct ManifestPkg
    name::String
    uuid::UUID
    location_info::Union{Nothing, String, SHA1} # stdlib, path, tree_sha, respectively
    version::Union{Nothing, VersionNumber} # stdlib, version
    deps::Set{UUID}
    pinned::Bool
    repo_info::Union{Nothing, GitRepoInfo}
end

default_pinned() = false

struct Manifest
    filename::String
    pkgs::Dict{UUID, ManifestPkg}
    julia_version::Union{VersionNumber, Nothing}
end

function Base.copy(m::Manifest)
    Manifest(
        m.filename,
        copy(m.pkgs),
        m.julia_version,
    )
end

function Manifest(manifest_path::String)
    d = isfile(manifest_path) ? TOML.parsefile(manifest_path) : Dict{String, Any}()

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

    pkgs = Dict{UUID, ManifestPkg}()
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

            # Location info
            path = get(info, "path", nothing)::Union{String, Nothing}
            git_tree_sha1 = get(info, "git-tree-sha1", nothing)::Union{String, Nothing}
            if path !== nothing && git_tree_sha1 !== nothing
                # TODO: Error
            end
            location_info = nothing
            path !== nothing && (location_info = path)
            git_tree_sha1 !== nothing && (location_info = SHA1(git_tree_sha1))

            # Version
            version = get(info, "version", nothing)::Union{String, Nothing}
            version !== nothing && (version = VersionNumber(version))

            # Git repo info
            repo_rev = get(info, "repo-rev", nothing)::Union{Nothing, String}
            repo_url = get(info, "repo-url", nothing)::Union{Nothing, String}
            repo_subdir = get(info, "repo-subdir", nothing)::Union{Nothing, String}
            if (repo_rev === nothing) ⊻ (repo_url === nothing)
                error("todo")
            end
            repo = repo_rev !== nothing ? GitRepoInfo(repo_rev, repo_url::String, repo_subdir) : nothing

            # Pinned
            pinned = get(info, "pinned", default_pinned())::Bool

            pkg = ManifestPkg(name, uuid, location_info, version, uuids, pinned, repo)
            pkgs[uuid] = pkg
        end
    end
    # TODO: consistency check
    return Manifest(basename(manifest_path), pkgs, julia_version)
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
        if pkg.location_info isa String
            d_pkg["path"] = pkg.location_info
        elseif pkg.location_info isa SHA1
            d_pkg["git-tree-sha1"] = string(pkg.location_info)
        else
            @assert pkg.location_info === nothing
        end

        # Version
        if pkg.version !== nothing
            d_pkg["version"] = string(pkg.version)
        end

        # Git repo info
        if pkg.repo_info !== nothing
            repo = pkg.repo_info
            d_pkg["repo-rev"] = repo.rev
            d_pkg["repo-url"] = repo.url
            if repo.subdir !== nothing
                d_pkg["repo-subdir"] = repo.subdir
            end
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
function write_manifest(dir::String, m::Manifest)
    d = destructure(m)
    str = sprint() do io
        print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
        TOML.print(io, d, sorted=true)
    end
    write(joinpath(dir, m.filename), str)
end
