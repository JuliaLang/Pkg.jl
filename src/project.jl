#########
# UTILS #
#########
listed_deps(project::Project; include_weak::Bool) =
    vcat(collect(keys(project.deps)), collect(keys(project.extras)), include_weak ? collect(keys(project.weakdeps)) : String[])

function get_path_repo(project::Project, name::String)
    source = get(project.sources, name, nothing)
    if source === nothing
        return nothing, GitRepo()
    end
    path   = get(source, "path",   nothing)::Union{String, Nothing}
    url    = get(source, "url",    nothing)::Union{String, Nothing}
    rev    = get(source, "rev",    nothing)::Union{String, Nothing}
    subdir = get(source, "subdir", nothing)::Union{String, Nothing}
    if path !== nothing && url !== nothing
        pkgerror("`path` and `url` are conflicting specifications")
    end
    repo = GitRepo(url, rev, subdir)
    return path, repo
end

###########
# READING #
###########
read_project_uuid(::Nothing) = nothing
function read_project_uuid(uuid::String)
    try uuid = UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse project UUID as a UUID")
    end
    return uuid
end
read_project_uuid(uuid) = pkgerror("Expected project UUID to be a string")

read_project_version(::Nothing) = nothing
function read_project_version(version::String)
    try version = VersionNumber(version)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse project version as a version")
    end
end
read_project_version(version) = pkgerror("Expected project version to be a string")

read_project_deps(::Nothing, section::String) = Dict{String,UUID}()
function read_project_deps(raw::Dict{String,Any}, section_name::String)
    deps = Dict{String,UUID}()
    for (name, uuid) in raw
        try
            uuid = UUID(uuid)
        catch err
            err isa ArgumentError || rethrow()
            pkgerror("Malformed value for `$name` in `$(section_name)` section.")
        end
        deps[name] = uuid
    end
    return deps
end
function read_project_deps(raw, section_name::String)
    pkgerror("Expected `$(section_name)` section to be a key-value list")
end

read_project_targets(::Nothing, project::Project) = Dict{String,Any}()
function read_project_targets(raw::Dict{String,Any}, project::Project)
    for (target, deps) in raw
        deps isa Vector{String} || pkgerror("""
            Expected value for target `$target` to be a list of dependency names.
        """)
    end
    return raw
end
read_project_targets(raw, project::Project) =
    pkgerror("Expected `targets` section to be a key-value list")

read_project_apps(::Nothing, project::Project) = Dict{String,Any}()
function read_project_apps(raw::Dict{String,Any}, project::Project)
    other = raw
    appinfos = Dict{String,AppInfo}()
    for (name, info) in raw
        info isa Dict{String,Any} || pkgerror("""
            Expected value for app `$name` to be a dictionary.
        """)
        appinfos[name] = AppInfo(name, nothing, nothing, other)
    end
    return appinfos
end

read_project_compat(::Nothing, project::Project) = Dict{String,Compat}()
function read_project_compat(raw::Dict{String,Any}, project::Project)
    compat = Dict{String,Compat}()
    for (name, version) in raw
        version = version::String
        try
            compat[name] = Compat(semver_spec(version), version)
        catch err
            pkgerror("Could not parse compatibility version for dependency `$name`")
        end
    end
    return compat
end
read_project_compat(raw, project::Project) =
    pkgerror("Expected `compat` section to be a key-value list")

read_project_sources(::Nothing, project::Project) = Dict{String,Any}()
function read_project_sources(raw::Dict{String,Any}, project::Project)
    valid_keys = ("path", "url", "rev", "subdir")
    sources = Dict{String,Any}()
    for (name, source) in raw
        if !(source isa AbstractDict)
            pkgerror("Expected `source` section to be a table")
        end
        for key in keys(source)
            key in valid_keys || pkgerror("Invalid key `$key` in `source` section")
        end
        if haskey(source, "path") && (haskey(source, "url") || haskey(source, "rev"))
            pkgerror("Both `path` and `url` or `rev` are specified in `source` section")
        end
        sources[name] = source
    end
    return sources
end

read_project_workspace(::Nothing, project::Project) = Dict{String,Any}()
function read_project_workspace(raw::Dict, project::Project)
    workspace_table = Dict{String,Any}()
    for (key, val) in raw
        if key == "projects"
            for path in val
                path isa String || pkgerror("Expected entry in `projects` to be strings")
            end
        else
            pkgerror("Invalid key `$key` in `workspace`")
        end
        workspace_table[key] = val
    end
    return workspace_table
end
read_project_workspace(raw, project::Project) =
    pkgerror("Expected `workspace` section to be a key-value list")


function validate(project::Project; file=nothing)
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
    listed = listed_deps(project; include_weak=true)
    for (target, deps) in project.targets, dep in deps
        if length(deps) != length(unique(deps))
            pkgerror("A dependency was named twice in target `$target`")
        end
        dep in listed || pkgerror("""
            Dependency `$dep` in target `$target` not listed in `deps`, `weakdeps` or `extras` section
            """ * location_string)
    end
    # compat
    for name in keys(project.compat)
        name == "julia" && continue
        name in listed ||
            pkgerror("Compat `$name` not listed in `deps`, `weakdeps` or `extras` section" * location_string)
    end
     # sources
     listed_nonweak = listed_deps(project; include_weak=false)
     for name in keys(project.sources)
        name in listed_nonweak ||
            pkgerror("Sources for `$name` not listed in `deps` or `extras` section" * location_string)
    end
end

function Project(raw::Dict; file=nothing)
    project = Project()
    project.other    = raw
    project.name     = get(raw, "name", nothing)::Union{String, Nothing}
    project.manifest = get(raw, "manifest", nothing)::Union{String, Nothing}
    project.entryfile     = get(raw, "path", nothing)::Union{String, Nothing}
    if project.entryfile === nothing
        project.entryfile = get(raw, "entryfile", nothing)::Union{String, Nothing}
    end
    project.uuid     = read_project_uuid(get(raw, "uuid", nothing))
    project.version  = read_project_version(get(raw, "version", nothing))
    project.deps     = read_project_deps(get(raw, "deps", nothing), "deps")
    project.weakdeps = read_project_deps(get(raw, "weakdeps", nothing), "weakdeps")
    project.exts     = get(Dict{String, String}, raw, "extensions")
    project.sources  = read_project_sources(get(raw, "sources", nothing), project)
    project.extras   = read_project_deps(get(raw, "extras", nothing), "extras")
    project.compat   = read_project_compat(get(raw, "compat", nothing), project)
    project.targets  = read_project_targets(get(raw, "targets", nothing), project)
    project.workspace = read_project_workspace(get(raw, "workspace", nothing), project)
    project.apps     = read_project_apps(get(raw, "apps", nothing), project)

    # Handle deps in both [deps] and [weakdeps]
    project._deps_weak = Dict(intersect(project.deps, project.weakdeps))
    filter!(p->!haskey(project._deps_weak, p.first), project.deps)
    validate(project; file)
    return project
end

function read_project(f_or_io::Union{String, IO})
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String))
        else
            isfile(f_or_io) ? parse_toml(f_or_io) : return Project()
        end
    catch e
        if e isa TOML.ParserError
            pkgerror("Could not parse project: ", sprint(showerror, e))
        end
        pkgerror("Errored when reading $f_or_io, got: ", sprint(showerror, e))
    end
    return Project(raw; file= f_or_io isa IO ? nothing : f_or_io)
end


###########
# WRITING #
###########
function destructure(project::Project)::Dict
    raw = deepcopy(project.other)

    # sanity check for consistency between compat value and string representation
    for (name, compat) in project.compat
        if compat.val != semver_spec(compat.str)
            pkgerror("inconsistency between compat values and string representation")
        end
    end

    # if a field is set to its default value, don't include it in the write
    function entry!(key::String, src)
        should_delete(x::Dict) = isempty(x)
        should_delete(x)       = x === nothing
        should_delete(src) ? delete!(raw, key) : (raw[key] = src)
    end

    entry!("name",     project.name)
    entry!("uuid",     project.uuid)
    entry!("version",  project.version)
    entry!("workspace", project.workspace)
    entry!("manifest", project.manifest)
    entry!("entryfile",     project.entryfile)
    entry!("deps",     merge(project.deps, project._deps_weak))
    entry!("weakdeps", project.weakdeps)
    entry!("sources",  project.sources)
    entry!("extras",   project.extras)
    entry!("compat",   Dict(name => x.str for (name, x) in project.compat))
    entry!("targets",  project.targets)
    return raw
end

const _project_key_order = ["name", "uuid", "keywords", "license", "desc", "version", "workspace", "deps", "weakdeps", "sources", "extensions", "compat"]
project_key_order(key::String) =
    something(findfirst(x -> x == key, _project_key_order), length(_project_key_order) + 1)

function write_project(env::EnvCache)
    write_project(env.project, env.project_file)
end
write_project(project::Project, project_file::AbstractString) =
    write_project(destructure(project), project_file)
function write_project(io::IO, project::Dict)
    inline_tables = Base.IdSet{Dict}()
    if haskey(project, "sources")
        for source in values(project["sources"])
            source isa Dict || error("Expected `sources` to be a table")
            push!(inline_tables, source)
        end
    end
    TOML.print(io, project; inline_tables, sorted=true, by=key -> (project_key_order(key), key)) do x
        x isa UUID || x isa VersionNumber || pkgerror("unhandled type `$(typeof(x))`")
        return string(x)
    end
    return nothing
end
function write_project(project::Dict, project_file::AbstractString)
    str = sprint(write_project, project)
    mkpath(dirname(project_file))
    write(project_file, str)
end
