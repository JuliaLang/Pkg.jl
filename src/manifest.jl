###########
# READING #
###########
function read_field(name::String, default, info, map)
    x = get(info, name, default)
    if default === nothing
        x === nothing && return nothing
    else
        x == default && return default
    end
    x isa String || pkgerror("Expected field `$name` to be a String.")
    return map(x)
end

read_pinned(::Nothing) = false
read_pinned(pinned::Bool) = pinned
read_pinned(::Any) = pkgerror("Expected field `pinned` to be a Boolean.")

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
    ret = String[]
    for dep in deps
        dep isa String || pkgerror("Expected `dep` entry to be a String.")
        push!(ret, dep)
    end
    return ret
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
    deps::Union{Vector{String}, Dict{String,UUID}}
end

normalize_deps(name, uuid, deps, raw_manifest) = deps
function normalize_deps(name, uuid, deps::Vector{String}, raw_manifest::Dict{String,Vector{Stage1}})
    if length(deps) != length(unique(deps))
        pkgerror("Duplicate entry in `$name=$uuid`'s `deps` field.")
    end
    final = Dict{String,UUID}()
    for dep in deps
        infos = get(raw_manifest, dep, nothing)
        if infos === nothing
            pkgerror("`$name=$uuid` depends on `$dep`, ",
                     "but no such entry exists in the manifest.")
        end
        # should have used dict format instead of vector format
        length(infos) == 1 || pkgerror("Invalid manifest format. ",
                                       "`$name=$uuid`'s dependency on `$dep` is ambiguous.")
        final[dep] = infos[1].uuid
    end
    return final
end

function validate_manifest(stage1::Dict{String,Vector{Stage1}}, julia_version, project_hash::Union{String,Nothing})
    # expand vector format deps
    for (name, infos) in stage1, info in infos
        info.entry.deps = normalize_deps(name, info.uuid, info.deps, stage1)
    end
    # invariant: all dependencies are now normalized to Dict{String,UUID}
    deps = Dict{UUID, PackageEntry}()
    for (name, infos) in stage1, info in infos
        deps[info.uuid] = info.entry
    end
    # now just verify the graph structure
    for (entry_uuid, entry) in deps, (name, uuid) in entry.deps
        dep_entry = get(deps, uuid, nothing)
        if dep_entry === nothing
            pkgerror("`$(entry.name)=$(entry_uuid)` depends on `$name=$uuid`, ",
                     "but no such entry exists in the manifest.")
        end
        if dep_entry.name != name
            pkgerror("`$(entry.name)=$(entry_uuid)` depends on `$name=$uuid`, ",
                     "but entry with UUID `$uuid` has name `$(dep_entry.name)`.")
        end
    end
    return Manifest(julia_version = julia_version, project_hash = project_hash, deps = deps)
end

function check_manifest_format_compat(raw::Dict)
    return haskey(raw, "julia_version") && haskey(raw, "project_hash")
end

function Manifest(raw::Dict)::Manifest
    julia_version = raw["julia_version"] == "nothing" ? nothing : VersionNumber(raw["julia_version"])
    project_hash = raw["project_hash"] == "nothing" ? nothing : raw["project_hash"]
    stage1 = Dict{String,Vector{Stage1}}()
    if haskey(raw, "deps")
        for (name, infos) in raw["deps"], info in infos
            entry = PackageEntry()
            entry.name = name
            uuid = nothing
            deps = nothing
            try
                entry.pinned      = read_pinned(get(info, "pinned", nothing))
                uuid              = read_field("uuid",          nothing, info, safe_uuid)::UUID
                entry.version     = read_field("version",       nothing, info, safe_version)
                entry.path        = read_field("path",          nothing, info, safe_path)
                entry.repo.source = read_field("repo-url",      nothing, info, identity)
                entry.repo.rev    = read_field("repo-rev",      nothing, info, identity)
                entry.repo.subdir = read_field("repo-subdir",   nothing, info, identity)
                entry.tree_hash   = read_field("git-tree-sha1", nothing, info, safe_SHA1)
                entry.uuid        = uuid
                deps = read_deps(get(info::Dict, "deps", nothing))
            catch
                # TODO: Should probably not unconditionally log something
                @error "Could not parse entry for `$name`"
                rethrow()
            end
            entry.other = info::Union{Dict,Nothing}
            stage1[name] = push!(get(stage1, name, Stage1[]), Stage1(uuid, entry, deps))
        end
        # by this point, all the fields of the `PackageEntry`s have been type casted
        # but we have *not* verified the _graph_ structure of the manifest
    end
    return validate_manifest(stage1, julia_version, project_hash)
end

function read_manifest(f_or_io::Union{String, IO})
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String))
        else
            if isfile(f_or_io)
                parse_toml(f_or_io)
            else
                return Manifest()
            end
        end
    catch e
        if e isa TOML.ParserError
            pkgerror("Could not parse manifest: ", sprint(showerror, e))
        end
        rethrow()
    end
    if check_manifest_format_compat(raw) == false
        raw = update_old_format_raw_manifest(raw)
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
            entry[key] = value
        end
    end

    unique_name = Dict{String,Bool}()
    for (uuid, entry) in manifest.deps
        unique_name[entry.name] = !haskey(unique_name, entry.name)
    end

    raw = Dict{String,Any}()
    raw["julia_version"] = manifest.julia_version
    raw["project_hash"] = manifest.project_hash
    raw["deps"] = Dict{String,Vector{Dict{String,Any}}}()
    for (uuid, entry) in manifest.deps
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
        repo_source = entry.repo.source
        if repo_source !== nothing && Sys.iswindows() && !isabspath(repo_source) && !isurl(repo_source)
            repo_source = join(splitpath(repo_source), "/")
        end
        entry!(new_entry, "repo-url", repo_source)
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
        push!(get!(raw["deps"], entry.name, Dict{String,Any}[]), new_entry)
    end
    return raw
end

function write_manifest(env::EnvCache)
    mkpath(dirname(env.manifest_file))
    write_manifest(env.manifest, env.manifest_file)
end
write_manifest(manifest::Manifest, manifest_file::AbstractString) =
    write_manifest(destructure(manifest), manifest_file)
function write_manifest(raw_manifest::Dict, manifest_file::AbstractString)
    str = sprint() do io
        print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
        TOML.print(io, raw_manifest, sorted=true) do x
            (typeof(x) in [String, Nothing, UUID, SHA1, VersionNumber]) && return string(x)
            error("unhandled type `$(typeof(x))`")
        end
    end
    write(manifest_file, str)
end

function update_old_format_raw_manifest(old_raw_manifest::Dict)
    new_raw_manifest = Dict{String,Any}()
    new_raw_manifest["julia_version"] = "nothing"
    new_raw_manifest["project_hash"] = "nothing"
    new_raw_manifest["deps"] = Dict{String,Vector{Any}}()
    for (key, value) in old_raw_manifest
        new_raw_manifest["deps"][key] = value
    end
    return new_raw_manifest
end

function update_old_format_manifest(manifest_path::String)
    old_raw_manifest = Types.parse_toml(manifest_path)
    new_raw_manifest = update_old_format_raw_manifest(old_raw_manifest)
    Types.write_manifest(new_raw_manifest, manifest_path)
end
