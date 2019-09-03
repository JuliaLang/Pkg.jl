module Utils

export uuid5, uuid_julia,
       parse_toml, set_readonly, safe_realpath, isdir_windows_workaround, casesensitive_isdir, pathrepr,
       projectfile_path, manifestfile_path, find_project_file, stdlib, is_stdlib, stdlib_dir, stdlib_path

import Base: SHA1
using  UUIDs, SHA
import ..TOML

function parse_toml(path::String...; fakeit::Bool=false)
    p = joinpath(path...)
    !fakeit || isfile(p) ? TOML.parsefile(p) : Dict{String,Any}()
end

###
### UUID
###

## ordering of UUIDs ##
if VERSION < v"1.2.0-DEV.269"  # Defined in Base as of #30947
    Base.isless(a::UUID, b::UUID) = a.value < b.value
end

## Computing UUID5 values from (namespace, key) pairs ##
function uuid5(namespace::UUID, key::String)
    data = [reinterpret(UInt8, [namespace.value]); codeunits(key)]
    u = reinterpret(UInt128, sha1(data)[1:16])[1]
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end
uuid5(namespace::UUID, key::AbstractString) = uuid5(namespace, String(key))

const uuid_dns = UUID(0x6ba7b810_9dad_11d1_80b4_00c04fd430c8)
const uuid_julia_project = uuid5(uuid_dns, "julialang.org")
const uuid_package = uuid5(uuid_julia_project, "package")
const uuid_registry = uuid5(uuid_julia_project, "registry")
const uuid_julia = uuid5(uuid_package, "julia")

###
### Filesystem
###
function set_readonly(path::String)
    for (root, dirs, files) in walkdir(path)
        for file in files
            filepath = joinpath(root, file)
            fmode = filemode(filepath)
            try
                chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
            catch
            end
        end
    end
    return nothing
end

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
