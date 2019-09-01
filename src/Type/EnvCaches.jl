module EnvCaches

export EnvCache

using UUIDs # TODO remove this when creating RegCache
import ..Pkg: logdir
using  Dates
using  ..PackageSpecs, ..Projects, ..Manifests, ..Utils
# TODO remove PackageSpec

###
### EnvCache
###
# TODO move to RegCache
mutable struct EnvCache
    # environment info:
    env::Union{Nothing,String} # TODO get rid of this field
    git::Union{Nothing,String} # TODO get rid of this field
    # paths for files:
    project_file::String
    manifest_file::String
    # name / uuid of the project
    pkg::Union{Nothing,PackageSpec} # TODO get rid of this
    # cache of metadata:
    project::Project
    manifest::Manifest
    # registered package info:
    uuids::Dict{String,Vector{UUID}}
    paths::Dict{UUID,Vector{String}}
    names::Dict{UUID,Vector{String}}
end

function EnvCache(env::Union{Nothing,String}=nothing)
    project_file = find_project_file(env)
    project_dir = dirname(project_file)
    git = ispath(joinpath(project_dir, ".git")) ? project_dir : nothing
    # read project file
    project = read_project(project_file)
    # initiaze project package
    if any(x -> x !== nothing, [project.name, project.uuid, project.version])
        project_package = PackageSpec(
            name = project.name,
            uuid = project.uuid,
            version = something(project.version, VersionNumber("0.0")),
        )
    else
        project_package = nothing
    end
    # determine manifest file
    dir = abspath(project_dir)
    manifest_file = project.manifest !== nothing ?
        abspath(project.manifest) :
        manifestfile_path(dir)
    write_env_usage(manifest_file, "manifest_usage.toml")
    manifest = read_manifest(manifest_file)
    uuids = Dict{String,Vector{UUID}}()
    paths = Dict{UUID,Vector{String}}()
    names = Dict{UUID,Vector{String}}()
    return EnvCache(env,
        git,
        project_file,
        manifest_file,
        project_package,
        project,
        manifest,
        uuids,
        paths,
        names,)
end

###
### Utils
###
function write_env_usage(source_file::AbstractString, usage_filepath::AbstractString)
    !ispath(logdir()) && mkpath(logdir())
    usage_file = joinpath(logdir(), usage_filepath)
    touch(usage_file)

    # Don't record ghost usage
    !isfile(source_file) && return

    # Do not rewrite as do-block syntax (no longer precompilable)
    io = open(usage_file, "a")
    print(io, """
    [[$(repr(source_file))]]
    time = $(now())Z
    """)
    close(io)
end

end #module
