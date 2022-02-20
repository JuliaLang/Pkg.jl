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
        length(infos) == 1 || pkgerror("Invalid manifest format. ",
                                       "`$name=$uuid`'s dependency on `$dep` is ambiguous.")
        final[dep] = infos[1].uuid
    end
    return final
end

function validate_manifest(julia_version::Union{Nothing,VersionNumber}, manifest_format::VersionNumber, stage1::Dict{String,Vector{Stage1}}, other::Dict{String, Any})
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
    return Manifest(; julia_version, manifest_format, deps, other)
end

function Manifest(raw::Dict, f_or_io::Union{String, IO})::Manifest
    julia_version = haskey(raw, "julia_version") ? VersionNumber(raw["julia_version"]) : nothing
    manifest_format = VersionNumber(raw["manifest_format"])
    if !in(manifest_format.major, 1:2)
        if f_or_io isa IO
            @warn "Unknown Manifest.toml format version detected in streamed manifest. Unexpected behavior may occur" manifest_format
        else
            @warn "Unknown Manifest.toml format version detected in file `$(f_or_io)`. Unexpected behavior may occur" manifest_format maxlog = 1 _id = Symbol(f_or_io)
        end
    end
    stage1 = Dict{String,Vector{Stage1}}()
    if haskey(raw, "deps") # deps field doesn't exist if there are no deps
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
                @debug "Could not parse manifest entry for `$name`" f_or_io
                rethrow()
            end
            entry.other = info::Union{Dict,Nothing}
            stage1[name] = push!(get(stage1, name, Stage1[]), Stage1(uuid, entry, deps))
        end
        # by this point, all the fields of the `PackageEntry`s have been type casted
        # but we have *not* verified the _graph_ structure of the manifest
    end
    other = Dict{String, Any}()
    for (k, v) in raw
        if k in ("julia_version", "deps", "manifest_format")
            continue
        end
        other[k] = v
    end
    return validate_manifest(julia_version, manifest_format, stage1, other)
end

function read_manifest(f_or_io::Union{String, IO})
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String))
        else
            isfile(f_or_io) ? parse_toml(f_or_io) : return Manifest()
        end
    catch e
        if e isa TOML.ParserError
            pkgerror("Could not parse manifest: ", sprint(showerror, e))
        end
        rethrow()
    end
    if Base.is_v1_format_manifest(raw)
        raw = convert_v1_format_manifest(raw)
    end
    return Manifest(raw, f_or_io)
end

function convert_v1_format_manifest(old_raw_manifest::Dict)
    new_raw_manifest = Dict{String, Any}(
            "deps" => old_raw_manifest,
            "manifest_format" => "1.0.0" # must be a string here to match raw dict
            # don't set julia_version as it is unknown in old manifests
        )
    return new_raw_manifest
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
    for (uuid, entry) in manifest
        unique_name[entry.name] = !haskey(unique_name, entry.name)
    end

    # maintain the format of the manifest when writing
    if manifest.manifest_format.major == 1
        raw = Dict{String,Vector{Dict{String,Any}}}()
    elseif manifest.manifest_format.major == 2
        raw = Dict{String,Any}()
        if !isnothing(manifest.julia_version) # don't write julia_version if nothing
            raw["julia_version"] = manifest.julia_version
        end
        raw["manifest_format"] = string(manifest.manifest_format.major, ".", manifest.manifest_format.minor)
        raw["deps"] = Dict{String,Vector{Dict{String,Any}}}()
        for (k, v) in manifest.other
            raw[k] = v
        end
    end

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
        if manifest.manifest_format.major == 1
            push!(get!(raw, entry.name, Dict{String,Any}[]), new_entry)
        elseif manifest.manifest_format.major == 2
            push!(get!(raw["deps"], entry.name, Dict{String,Any}[]), new_entry)
        end
    end
    return raw
end

function write_manifest(env::EnvCache)
    mkpath(dirname(env.manifest_file))
    write_manifest(env.manifest, env.manifest_file)
end
function write_manifest(manifest::Manifest, manifest_file::AbstractString)
    if manifest.manifest_format.major == 1
        @warn """The active manifest file at `$(manifest_file)` has an old format that is being maintained.
            To update to the new format, which is supported by Julia versions ≥ 1.6.2, run `Pkg.upgrade_manifest()` which will upgrade the format without re-resolving.
            To then record the julia version re-resolve with `Pkg.resolve()` and if there are resolve conflicts consider `Pkg.update()`.""" maxlog = 1 _id = Symbol(manifest_file)
    end
    return write_manifest(destructure(manifest), manifest_file)
end
function write_manifest(io::IO, manifest::Manifest)
    return write_manifest(io, destructure(manifest))
end
function write_manifest(io::IO, raw_manifest::Dict)
    print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
    TOML.print(io, raw_manifest, sorted=true) do x
        (typeof(x) in [String, Nothing, UUID, SHA1, VersionNumber]) && return string(x)
        error("unhandled type `$(typeof(x))`")
    end
    return nothing
end
function write_manifest(raw_manifest::Dict, manifest_file::AbstractString)
    str = sprint(write_manifest, raw_manifest)
    write(manifest_file, str)
end

############
# METADATA #
############

function check_warn_manifest_julia_version_compat(manifest::Manifest, manifest_file::String)
    isempty(manifest.deps) && return
    if manifest.manifest_format < v"2"
        @warn """The active manifest file is an older format with no julia version entry. Dependencies may have \
        been resolved with a different julia version.""" maxlog = 1 _file = manifest_file _line = 0 _module = nothing
        return
    end
    v = manifest.julia_version
    if v === nothing
        @warn """The active manifest file is missing a julia version entry. Dependencies may have \
        been resolved with a different julia version.""" maxlog = 1 _file = manifest_file _line = 0 _module = nothing
        return
    end
    if Base.thisminor(v) != Base.thisminor(VERSION)
        @warn """The active manifest file has dependencies that were resolved with a different julia \
        version ($(manifest.julia_version)). Unexpected behavior may occur.""" maxlog = 1 _file = manifest_file _line = 0 _module = nothing
    end
end
