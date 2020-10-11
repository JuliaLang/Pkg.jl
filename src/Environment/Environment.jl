module Environments

using TOML
using Base: UUID, SHA1
using ..Pkg.Versions

# export Environment, Project, Manifest

include("project.jl")
include("manifest.jl")

struct Environment
    path::String
    project::Union{Nothing, Project}
    manifest::Union{Nothing, Manifest}
end

function Base.copy(env::Environment)
    Environment(env.path, env.project  === nothing ? nothing : copy(env.project),
                          env.manifest === nothing ? nothing : copy(env.manifest)
    )
end

function Environment(dir::String)
    project_name = "Project.toml"
    for name in Base.project_names
        if isfile(joinpath(dir, name))
            project_name = name
            break
        end
    end
    project = Project(joinpath(dir, project_name))

    manifest_name = "Manifest.toml"
    for name in Base.manifest_names
        if isfile(joinpath(dir, name))
            manifest_name = name
            break
        end
    end
    manifest = Manifest(joinpath(dir, manifest_name))
    return Environment(dir, project, manifest)
end

function write_environment(env::Environment; path=nothing)
    path === nothing && (path = env.path)

    # First prune
    project_uuids = Set{UUID}(keys(env.project.deps))
    if env.project.pkg != nothing
        push!(project_uuids, env.project.pkg.uuid)
    end
    prune_manifest!(env.manifest, project_uuids)

    # Then write
    write_project(path, env.project)
    write_manifest(path, env.manifest)
    return
end

end
