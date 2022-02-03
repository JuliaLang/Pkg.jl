#########
# UTILS #
#########
listed_deps(project::Project) =
    append!(collect(keys(project.deps)), collect(keys(project.extras)))

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

read_project_compat(::Nothing, project::Project) = Dict{String,Compat}()
function read_project_compat(raw::Dict{String,Any}, project::Project)
    compat = Dict{String,Compat}()
    for (name, version) in raw
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

function validate(project::Project)
    # deps
    dep_uuids = collect(values(project.deps))
    if length(dep_uuids) != length(unique(dep_uuids))
        pkgerror("Two different dependencies can not have the same uuid")
    end
    # extras
    extra_uuids = collect(values(project.extras))
    if length(extra_uuids) != length(unique(extra_uuids))
        pkgerror("Two different `extra` dependencies can not have the same uuid")
    end
    dep_names = keys(project.deps)
    # TODO decide what to do in when `add`ing a dep that is already in `extras`
    #   also, reintroduce test files for this
    #=
    for (name, uuid) in project.extras
        name in dep_names && pkgerror("name `$name` is listed in both `deps` and `extras`")
        uuid in dep_uuids && pkgerror("uuid `$uuid` is listed in both `deps` and `extras`")
    end
    =#
    # targets
    listed = listed_deps(project)
    for (target, deps) in project.targets, dep in deps
        if length(deps) != length(unique(deps))
            pkgerror("A dependency was named twice in target `$target`")
        end
        dep in listed || pkgerror("""
            Dependency `$dep` in target `$target` not listed in `deps` or `extras` section.
            """)
    end
    # compat
    for (name, version) in project.compat
        name == "julia" && continue
        name in listed ||
            pkgerror("Compat `$name` not listed in `deps` or `extras` section.")
    end
end

function Project(raw::Dict)
    project = Project()
    project.other    = raw
    project.name     = get(raw, "name", nothing)::Union{String, Nothing}
    project.manifest = get(raw, "manifest", nothing)::Union{String, Nothing}
    project.uuid     = read_project_uuid(get(raw, "uuid", nothing))
    project.version  = read_project_version(get(raw, "version", nothing))
    project.deps     = read_project_deps(get(raw, "deps", nothing), "deps")
    project.extras   = read_project_deps(get(raw, "extras", nothing), "extras")
    project.compat   = read_project_compat(get(raw, "compat", nothing), project)
    project.targets  = read_project_targets(get(raw, "targets", nothing), project)
    validate(project)
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
        rethrow()
    end
    return Project(raw)
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
    entry!("manifest", project.manifest)
    entry!("deps",     project.deps)
    entry!("extras",   project.extras)
    entry!("compat",   Dict(name => x.str for (name, x) in project.compat))
    entry!("targets",  project.targets)
    return raw
end

_project_key_order = ["name", "uuid", "keywords", "license", "desc", "deps", "compat"]
project_key_order(key::String) =
    something(findfirst(x -> x == key, _project_key_order), length(_project_key_order) + 1)

function write_project(env::EnvCache)
    mkpath(dirname(env.project_file))
    write_project(env.project, env.project_file)
end
write_project(project::Project, project_file::AbstractString) =
    write_project(destructure(project), project_file)
function write_project(io::IO, project::Dict)
    TOML.print(io, project, sorted=true, by=key -> (project_key_order(key), key)) do x
        x isa UUID || x isa VersionNumber || pkgerror("unhandled type `$(typeof(x))`")
        return string(x)
    end
    return nothing
end
function write_project(project::Dict, project_file::AbstractString)
    str = sprint(write_project, project)
    write(project_file, str)
end
