###########
# READING #
###########
function read_field(name::String, default, info, map)
    x = get(info, name, default)
    x == default && return default
    x isa String || pkgerror("Expected field `$name` to be a String.")
    return map(x)
end

read_pinned(::Nothing) = false
read_pinned(pinned::Bool) = pinned
read_pinned(pinned) = pkgerror("Expected field `pinned` to be a Boolean.")

function safe_SHA1(sha::String)
    try sha = SHA1(sha)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `git-tree-sha1` field as a SHA.")
    end
    return sha
end

function safe_uuid(uuid::String)::UUID
    try uuid = UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `uuid` field as a UUID.")
    end
    return uuid
end

function safe_bool(bool::String)
    try bool = parse(Bool, bool)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `pinned` field as a Bool.")
    end
    return bool
end

# note: returns raw version *not* parsed version
function safe_version(version::String)::VersionNumber
    try version = VersionNumber(version)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `version` as a `VersionNumber`.")
    end
    return version
end

# turn /-paths into \-paths on Windows
function safe_path(path::String)
    if Sys.iswindows() && !isabspath(path)
        path = joinpath(split(path, "/")...)
    end
    return path
end

read_deps(::Nothing) = Dict{String, UUID}()
read_deps(deps) = pkgerror("Expected `deps` field to be either a list or a table.")
function read_deps(deps::AbstractVector)
    for dep in deps
        dep isa String || pkgerror("Expected `dep` entry to be a String.")
    end
    return deps
end
function read_deps(raw::Dict{String, Any})::Dict{String,UUID}
    deps = Dict{String,UUID}()
    for (name, uuid) in raw
        deps[name] = safe_uuid(uuid)
    end
    return deps
end

struct Stage1
    uuid::UUID
    entry::PackageEntry
    deps::Union{AbstractVector{<:AbstractString}, Dict{String,UUID}}
end

normalize_deps(name, uuid, deps, manifest) = deps
function normalize_deps(name, uuid, deps::Vector{String}, manifest::Dict{String,Vector{Stage1}})
    if length(deps) != length(unique(deps))
        pkgerror("Duplicate entry in `$name=$uuid`'s `deps` field.")
    end
    final = Dict{String,UUID}()
    for dep in deps
        infos = get(manifest, dep, nothing)
        if infos === nothing
            pkgerror("`$name=$uuid` depends on `$dep`, ",
                     "but no such entry exists in the manifest.")
        end
        # should have used dict format instead of vector format
        length(infos) == 1 || pkgerror("Invalid manfiest format. ",
                                       "`$name=$uuid`'s dependency on `$dep` is ambiguous.")
        final[dep] = infos[1].uuid
    end
    return final
end

function validate_manifest(stage1::Dict{String,Vector{Stage1}})
    # expand vector format deps
    for (name, infos) in stage1, info in infos
        info.entry.deps = normalize_deps(name, info.uuid, info.deps, stage1)
    end
    # invariant: all dependencies are now normalized to Dict{String,UUID}
    manifest = Dict{UUID, PackageEntry}()
    for (name, infos) in stage1, info in infos
        manifest[info.uuid] = info.entry
    end
    # now just verify the graph structure
    for (entry_uuid, entry) in manifest, (name, uuid) in entry.deps
        dep_entry = get(manifest, uuid, nothing)
        if dep_entry === nothing
            pkgerror("`$(entry.name)=$(entry_uuid)` depends on `$name=$uuid`, ",
                     "but no such entry exists in the manifest.")
        end
        if dep_entry.name != name
            pkgerror("`$(entry.name)=$(entry_uuid)` depends on `$name=$uuid`, ",
                     "but entry with UUID `$uuid` has name `$(dep_entry.name)`.")
        end
    end
    return manifest
end

function Manifest(raw::Dict)::Manifest
    stage1 = Dict{String,Vector{Stage1}}()
    for (name, infos) in raw, info in infos
        entry = PackageEntry()
        entry.name = name
        uuid = nothing
        deps = nothing
        try
            entry.pinned      = read_pinned(get(info, "pinned", nothing))
            uuid              = read_field("uuid",          nothing, info, safe_uuid)
            entry.version     = read_field("version",       nothing, info, safe_version)
            entry.path        = read_field("path",          nothing, info, safe_path)
            entry.repo.source = read_field("repo-url",      nothing, info, identity)
            entry.repo.rev    = read_field("repo-rev",      nothing, info, identity)
            entry.repo.subdir = read_field("repo-subdir",   nothing, info, identity)
            entry.tree_hash   = read_field("git-tree-sha1", nothing, info, safe_SHA1)
            deps = read_deps(get(info, "deps", nothing))
        catch
            # TODO: Should probably not unconditionally log something
            @error "Could not parse entry for `$name`"
            rethrow()
        end
        entry.other = info
        stage1[name] = push!(get(stage1, name, Stage1[]), Stage1(uuid, entry, deps))
    end
    # by this point, all the fields of the `PackageEntry`s have been type casted
    # but we have *not* verified the _graph_ structure of the manifest
    return validate_manifest(stage1)
end

function read_manifest(path_or_stream)
    local raw
    try
        if path_or_stream isa String
            path = path_or_stream
            isfile(path) || return Dict{UUID,PackageEntry}()
            raw = TOML.parsefile(path)
        else
            raw = TOML.parse(path_or_stream)
        end
    catch err
        path = path_or_stream isa String ? path_or_stream : ""
        if err isa TOML.ParserError
            pkgerror("Could not parse manifest $path: $(err.msg)")
        elseif all(x -> x isa TOML.ParserError, err)
            pkgerror("Could not parse manifest $path: $err")
        else
            rethrow()
        end
    end
    return Manifest(raw)
end

###########
# WRITING #
###########
function destructure(manifest::Manifest)::Dict
    function entry!(entry, key, value; default=nothing)
        if value == default
            delete!(entry, key)
        else
            entry[key] = value isa TOML.TYPE ? value : string(value)
        end
    end

    unique_name = Dict{String,Bool}()
    for (uuid, entry) in manifest
        unique_name[entry.name] = !haskey(unique_name, entry.name)
    end

    raw = Dict{String,Any}()
    for (uuid, entry) in manifest
        new_entry = something(entry.other, Dict{String,Any}())
        new_entry["uuid"] = string(uuid)
        entry!(new_entry, "version", entry.version)
        entry!(new_entry, "git-tree-sha1", entry.tree_hash)
        entry!(new_entry, "pinned", entry.pinned; default=false)
        path = entry.path
        if path !== nothing && Sys.iswindows() && !isabspath(path)
            path = join(splitpath(path), "/")
        end
        entry!(new_entry, "path", path)
        entry!(new_entry, "repo-url", entry.repo.source)
        entry!(new_entry, "repo-rev", entry.repo.rev)
        entry!(new_entry, "repo-subdir", entry.repo.subdir)
        if isempty(entry.deps)
            delete!(new_entry, "deps")
        else
            if all(dep -> unique_name[first(dep)], entry.deps)
                new_entry["deps"] = sort(collect(keys(entry.deps)))
            else
                new_entry["deps"] = Dict{String,String}()
                for (name, uuid) in entry.deps
                    new_entry["deps"][name] = string(uuid)
                end
            end
        end
        push!(get!(raw, entry.name, Dict{String,Any}[]), new_entry)
    end
    return raw
end

function write_manifest(env::EnvCache)
    mkpath(dirname(env.manifest_file))
    write_manifest(env.manifest, env.manifest_file)
end
write_manifest(manifest::Manifest, manifest_file::AbstractString) =
    write_manifest(destructure(manifest), manifest_file)
function write_manifest(manifest::Dict, manifest_file::AbstractString)
    io = IOBuffer()
    print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
    TOML.print(io, manifest, sorted=true)
    open(f -> write(f, seekstart(io)), manifest_file; truncate=true)
end
