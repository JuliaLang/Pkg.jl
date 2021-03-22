function find_project_file(env::Union{Nothing,String}=nothing)
    project_file = nothing
    if env isa Nothing
        project_file = Base.active_project()
        project_file === nothing && pkgerror("no active project")
    elseif startswith(env, '@')
        project_file = Base.load_path_expand(env)
        project_file === nothing && pkgerror("package environment does not exist: $env")
    elseif env isa String
        if isdir(env)
            isempty(readdir(env)) || pkgerror("environment is a package directory: $env")
            project_file = joinpath(env, Base.project_names[end])
        else
            project_file = endswith(env, ".toml") ? abspath(env) :
                abspath(env, Base.project_names[end])
        end
    end
    @assert project_file isa String &&
        (isfile(project_file) || !ispath(project_file) ||
         isdir(project_file) && isempty(readdir(project_file)))
    return safe_realpath(project_file)
end

function projectfile_path(env_path::String; strict=false)
    for name in Base.project_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    return strict ? nothing : joinpath(env_path, "Project.toml")
end

function manifestfile_path(env_path::String; strict=false)
    for name in Base.manifest_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    if strict
        return nothing
    else
        project = basename(projectfile_path(env_path))
        idx = findfirst(x -> x == project, Base.project_names)
        @assert idx !== nothing
        return joinpath(env_path, Base.manifest_names[idx])
    end
end


function write_env_usage(source_file::AbstractString, usage_filepath::AbstractString)
    # Don't record ghost usage
    !isfile(source_file) && return

    # Ensure that log dir exists
    !ispath(logdir()) && mkpath(logdir())

    # Generate entire entry as a string first
    entry = sprint() do io
        TOML.print(io, Dict(source_file => [Dict("time" => now())]))
    end

    # Append entry to log file in one chunk
    usage_file = joinpath(logdir(), usage_filepath)
    open(usage_file, append=true) do io
        write(io, entry)
    end
end

mutable struct EnvCache
    # environment info:
    env::Union{Nothing,String}
    # paths for files:
    project_file::String
    manifest_file::String
    # name / uuid of the project
    pkg::Union{PackageSpec, Nothing}
    # cache of metadata:
    project::Project
    manifest::Manifest
    # What these where at creation of the EnvCache
    original_project::Project
    original_manifest::Manifest
end

function EnvCache(env::Union{Nothing,String}=nothing)
    project_file = find_project_file(env)
    project_dir = dirname(project_file)
    # read project file
    project = read_project(project_file)
    # initialize project package
    if project.name !== nothing && project.uuid !== nothing
        project_package = PackageSpec(
            name = project.name,
            uuid = project.uuid,
            version = something(project.version, VersionNumber("0.0")),
            path = project_dir,
        )
    else
        project_package = nothing
    end
    # determine manifest file
    dir = abspath(project_dir)
    manifest_file = project.manifest
    manifest_file = manifest_file !== nothing ?
        abspath(manifest_file) : manifestfile_path(dir)::String
    write_env_usage(manifest_file, "manifest_usage.toml")
    manifest = read_manifest(manifest_file)

    env′ = EnvCache(env,
        project_file,
        manifest_file,
        project_package,
        project,
        manifest,
        deepcopy(project),
        deepcopy(manifest),
        )



    return env′
end

project_uuid(env::EnvCache) = env.pkg === nothing ? nothing : env.pkg.uuid
is_project_name(env::EnvCache, name::String) =
    env.pkg !== nothing && env.pkg.name == name
is_project_name(env::EnvCache, name::Nothing) = false
is_project_uuid(env::EnvCache, uuid::UUID) = project_uuid(env) == uuid

function write_project(env::EnvCache)
    mkpath(dirname(env.project_file))
    write_project(env.project, env.project_file)
end

function write_manifest(env::EnvCache)
    mkpath(dirname(env.manifest_file))
    write_manifest(env.manifest, env.manifest_file)
end

function write_env(env::EnvCache)
    if env.project != env.original_project
        write_project(env)
    end
    if env.manifest != env.original_manifest
        write_manifest(env)
    end
end