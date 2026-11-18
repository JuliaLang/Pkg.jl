#########
# UTILS #
#########
listed_deps(project::Project; include_weak::Bool) =
    vcat(collect(keys(project.deps)), collect(keys(project.extras)), include_weak ? collect(keys(project.weakdeps)) : String[])

function get_path_repo(project::Project, project_file::String, manifest_file::String, name::String)
    source = get(project.sources, name, nothing)
    if source === nothing
        return nothing, GitRepo()
    end
    path = get(source, "path", nothing)::Union{String, Nothing}
    url = get(source, "url", nothing)::Union{String, Nothing}
    rev = get(source, "rev", nothing)::Union{String, Nothing}
    subdir = get(source, "subdir", nothing)::Union{String, Nothing}
    if path !== nothing && url !== nothing
        pkgerror("`path` and `url` are conflicting specifications")
    end
    repo = GitRepo(url, rev, subdir)
    # Convert path from project-relative to manifest-relative
    if path !== nothing
        path = project_path_to_manifest_path(project_file, manifest_file, path)
    end
    return path, repo
end

###########
# READING #
###########
# The readers take the raw TOML value and branch on its type in one method, so that a call
# with a value of unknown type does not need dynamic dispatch.
function read_project_uuid(@nospecialize(uuid))
    uuid === nothing && return nothing
    uuid isa String || pkgerror("Expected project UUID to be a string")
    try
        uuid = UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse project UUID as a UUID")
    end
    return uuid
end

function read_project_version(@nospecialize(version))
    version === nothing && return nothing
    version isa String || pkgerror("Expected project version to be a string")
    return try
        version = VersionNumber(version)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse project version as a version")
    end
end

function read_project_deps(@nospecialize(raw), section_name::String)
    deps = Dict{String, UUID}()
    raw === nothing && return deps
    raw isa Dict{String, Any} || pkgerror("Expected `$(section_name)` section to be a key-value list")
    for (name, uuid) in raw
        try
            uuid isa String || throw(ArgumentError("expected a string"))
            uuid = UUID(uuid)
        catch err
            err isa ArgumentError || rethrow()
            pkgerror("Malformed value for `$name` in `$(section_name)` section.")
        end
        deps[name] = uuid
    end
    return deps
end

function read_project_exts(@nospecialize(raw))
    exts = Dict{String, Union{Vector{String}, String}}()
    raw === nothing && return exts
    raw isa Dict{String, Any} || pkgerror("Expected `extensions` section to be a key-value list")
    for (name, triggers) in raw
        triggers = triggers isa String ? triggers : toml_strings(triggers)
        triggers === nothing && pkgerror("Expected value for extension `$name` to be a string or a list of strings")
        exts[name] = triggers
    end
    return exts
end

function read_project_targets(@nospecialize(raw), project::Project)
    targets = Dict{String, Vector{String}}()
    raw === nothing && return targets
    raw isa Dict{String, Any} || pkgerror("Expected `targets` section to be a key-value list")
    for (target, deps) in raw
        deps isa Vector{String} || pkgerror(
            """
                Expected value for target `$target` to be a list of dependency names.
            """
        )
        targets[target] = deps
    end
    return targets
end

function read_project_apps(@nospecialize(raw), project::Project)
    appinfos = Dict{String, AppInfo}()
    raw === nothing && return appinfos
    raw isa Dict{String, Any} || pkgerror("Expected `apps` section to be a key-value list")
    other = raw
    for (name, info) in raw
        info isa Dict{String, Any} || pkgerror(
            """
                Expected value for app `$name` to be a dictionary.
            """
        )
        submodule = get(info, "submodule", nothing)
        submodule isa Union{String, Nothing} || pkgerror("Expected `submodule` for app `$name` to be a string")
        julia_flags_raw = get(info, "julia_flags", nothing)
        julia_flags = julia_flags_raw === nothing ? String[] : toml_strings(julia_flags_raw)
        julia_flags === nothing && pkgerror("Expected `julia_flags` for app `$name` to be an array of strings")
        appinfos[name] = AppInfo(name, nothing, submodule, julia_flags, other)
    end
    return appinfos
end

function read_project_compat(@nospecialize(raw), project::Project; file::Union{Nothing, String} = nothing)
    compat = Dict{String, Compat}()
    raw === nothing && return compat
    raw isa Dict{String, Any} ||
        pkgerror("Expected `compat` section to be a key-value list" * (file === nothing ? "" : " in $(repr(file))"))
    location_string = file === nothing ? "" : " in $(repr(file))"
    for (name, version) in raw
        version = version::String
        try
            compat[name] = Compat(semver_spec(version), version)
        catch err
            pkgerror("Could not parse compatibility version spec $(repr(version)) for dependency `$name`$location_string")
        end
    end
    return compat
end

function read_project_sources(@nospecialize(raw), project::Project)
    valid_keys = ("path", "url", "rev", "subdir")
    sources = Dict{String, Dict{String, String}}()
    raw === nothing && return sources
    raw isa Dict{String, Any} || pkgerror("Expected `sources` section to be a key-value list")
    for (name, source) in raw
        if !(source isa Dict{String, Any})
            pkgerror("Expected `source` section to be a table")
        end
        typed_source = Dict{String, String}()
        for (key, val) in source
            key in valid_keys || pkgerror("Invalid key `$key` in `source` section")
            val isa String || pkgerror("Expected `$key` in `source` section to be a string")
            typed_source[key] = val
        end
        if haskey(source, "path") && (haskey(source, "url") || haskey(source, "rev"))
            pkgerror("Both `path` and `url` or `rev` are specified in `source` section")
        end
        sources[name] = typed_source
    end
    return sources
end

function read_project_workspace(@nospecialize(raw), project::Project)
    workspace_table = Dict{String, Any}()
    raw === nothing && return workspace_table
    raw isa Dict{String, Any} || pkgerror("Expected `workspace` section to be a key-value list")
    for (key, val) in raw
        if key == "projects"
            toml_strings(val) === nothing && pkgerror("Expected entry in `projects` to be strings")
        else
            pkgerror("Invalid key `$key` in `workspace`")
        end
        workspace_table[key] = val
    end
    return workspace_table
end


function validate(project::Project; file::Union{Nothing, String} = nothing)
    # deps
    location_string = file === nothing ? "" : " at $(repr(file))."
    dep_uuids = collect(values(project.deps))
    if length(dep_uuids) != length(unique(dep_uuids))
        pkgerror("Two different dependencies can not have the same uuid" * location_string)
    end
    weak_dep_uuids = collect(values(project.weakdeps))
    if length(weak_dep_uuids) != length(unique(weak_dep_uuids))
        pkgerror("Two different weak dependencies can not have the same uuid" * location_string)
    end
    # extras
    extra_uuids = collect(values(project.extras))
    if length(extra_uuids) != length(unique(extra_uuids))
        pkgerror("Two different `extra` dependencies can not have the same uuid" * location_string)
    end
    # TODO decide what to do in when `add`ing a dep that is already in `extras`
    #   also, reintroduce test files for this
    #=
    dep_names = keys(project.deps)
    for (name, uuid) in project.extras
        name in dep_names && pkgerror("name `$name` is listed in both `deps` and `extras`")
        uuid in dep_uuids && pkgerror("uuid `$uuid` is listed in both `deps` and `extras`")
    end
    =#
    # targets
    listed = listed_deps(project; include_weak = true)
    for (target, deps) in project.targets, dep in deps
        if length(deps) != length(unique(deps))
            pkgerror("A dependency was named twice in target `$target`")
        end
        dep in listed || pkgerror(
            """
            Dependency `$dep` in target `$target` not listed in `deps`, `weakdeps` or `extras` section
            """ * location_string
        )
    end
    # compat
    for name in keys(project.compat)
        name == "julia" && continue
        name in listed ||
            pkgerror("Compat `$name` not listed in `deps`, `weakdeps` or `extras` section" * location_string)
    end
    # compat-overrides
    for name in keys(project.compat_overrides)
        haskey(project.deps, name) || haskey(project.weakdeps, name) ||
            pkgerror("Compat override `$name` not listed in `deps` or `weakdeps` section" * location_string)
    end
    # sources
    listed_nonweak = listed_deps(project; include_weak = false)
    for name in keys(project.sources)
        name in listed_nonweak ||
            pkgerror("Sources for `$name` not listed in `deps` or `extras` section" * location_string)
    end
    return
end

function Project(raw::Dict; file = nothing)
    return parse_project(raw, file === nothing ? nothing : String(file))
end

# The filename is diagnostic context, not a reason to specialize the parser.
@noinline function parse_project(raw::Dict, file::Union{Nothing, String})
    project = Project()
    project.other = raw
    project.name = get(raw, "name", nothing)::Union{String, Nothing}
    project.manifest = get(raw, "manifest", nothing)::Union{String, Nothing}
    project.entryfile = get(raw, "path", nothing)::Union{String, Nothing}
    if project.entryfile === nothing
        project.entryfile = get(raw, "entryfile", nothing)::Union{String, Nothing}
    end
    project.uuid = read_project_uuid(get(raw, "uuid", nothing))
    project.version = read_project_version(get(raw, "version", nothing))
    project.deps = read_project_deps(get(raw, "deps", nothing), "deps")
    project.weakdeps = read_project_deps(get(raw, "weakdeps", nothing), "weakdeps")
    project.exts = read_project_exts(get(raw, "extensions", nothing))
    project.sources = read_project_sources(get(raw, "sources", nothing), project)
    project.extras = read_project_deps(get(raw, "extras", nothing), "extras")
    project.compat = read_project_compat(get(raw, "compat", nothing), project; file)
    project.compat_overrides = read_project_compat(get(raw, "compat-overrides", nothing), project; file)
    project.targets = read_project_targets(get(raw, "targets", nothing), project)
    project.workspace = read_project_workspace(get(raw, "workspace", nothing), project)
    project.apps = read_project_apps(get(raw, "apps", nothing), project)
    project.readonly = get(raw, "readonly", false)::Bool
    syntax = get(raw, "syntax", nothing)::Union{Dict{String, Any}, Nothing}
    project.julia_syntax_version = syntax === nothing ? nothing : read_project_version(get(syntax, "julia_version", nothing))

    # Handle deps in both [deps] and [weakdeps]
    project._deps_weak = Dict(intersect(project.deps, project.weakdeps))
    filter!(p -> !haskey(project._deps_weak, p.first), project.deps)
    validate(project; file)
    return project
end

function read_project(f_or_io::Union{String, IO})
    # Capture the comments of the project file so that they can be written back
    # out by `write_project`
    comments = TOML.Comments()
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String); comments)
        elseif isfile(f_or_io)
            # The comment-capturing path bypasses the shared parser cache;
            # project files are small so the extra parse is cheap
            TOML.parsefile(f_or_io; comments)
        else
            return Project()
        end
    catch e
        if e isa TOML.ParserError
            pkgerror("Could not parse project: ", Pkg.errorstring(e))
        end
        pkgerror("Errored when reading $(f_or_io isa String ? f_or_io : "project"), got: ", Pkg.errorstring(e))
    end
    project = Project(raw; file = f_or_io isa IO ? nothing : f_or_io)
    project.comments = comments
    return project
end


###########
# WRITING #
###########
function destructure(project::Project)::Dict
    raw = deepcopy_toml(project.other)::Dict{String, Any}

    # sanity check for consistency between compat value and string representation
    for (name, compat) in Iterators.flatten((project.compat, project.compat_overrides))
        if compat.val != semver_spec(compat.str)
            pkgerror("inconsistency between compat values and string representation")
        end
    end

    # if a field is set to its default value, don't include it in the write
    function entry!(key::String, src)
        should_delete(x::Dict) = isempty(x)
        should_delete(x) = x === nothing
        return should_delete(src) ? delete!(raw, key) : (raw[key] = src)
    end

    entry!("name", project.name)
    entry!("uuid", project.uuid)
    entry!("version", project.version)
    entry!("workspace", project.workspace)
    entry!("manifest", project.manifest)
    entry!("entryfile", project.entryfile)
    entry!("deps", merge(project.deps, project._deps_weak))
    entry!("weakdeps", project.weakdeps)

    # Normalize paths in sources to use forward slashes on Windows (matching Manifest.toml behavior)
    normalized_sources = project.sources
    if !isempty(project.sources)
        normalized_sources = Dict{String, Dict{String, String}}()
        for (name, source) in project.sources
            normalized_source = copy(source)
            path = get(source, "path", nothing)
            if path !== nothing
                normalized_source["path"] = normalize_path_for_toml(path)
            end
            normalized_sources[name] = normalized_source
        end
    end
    entry!("sources", normalized_sources)
    entry!("extras", project.extras)
    entry!("compat", Dict(name => x.str for (name, x) in project.compat))
    entry!("compat-overrides", Dict(name => x.str for (name, x) in project.compat_overrides))
    entry!("targets", project.targets)
    entry!(
        "syntax", project.julia_syntax_version === nothing ? nothing :
            Dict("julia_version" => string(project.julia_syntax_version))
    )

    # Only write readonly if it's true (not the default false)
    if project.readonly
        raw["readonly"] = true
    else
        delete!(raw, "readonly")
    end

    return raw
end

const _project_key_order = ["name", "uuid", "keywords", "license", "desc", "version", "readonly", "workspace", "deps", "weakdeps", "sources", "extensions", "compat", "compat-overrides"]
project_key_order(key::String) =
    something(findfirst(x -> x == key, _project_key_order), length(_project_key_order) + 1)

function write_project(env::EnvCache, skip_readonly_check::Bool = false)
    if env.project.readonly && !skip_readonly_check
        pkgerror("Cannot write to readonly project file at $(env.project_file)")
    end
    return write_project(env.project, env.project_file)
end
write_project(project::Project, project_file::AbstractString) =
    write_project(destructure(project), project_file; comments = project.comments)
function write_project(io::IO, project::Dict; comments::Union{TOML.Comments, Nothing} = nothing)
    inline_tables = Base.IdSet{Dict}()
    if haskey(project, "sources")
        sources = project["sources"]
        if sources isa Dict{String, Dict{String, String}}
            foreach(source -> push!(inline_tables, source), values(sources))
        else
            for source in values(sources::Dict{String, Any})
                source isa Dict || error("Expected `sources` to be a table")
                push!(inline_tables, source)
            end
        end
    end
    TOML.print(io, project; inline_tables, sorted = true, by = key -> (project_key_order(key), key), comments) do x
        x isa UUID || x isa VersionNumber || pkgerror("unhandled type `$(typeof(x))`")
        return string(x)
    end
    return nothing
end
function write_project(project::Dict, project_file::AbstractString; comments::Union{TOML.Comments, Nothing} = nothing)
    str = sprint(io -> write_project(io, project; comments))
    mkpath(dirname(project_file))
    return write(project_file, str)
end
