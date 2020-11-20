module Environments

using TOML
using Base: UUID, SHA1
using ..Pkg.Versions
using ..Pkg: Resolve
using ..Pkg

# export Environment, Project, Manifest

# See loading.jl
const TOML_CACHE = Base.TOMLCache(TOML.Parser(), Dict{String, Dict{String, Any}}())
const TOML_LOCK = ReentrantLock()
# Be safe and make a copy here, if the copy is removed, all usages needs to be audited to make
# sure they do not modify the returned dictionary.
parsefile(project_file::AbstractString) = copy(Base.parsed_toml(project_file, TOML_CACHE, TOML_LOCK))

include("project.jl")
include("manifest.jl")

struct Environment
    path::String
    project::Union{Nothing, Project}
    manifest::Union{Manifest}
end

function Base.copy(env::Environment)
    Environment(env.path, env.project  === nothing ? nothing : copy(env.project),
                          copy(env.manifest)
    )
end

function Environment(dir::String)
    project_path = nothing
    for name in Base.project_names
        candidate_path = joinpath(dir, name)
        if isfile(candidate_path)
            project_path = candidate_path
            break
        end
    end
    project = project_path === nothing ? nothing : Project(project_path)

    manifest_path = nothing
    for name in Base.manifest_names
        candidate_path = joinpath(dir, name)
        if isfile(candidate_path)
            manifest_path = candidate_path
            break
        end
    end
    manifest = manifest_path === nothing ?
        empty_manifest(joinpath(dir, first(Base.manifest_names))) :
        Manifest(manifest_path)
    return Environment(dir, project, manifest)
end

function prune_manifest!(env::Environment)
    project_uuids = Set{UUID}(keys(env.project.deps))
    if env.project.pkg != nothing
        push!(project_uuids, env.project.pkg.uuid)
    end
    prune_manifest!(env.manifest, project_uuids)
end

write_environment(env::Environment) = write_environment(env.path, env)
function write_environment(path::String, env::Environment)
    mkpath(path)
    prune_manifest!(env)

    # Then write
    n = 0
    n += write_project(path, env.project)
    n += write_manifest(path, env.manifest)
    return n
end

end
