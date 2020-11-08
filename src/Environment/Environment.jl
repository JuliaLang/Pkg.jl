module Environments

using TOML
using Base: UUID, SHA1
using ..Pkg.Versions
using ..Pkg: Resolve
using ..Pkg

# export Environment, Project, Manifest

include("project.jl")
include("manifest.jl")

struct Environment
    path::String
    project::Union{Nothing, Project}
    manifest::Union{Nothing, Manifest{VersionNumber}}
end

function Base.copy(env::Environment)
    Environment(env.path, env.project  === nothing ? nothing : copy(env.project),
                          env.manifest === nothing ? nothing : copy(env.manifest)
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
    manifest = manifest_path === nothing ? nothing : Manifest(manifest_path)
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
