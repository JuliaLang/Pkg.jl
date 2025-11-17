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

function read_pinned(pinned)
    pinned === nothing && return false
    pinned isa Bool && return pinned
    pkgerror("Expected field `pinned` to be a Boolean.")
end

function safe_SHA1(sha::String)
    try
        sha = SHA1(sha)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `git-tree-sha1` field as a SHA.")
    end
    return sha
end

function safe_uuid(uuid::String)::UUID
    try
        uuid = UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `uuid` field as a UUID.")
    end
    return uuid
end

function safe_bool(bool::String)
    try
        bool = parse(Bool, bool)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse `pinned` field as a Bool.")
    end
    return bool
end

# note: returns raw version *not* parsed version
function safe_version(version::String)::VersionNumber
    try
        version = VersionNumber(version)
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

function read_registry_entry(id::String, info::Dict{String, Any})
    uuid_val = get(info, "uuid", nothing)
    uuid_val isa String || pkgerror("Registry entry `$id` is missing a string `uuid` field.")
    uuid = safe_uuid(uuid_val)
    url_val = get(info, "url", nothing)
    url_val === nothing || url_val isa String || pkgerror("Field `url` for registry `$id` must be a String.")

    return ManifestRegistryEntry(
        id = id,
        uuid = uuid,
        url = url_val === nothing ? nothing : String(url_val),
    )
end

function registry_entry_toml(entry::ManifestRegistryEntry)
    d = Dict{String, Any}()
    d["uuid"] = string(entry.uuid)
    entry.url === nothing || (d["url"] = entry.url)
    return d
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
function read_deps(raw::Dict{String, Any})::Dict{String, UUID}
    deps = Dict{String, UUID}()
    for (name, uuid) in raw
        deps[name] = safe_uuid(uuid)
    end
    return deps
end

read_apps(::Nothing) = Dict{String, AppInfo}()
read_apps(::Any) = pkgerror("Expected `apps` field to be a Dict")
function read_apps(apps::Dict)
    appinfos = Dict{String, AppInfo}()
    for (appname, app) in apps
        submodule = get(app, "submodule", nothing)
        julia_flags_raw = get(app, "julia_flags", nothing)
        julia_flags = if julia_flags_raw === nothing
            String[]
        else
            String[flag::String for flag in julia_flags_raw]
        end
        appinfo = AppInfo(
            appname::String,
            app["julia_command"]::String,
            submodule,
            julia_flags,
            app
        )
        appinfos[appinfo.name] = appinfo
    end
    return appinfos
end

read_exts(::Nothing) = Dict{String, Union{String, Vector{String}}}()
function read_exts(raw::Dict{String, Any})
    exts = Dict{String, Union{String, Vector{String}}}()
    for (key, val) in raw
        val isa Union{String, Vector{String}} || pkgerror("Expected `ext` entry to be a `Union{String, Vector{String}}`.")
        exts[key] = val
    end
    return exts
end

struct Stage1
    uuid::UUID
    entry::PackageEntry
    deps::Union{Vector{String}, Dict{String, UUID}}
    weakdeps::Union{Vector{String}, Dict{String, UUID}}
end

normalize_deps(name, uuid, deps, manifest; isext = false) = deps
function normalize_deps(name, uuid, deps::Vector{String}, manifest::Dict{String, Vector{Stage1}}; isext = false)
    if length(deps) != length(unique(deps))
        pkgerror("Duplicate entry in `$name=$uuid`'s `deps` field.")
    end
    final = Dict{String, UUID}()
    for dep in deps
        infos = get(manifest, dep, nothing)
        if !isext
            if infos === nothing
                pkgerror(
                    "`$name=$uuid` depends on `$dep`, ",
                    "but no such entry exists in the manifest."
                )
            end
        end
        # should have used dict format instead of vector format
        if isnothing(infos) || length(infos) != 1
            pkgerror(
                "Invalid manifest format. ",
                "`$name=$uuid`'s dependency on `$dep` is ambiguous."
            )
        end
        final[dep] = infos[1].uuid
    end
    return final
end

function validate_manifest(julia_version::Union{Nothing, VersionNumber}, project_hash::Union{Nothing, SHA1}, manifest_format::VersionNumber, stage1::Dict{String, Vector{Stage1}}, other::Dict{String, Any}, registries::Dict{String, ManifestRegistryEntry})
    # expand vector format deps
    for (name, infos) in stage1, info in infos
        info.entry.deps = normalize_deps(name, info.uuid, info.deps, stage1)
    end
    for (name, infos) in stage1, info in infos
        info.entry.weakdeps = normalize_deps(name, info.uuid, info.weakdeps, stage1; isext = true)
    end
    # invariant: all dependencies are now normalized to Dict{String,UUID}
    deps = Dict{UUID, PackageEntry}()
    for (name, infos) in stage1, info in infos
        deps[info.uuid] = info.entry
    end
    # now just verify the graph structure
    for (entry_uuid, entry) in deps
        for (deptype, isext) in [(entry.deps, false), (entry.weakdeps, true)]
            for (name, uuid) in deptype
                dep_entry = get(deps, uuid, nothing)
                if !isext
                    if dep_entry === nothing
                        pkgerror(
                            "`$(entry.name)=$(entry_uuid)` depends on `$name=$uuid`, ",
                            "but no such entry exists in the manifest."
                        )
                    end
                    if dep_entry.name != name
                        pkgerror(
                            "`$(entry.name)=$(entry_uuid)` depends on `$name=$uuid`, ",
                            "but entry with UUID `$uuid` has name `$(dep_entry.name)`."
                        )
                    end
                end
            end
        end
    end
    return Manifest(; julia_version, project_hash, manifest_format, deps, registries, other)
end

function Manifest(raw::Dict{String, Any}, f_or_io::Union{String, IO})::Manifest
    julia_version = haskey(raw, "julia_version") ? VersionNumber(raw["julia_version"]::String) : nothing
    project_hash = haskey(raw, "project_hash") ? SHA1(raw["project_hash"]::String) : nothing

    manifest_format = VersionNumber(raw["manifest_format"]::String)
    if !in(manifest_format.major, 1:2)
        if f_or_io isa IO
            @warn "Unknown Manifest.toml format version detected in streamed manifest. Unexpected behavior may occur" manifest_format
        else
            @warn "Unknown Manifest.toml format version detected in file `$(f_or_io)`. Unexpected behavior may occur" manifest_format maxlog = 1 _id = Symbol(f_or_io)
        end
    end
    stage1 = Dict{String, Vector{Stage1}}()
    if haskey(raw, "deps") # deps field doesn't exist if there are no deps
        deps_raw = raw["deps"]::Dict{String, Any}
        for (name::String, infos) in deps_raw
            infos = infos::Vector{Any}
            for info in infos
                info = info::Dict{String, Any}
                entry = PackageEntry()
                entry.name = name
                uuid = nothing
                deps = nothing
                weakdeps = nothing
                try
                    entry.pinned = read_pinned(get(info, "pinned", nothing))
                    uuid = read_field("uuid", nothing, info, safe_uuid)::UUID
                    entry.version = read_field("version", nothing, info, safe_version)
                    entry.path = read_field("path", nothing, info, safe_path)
                    entry.repo.source = read_field("repo-url", nothing, info, identity)
                    entry.repo.rev = read_field("repo-rev", nothing, info, identity)
                    entry.repo.subdir = read_field("repo-subdir", nothing, info, identity)
                    entry.tree_hash = read_field("git-tree-sha1", nothing, info, safe_SHA1)
                    entry.uuid = uuid
                    # Read registries field (can be a single string for backwards compatibility or a vector)
                    reg_field = get(info, "registries", nothing)
                    if reg_field === nothing
                        # Try reading old "registry" field for backwards compatibility
                        reg_field = get(info, "registry", nothing)
                        entry.registries = reg_field === nothing ? String[] : [String(reg_field)]
                    elseif reg_field isa String
                        entry.registries = [String(reg_field)]
                    elseif reg_field isa Vector
                        entry.registries = String[String(r) for r in reg_field]
                    else
                        pkgerror("Expected `registries` field to be a String or Vector{String}.")
                    end
                    deps = read_deps(get(info::Dict, "deps", nothing)::Union{Nothing, Dict{String, Any}, Vector{String}})
                    weakdeps = read_deps(get(info::Dict, "weakdeps", nothing)::Union{Nothing, Dict{String, Any}, Vector{String}})
                    entry.apps = read_apps(get(info::Dict, "apps", nothing)::Union{Nothing, Dict{String, Any}})
                    entry.exts = read_exts(get(info, "extensions", nothing))
                catch
                    # TODO: Should probably not unconditionally log something
                    # @debug "Could not parse manifest entry for `$name`" f_or_io
                    rethrow()
                end
                entry.other = info
                stage1[name] = push!(get(stage1, name, Stage1[]), Stage1(uuid, entry, deps, weakdeps))
            end
        end
        # by this point, all the fields of the `PackageEntry`s have been type casted
        # but we have *not* verified the _graph_ structure of the manifest
    end
    registries = Dict{String, ManifestRegistryEntry}()
    if haskey(raw, "registries")
        regs_raw = raw["registries"]::Dict{String, Any}
        for (reg_id, info_any) in regs_raw
            info = info_any::Dict{String, Any}
            registries[reg_id] = read_registry_entry(reg_id, info)
        end
    end

    other = Dict{String, Any}()
    for (k, v) in raw
        if k in ("julia_version", "deps", "manifest_format", "registries")
            continue
        end
        other[k] = v
    end
    return validate_manifest(julia_version, project_hash, manifest_format, stage1, other, registries)
end

function read_manifest(f_or_io::Union{String, IO}; source_file::Union{String, Nothing} = nothing)
    raw = try
        if f_or_io isa IO
            # TODO Ugly
            # If source_file indicates a .jl file, write to temp file and parse as inline
            if source_file !== nothing && endswith(source_file, ".jl")
                content = read(f_or_io, String)
                temp_file = tempname() * ".jl"
                try
                    write(temp_file, content)
                    parse_toml(temp_file, manifest=true)
                finally
                    rm(temp_file; force=true)
                end
            else
                TOML.parse(read(f_or_io, String))
            end
        elseif f_or_io isa String
            if !isfile(f_or_io)
                return Manifest()
            elseif endswith(f_or_io, ".jl")
                parse_toml(f_or_io, manifest=true)
            else
                parse_toml(f_or_io)
            end
        end
    catch e
        if e isa TOML.ParserError
            pkgerror("Could not parse manifest: ", sprint(showerror, e))
        end
        rethrow()
    end
    if Base.is_v1_format_manifest(raw)
        if isempty(raw) # treat an empty Manifest file as v2 format for convenience
            raw["manifest_format"] = "2.0.0"
        else
            raw = convert_v1_format_manifest(raw)
        end
    end
    return Manifest(raw, source_file !== nothing ? source_file : f_or_io)
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
    function entry!(entry, key, value; default = nothing)
        return if value == default
            delete!(entry, key)
        else
            entry[key] = value
        end
    end

    if !isempty(manifest.registries) && manifest.manifest_format < v"2.1.0"
        manifest.manifest_format = v"2.1.0"
    end

    unique_name = Dict{String, Bool}()
    for (uuid, entry) in manifest
        unique_name[entry.name] = !haskey(unique_name, entry.name)
    end

    # maintain the format of the manifest when writing
    if manifest.manifest_format.major == 1
        raw = Dict{String, Vector{Dict{String, Any}}}()
    elseif manifest.manifest_format.major == 2
        raw = Dict{String, Any}()
        if !isnothing(manifest.julia_version)
            raw["julia_version"] = manifest.julia_version
        end
        if !isnothing(manifest.project_hash)
            raw["project_hash"] = manifest.project_hash
        end
        raw["manifest_format"] = string(manifest.manifest_format.major, ".", manifest.manifest_format.minor)
        raw["deps"] = Dict{String, Vector{Dict{String, Any}}}()
        for (k, v) in manifest.other
            raw[k] = v
        end
        if !isempty(manifest.registries)
            regs = Dict{String, Any}()
            for (id, entry) in manifest.registries
                regs[id] = registry_entry_toml(entry)
            end
            raw["registries"] = regs
        end
    end

    for (uuid, entry) in manifest
        # https://github.com/JuliaLang/Pkg.jl/issues/4086
        @assert !(entry.tree_hash !== nothing && entry.path !== nothing)

        new_entry = something(entry.other, Dict{String, Any}())
        new_entry["uuid"] = string(uuid)
        entry!(new_entry, "version", entry.version)
        entry!(new_entry, "git-tree-sha1", entry.tree_hash)
        entry!(new_entry, "pinned", entry.pinned; default = false)
        path = entry.path
        if path !== nothing
            path = normalize_path_for_toml(path)
        end
        entry!(new_entry, "path", path)
        entry!(new_entry, "entryfile", entry.entryfile)
        repo_source = entry.repo.source
        if repo_source !== nothing && !isurl(repo_source)
            repo_source = normalize_path_for_toml(repo_source)
        end
        entry!(new_entry, "repo-url", repo_source)
        entry!(new_entry, "repo-rev", entry.repo.rev)
        entry!(new_entry, "repo-subdir", entry.repo.subdir)
        # Write registries as a vector (or nothing if empty)
        if !isempty(entry.registries)
            if length(entry.registries) == 1
                # For backwards compatibility, write a single registry as a string
                entry!(new_entry, "registries", entry.registries[1])
            else
                entry!(new_entry, "registries", entry.registries)
            end
        else
            delete!(new_entry, "registries")
            delete!(new_entry, "registry") # Remove old field if present
        end
        for (deptype, depname) in [(entry.deps, "deps"), (entry.weakdeps, "weakdeps")]
            if isempty(deptype)
                delete!(new_entry, depname)
            else
                if all(dep -> haskey(unique_name, first(dep)), deptype) && all(dep -> unique_name[first(dep)], deptype)
                    new_entry[depname] = sort(collect(keys(deptype)))
                else
                    new_entry[depname] = Dict{String, String}()
                    for (name, uuid) in deptype
                        new_entry[depname][name] = string(uuid)
                    end
                end
            end
        end

        # TODO: Write this inline
        if !isempty(entry.exts)
            entry!(new_entry, "extensions", entry.exts)
        end

        if !isempty(entry.apps)
            new_entry["apps"] = Dict{String, Any}()
            for (appname, appinfo) in entry.apps
                julia_command = @something appinfo.julia_command joinpath(Sys.BINDIR, "julia" * (Sys.iswindows() ? ".exe" : ""))
                app_dict = Dict{String, Any}("julia_command" => julia_command)
                if appinfo.submodule !== nothing
                    app_dict["submodule"] = appinfo.submodule
                end
                if !isempty(appinfo.julia_flags)
                    app_dict["julia_flags"] = appinfo.julia_flags
                end
                new_entry["apps"][appname] = app_dict
            end
        end
        if manifest.manifest_format.major == 1
            push!(get!(raw, entry.name, Dict{String, Any}[]), new_entry)
        elseif manifest.manifest_format.major == 2
            push!(get!(raw["deps"], entry.name, Dict{String, Any}[]), new_entry)
        end
    end
    return raw
end

function write_manifest(env::EnvCache)
    if env.project.readonly
        pkgerror("Cannot write to readonly manifest file at $(env.manifest_file)")
    end
    mkpath(dirname(env.manifest_file))
    return write_manifest(env.manifest, env.manifest_file)
end
function write_manifest(manifest::Manifest, manifest_file::AbstractString)
    if manifest.manifest_format.major == 1
        @warn """The active manifest file at `$(manifest_file)` has an old format.
        Any package operation (add, remove, update, etc.) will automatically upgrade it to format v2.1.""" maxlog = 1 _id = Symbol(manifest_file)
    end
    return write_manifest(destructure(manifest), manifest_file)
end
function write_manifest(io::IO, manifest::Manifest)
    return write_manifest(io, destructure(manifest))
end
function write_manifest(io::IO, raw_manifest::Dict)
    print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
    TOML.print(io, raw_manifest, sorted = true) do x
        (typeof(x) in [String, Nothing, UUID, SHA1, VersionNumber]) && return string(x)
        error("unhandled type `$(typeof(x))`")
    end
    return nothing
end
function write_manifest(raw_manifest::Dict, manifest_file::AbstractString)
    if endswith(manifest_file, ".jl")
        str = sprint(write_manifest, raw_manifest)
        update_inline_manifest!(manifest_file, str)
        return nothing
    end
    str = sprint(write_manifest, raw_manifest)
    mkpath(dirname(manifest_file))
    return write(manifest_file, str)
end

############
# METADATA #
############

function check_manifest_julia_version_compat(manifest::Manifest, manifest_file::String; julia_version_strict::Bool = false)
    isempty(manifest.deps) && return
    if manifest.manifest_format < v"2"
        msg = """The active manifest file is an older format with no julia version entry. Dependencies may have \
        been resolved with a different julia version."""
        if julia_version_strict
            pkgerror(msg)
        else
            @warn msg maxlog = 1 _file = manifest_file _line = 0 _module = nothing
            return
        end
    end
    v = manifest.julia_version
    if v === nothing
        msg = """The active manifest file is missing a julia version entry. Dependencies may have \
        been resolved with a different julia version."""
        if julia_version_strict
            pkgerror(msg)
        else
            @warn msg maxlog = 1 _file = manifest_file _line = 0 _module = nothing
            return
        end
    end
    return if Base.thisminor(v) != Base.thisminor(VERSION)
        msg = """The active manifest file has dependencies that were resolved with a different julia \
        version ($(manifest.julia_version)). Unexpected behavior may occur."""
        if julia_version_strict
            pkgerror(msg)
        else
            @warn msg maxlog = 1 _file = manifest_file _line = 0 _module = nothing
        end
    end
end
