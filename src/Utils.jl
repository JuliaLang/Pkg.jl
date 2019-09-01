module Utils

export parse_toml, safe_realpath, isdir_windows_workaround, casesensitive_isdir, pathrepr,
    projectfile_path, manifestfile_path, find_project_file, stdlib, is_stdlib, stdlib_dir, stdlib_path

using  UUIDs
import ..TOML

function parse_toml(path::String...; fakeit::Bool=false)
    p = joinpath(path...)
    !fakeit || isfile(p) ? TOML.parsefile(p) : Dict{String,Any}()
end

###
### Filesystem
###
# try to call realpath on as much as possible
function safe_realpath(path)
    ispath(path) && return realpath(path)
    a, b = splitdir(path)
    return joinpath(safe_realpath(a), b)
end

# Windows sometimes throw on `isdir`...
function isdir_windows_workaround(path::String)
    try isdir(path)
    catch e
        false
    end
end

casesensitive_isdir(dir::String) =
    isdir_windows_workaround(dir) && basename(dir) in readdir(joinpath(dir, ".."))

# TODO is this the right place for this?
function pathrepr(path::String)
    # print stdlib paths as @stdlib/Name
    if startswith(path, stdlib_dir())
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

###
### Project Files
###

# TODO refactor all these
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

function find_project_file(env::Union{Nothing,String}=nothing)
    project_file = nothing
    if env isa Nothing
        project_file = Base.active_project()
        project_file == nothing && pkgerror("no active project")
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

###
### STDLIBS
###
const STDLIB = Ref{Dict{UUID,String}}()

stdlib_dir() = normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"))
stdlib_path(stdlib::String) = joinpath(stdlib_dir(), stdlib)

function load_stdlib()
    stdlib = Dict{UUID,String}()
    for name in readdir(stdlib_dir())
        projfile = projectfile_path(stdlib_path(name); strict=true)
        nothing === projfile && continue
        project = TOML.parsefile(projfile)
        uuid = get(project, "uuid", nothing)
        nothing === uuid && continue
        stdlib[UUID(uuid)] = name
    end
    return stdlib
end

function stdlib()
    if !isassigned(STDLIB)
        STDLIB[] = load_stdlib()
    end
    return deepcopy(STDLIB[])
end

function is_stdlib(uuid::UUID)
    if !isassigned(STDLIB)
        STDLIB[] = load_stdlib()
    end
    return uuid in keys(STDLIB[])
end

end #module
