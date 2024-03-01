# This file is a part of Julia. License is MIT: https://julialang.org/license

module Types

using UUIDs
using Random
using Dates
import LibGit2
import Base.string

using TOML
import ..Pkg, ..Registry
import ..Pkg: GitTools, depots, depots1, logdir, set_readonly, safe_realpath, pkg_server, stdlib_dir, stdlib_path, isurl, stderr_f, RESPECT_SYSIMAGE_VERSIONS
import Base.BinaryPlatforms: Platform
using ..Pkg.Versions
import FileWatching

import Base: SHA1
using SHA

export UUID, SHA1, VersionRange, VersionSpec,
    PackageSpec, PackageEntry, EnvCache, Context, GitRepo, Context!, Manifest, Project, err_rep,
    PkgError, pkgerror,
    has_name, has_uuid, is_stdlib, is_or_was_stdlib, stdlib_version, is_unregistered_stdlib, stdlibs, stdlib_infos, write_env, write_env_usage, parse_toml,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved,
    registered_name,
    manifest_info,
    read_project, read_package, read_manifest, get_path_repo,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PreserveLevel, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED,
    PRESERVE_TIERED_INSTALLED, PRESERVE_NONE,
    projectfile_path, manifestfile_path

# Load in data about historical stdlibs
include("HistoricalStdlibs.jl")

deepcopy_toml(x) = x
function deepcopy_toml(@nospecialize(x::Vector))
    d = similar(x)
    for (i, v) in enumerate(x)
        d[i] = deepcopy_toml(v)
    end
    return d
end
function deepcopy_toml(x::Dict{String, Any})
    d = Dict{String, Any}()
    sizehint!(d, length(x))
    for (k, v) in x
        d[k] = deepcopy_toml(v)
    end
    return d
end

# See loading.jl
const TOML_CACHE = Base.TOMLCache(Base.TOML.Parser{Dates}())
const TOML_LOCK = ReentrantLock()
# Some functions mutate the returning Dict so return a copy of the cached value here
parse_toml(toml_file::AbstractString) =
    Base.invokelatest(deepcopy_toml, Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK))::Dict{String, Any}

#################
# Pkg Error #
#################
struct PkgError <: Exception
    msg::String
end
pkgerror(msg::String...) = throw(PkgError(join(msg)))
Base.showerror(io::IO, err::PkgError) = print(io, err.msg)

###############
# PackageSpec #
###############
@enum(UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR)
@enum(PreserveLevel, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_TIERED_INSTALLED, PRESERVE_NONE)
@enum(PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST, PKGMODE_COMBINED)

const VersionTypes = Union{VersionNumber,VersionSpec,UpgradeLevel}

Base.@kwdef mutable struct GitRepo
    source::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing
    subdir::Union{String, Nothing} = nothing
end

Base.:(==)(r1::GitRepo, r2::GitRepo) =
    r1.source == r2.source && r1.rev == r2.rev && r1.subdir == r2.subdir


mutable struct PackageSpec
    name::Union{Nothing,String}
    uuid::Union{Nothing,UUID}
    version::Union{Nothing,VersionTypes,String}
    tree_hash::Union{Nothing,SHA1}
    repo::GitRepo
    path::Union{Nothing,String}
    pinned::Bool
    # used for input only
    url::Union{Nothing, String}
    rev::Union{Nothing, String}
    subdir::Union{Nothing, String}

end
function PackageSpec(; name::Union{Nothing,AbstractString} = nothing,
                       uuid::Union{Nothing,UUID,AbstractString} = nothing,
                       version::Union{Nothing,VersionTypes,AbstractString} = VersionSpec(),
                       tree_hash::Union{Nothing,SHA1} = nothing,
                       repo::GitRepo = GitRepo(),
                       path::Union{Nothing,AbstractString} = nothing,
                       pinned::Bool = false,
                       url = nothing,
                       rev = nothing,
                       subdir = nothing)
    uuid = uuid === nothing ? nothing : UUID(uuid)
    return PackageSpec(name, uuid, version, tree_hash, repo, path, pinned, url, rev, subdir)
end
PackageSpec(name::AbstractString) = PackageSpec(;name=name)::PackageSpec
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(;name=name, uuid=uuid)::PackageSpec
PackageSpec(name::AbstractString, version::VersionTypes) = PackageSpec(;name=name, version=version)::PackageSpec
PackageSpec(n::AbstractString, u::UUID, v::VersionTypes) = PackageSpec(;name=n, uuid=u, version=v)::PackageSpec

function Base.:(==)(a::PackageSpec, b::PackageSpec)
    return a.name == b.name && a.uuid == b.uuid && a.version == b.version &&
    a.tree_hash == b.tree_hash && a.repo == b.repo && a.path == b.path &&
    a.pinned == b.pinned
end

function err_rep(pkg::PackageSpec)
    x = pkg.name !== nothing && pkg.uuid !== nothing ? x = "$(pkg.name) [$(string(pkg.uuid)[1:8])]" :
        pkg.name !== nothing ? pkg.name :
        pkg.uuid !== nothing ? string(pkg.uuid)[1:8] :
        pkg.repo.source
    return "`$x`"
end

has_name(pkg::PackageSpec) = pkg.name !== nothing
has_uuid(pkg::PackageSpec) = pkg.uuid !== nothing
isresolved(pkg::PackageSpec) = pkg.uuid !== nothing && pkg.name !== nothing

function Base.show(io::IO, pkg::PackageSpec)
    vstr = repr(pkg.version)
    f = Pair{String, Any}[]

    pkg.name !== nothing && push!(f, "name" => pkg.name)
    pkg.uuid !== nothing && push!(f, "uuid" => pkg.uuid)
    pkg.tree_hash !== nothing && push!(f, "tree_hash" => pkg.tree_hash)
    pkg.path !== nothing && push!(f, "path" => pkg.path)
    pkg.url !== nothing && push!(f, "url" => pkg.url)
    pkg.rev !== nothing && push!(f, "rev" => pkg.rev)
    pkg.subdir !== nothing && push!(f, "subdir" => pkg.subdir)
    pkg.pinned && push!(f, "pinned" => pkg.pinned)
    push!(f, "version" => (vstr == "VersionSpec(\"*\")" ? "*" : vstr))
    if pkg.repo.source !== nothing
        push!(f, "repo/source" => string("\"", pkg.repo.source::String, "\""))
    end
    if pkg.repo.rev !== nothing
        push!(f, "repo/rev" => pkg.repo.rev)
    end
    if pkg.repo.subdir !== nothing
        push!(f, "repo/subdir" => pkg.repo.subdir)
    end
    print(io, "PackageSpec(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", string(value)::String, "\n")
    end
    print(io, ")")
end

############
# EnvCache #
############

function projectfile_path(env_path::String; strict=false)
    for name in Base.project_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    return strict ? nothing : joinpath(env_path, "Project.toml")
end

function manifestfile_path(env_path::String; strict=false)
    for name in (Base.manifest_names..., "AppManifest.toml")
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    if strict
        return nothing
    else
        # given no matching manifest exists, if JuliaProject.toml is used,
        # prefer to create JuliaManifest.toml, otherwise Manifest.toml
        project, _ = splitext(basename(projectfile_path(env_path)::String))
        if project == "JuliaProject"
            return joinpath(env_path, "JuliaManifest.toml")
        else
            return joinpath(env_path, "Manifest.toml")
        end
    end
end

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
    if isfile(project_file) && !contains(basename(project_file), "Project")
        pkgerror("""
        The active project has been set to a file that isn't a Project file: $project_file
        The project path must be to a Project file or directory.
        """)
    end
    @assert project_file isa String &&
        (isfile(project_file) || !ispath(project_file) ||
         isdir(project_file) && isempty(readdir(project_file)))
    return Pkg.safe_realpath(project_file)
end

Base.@kwdef mutable struct Compat
    val::VersionSpec
    str::String
end
Base.:(==)(t1::Compat, t2::Compat) = t1.val == t2.val
Base.hash(t::Compat, h::UInt) = hash(t.val, h)

struct AppInfo
    name::String
    julia_command::Union{String, Nothing}
    julia_version::Union{VersionNumber, Nothing}
    other::Dict{String,Any}
end
Base.@kwdef mutable struct Project
    other::Dict{String,Any} = Dict{String,Any}()
    # Fields
    name::Union{String, Nothing} = nothing
    uuid::Union{UUID, Nothing} = nothing
    version::Union{VersionTypes, Nothing} = nothing
    manifest::Union{String, Nothing} = nothing
    entryfile::Union{String, Nothing} = nothing
    # Sections
    deps::Dict{String,UUID} = Dict{String,UUID}()
    # deps that are also in weakdeps for backwards compat
    # we do not store them in deps because we want to ignore them
    # but for writing out the project file we need to remember them:
    _deps_weak::Dict{String,UUID} = Dict{String,UUID}()
    weakdeps::Dict{String,UUID} = Dict{String,UUID}()
    exts::Dict{String,Union{Vector{String}, String}} = Dict{String,String}()
    extras::Dict{String,UUID} = Dict{String,UUID}()
    targets::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    apps::Dict{String, AppInfo} = Dict{String, AppInfo}()
    compat::Dict{String,Compat} = Dict{String,Compat}()
    sources::Dict{String,Dict{String, String}} = Dict{String,Dict{String, String}}()
    workspace::Dict{String, Any} = Dict{String, Any}()
end
Base.:(==)(t1::Project, t2::Project) = all(x -> (getfield(t1, x) == getfield(t2, x))::Bool, fieldnames(Project))
Base.hash(t::Project, h::UInt) = foldr(hash, [getfield(t, x) for x in fieldnames(Project)], init=h)



Base.@kwdef mutable struct PackageEntry
    name::Union{String,Nothing} = nothing
    version::Union{VersionNumber,Nothing} = nothing
    path::Union{String,Nothing} = nothing
    entryfile::Union{String,Nothing} = nothing
    pinned::Bool = false
    repo::GitRepo = GitRepo()
    tree_hash::Union{Nothing,SHA1} = nothing
    deps::Dict{String,UUID} = Dict{String,UUID}()
    weakdeps::Dict{String,UUID} = Dict{String,UUID}()
    exts::Dict{String,Union{Vector{String}, String}} = Dict{String,String}()
    uuid::Union{Nothing, UUID} = nothing
    apps::Dict{String, AppInfo} = Dict{String, AppInfo}() # used by AppManifest.toml
    other::Union{Dict,Nothing} = nothing
end
Base.:(==)(t1::PackageEntry, t2::PackageEntry) = t1.name == t2.name &&
    t1.version == t2.version &&
    t1.path == t2.path &&
    t1.entryfile == t2.entryfile &&
    t1.pinned == t2.pinned &&
    t1.repo == t2.repo &&
    t1.tree_hash == t2.tree_hash &&
    t1.deps == t2.deps &&
    t1.weakdeps == t2.weakdeps &&
    t1.exts == t2.exts &&
    t1.uuid == t2.uuid &&
    t1.apps == t2.apps
    # omits `other`
Base.hash(x::PackageEntry, h::UInt) = foldr(hash, [x.name, x.version, x.path, x.entryfile, x.pinned, x.repo, x.tree_hash, x.deps, x.weakdeps, x.exts, x.uuid], init=h)  # omits `other`

Base.@kwdef mutable struct Manifest
    julia_version::Union{Nothing,VersionNumber} = nothing # only set to VERSION when resolving
    project_hash::Union{Nothing,SHA1} = nothing
    manifest_format::VersionNumber = v"2.0.0"
    deps::Dict{UUID,PackageEntry} = Dict{UUID,PackageEntry}()
    other::Dict{String,Any} = Dict{String,Any}()
end
Base.:(==)(t1::Manifest, t2::Manifest) = all(x -> (getfield(t1, x) == getfield(t2, x))::Bool, fieldnames(Manifest))
Base.hash(m::Manifest, h::UInt) = foldr(hash, [getfield(m, x) for x in fieldnames(Manifest)], init=h)
Base.getindex(m::Manifest, i_or_key) = getindex(m.deps, i_or_key)
Base.get(m::Manifest, key, default) = get(m.deps, key, default)
Base.setindex!(m::Manifest, i_or_key, value) = setindex!(m.deps, i_or_key, value)
Base.iterate(m::Manifest) = iterate(m.deps)
Base.iterate(m::Manifest, i::Int) = iterate(m.deps, i)
Base.length(m::Manifest) = length(m.deps)
Base.empty!(m::Manifest) = empty!(m.deps)
Base.values(m::Manifest) = values(m.deps)
Base.keys(m::Manifest) = keys(m.deps)
Base.haskey(m::Manifest, key) = haskey(m.deps, key)

function Base.show(io::IO, pkg::PackageEntry)
    f = []
    pkg.name        !== nothing && push!(f, "name"      => pkg.name)
    pkg.version     !== nothing && push!(f, "version"   => pkg.version)
    pkg.tree_hash   !== nothing && push!(f, "tree_hash" => pkg.tree_hash)
    pkg.path        !== nothing && push!(f, "dev/path"  => pkg.path)
    pkg.pinned                  && push!(f, "pinned"    => pkg.pinned)
    pkg.repo.source !== nothing && push!(f, "url/path"  => "`$(pkg.repo.source)`")
    pkg.repo.rev    !== nothing && push!(f, "rev"       => pkg.repo.rev)
    pkg.repo.subdir !== nothing && push!(f, "subdir"    => pkg.repo.subdir)
    print(io, "PackageEntry(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", value, "\n")
    end
    print(io, ")")
end

function find_root_base_project(start_project::String)
    project_file = start_project
    while true
        base_project_file = Base.base_project(project_file)
        base_project_file === nothing && return project_file
        project_file = base_project_file
    end
end

function collect_workspace(base_project_file::String, d::Dict{String, Project}=Dict{String, Project}())
    base_project = read_project(base_project_file)
    d[base_project_file] = base_project
    base_project_file_dir = dirname(base_project_file)

    projects = get(base_project.workspace, "projects", nothing)::Union{Nothing,Vector{String}}
    projects === nothing && return d
    project_paths = [abspath(base_project_file_dir, project) for project in projects]
    for project_path in project_paths
        project_file = Base.locate_project_file(abspath(project_path))
        if project_file isa String
            collect_workspace(project_file, d)
        end
    end
    return d
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
    workspace::Dict{String,Project} # paths relative to base
    manifest::Manifest
    # What these where at creation of the EnvCache
    original_project::Project
    original_manifest::Manifest
end

function EnvCache(env::Union{Nothing,String}=nothing)
    # @show env
    project_file = find_project_file(env)
    # @show project_file
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

    manifest_file = project.manifest
    root_base_proj_file = find_root_base_project(project_file)
    workspace = Dict{String, Project}()
    if isfile(root_base_proj_file)
        if root_base_proj_file !== project_file
            manifest_file = manifestfile_path(dirname(root_base_proj_file))
        end
        workspace = collect_workspace(root_base_proj_file)
        delete!(workspace, abspath(project_file))
    end

    dir = abspath(project_dir)
    manifest_file = manifest_file !== nothing ?
        (isabspath(manifest_file) ? manifest_file : abspath(dir, manifest_file)) :
        manifestfile_path(dir)::String
    write_env_usage(manifest_file, "manifest_usage.toml")
    manifest = read_manifest(manifest_file)

    env′ = EnvCache(env,
        project_file,
        manifest_file,
        project_package,
        project,
        workspace,
        manifest,
        deepcopy(project),
        deepcopy(manifest),
        )

    return env′
end

include("project.jl")
include("manifest.jl")

function num_concurrent_downloads()
    val = get(ENV, "JULIA_PKG_CONCURRENT_DOWNLOADS", "8")
    num = tryparse(Int, val)
    isnothing(num) && error("Environment variable `JULIA_PKG_CONCURRENT_DOWNLOADS` expects an integer, instead found $(val)")
    if num < 1
        error("Number of concurrent downloads must be greater than 0")
    end
    return num
end
# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    io::IO = stderr_f()
    use_git_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    num_concurrent_downloads::Int = num_concurrent_downloads()

    # Registris
    registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries()

    # The Julia Version to resolve with respect to
    julia_version::Union{VersionNumber,Nothing} = VERSION
end

project_uuid(env::EnvCache) = project_uuid(env.project, env.project_file)
project_uuid(project::Project, project_file::String) = @something(project.uuid, Base.dummy_uuid(project_file))
collides_with_project(env::EnvCache, pkg::PackageSpec) =
    is_project_name(env, pkg.name) || is_project_uuid(env, pkg.uuid)
is_project(env::EnvCache, pkg::PackageSpec) = is_project_uuid(env, pkg.uuid)
is_project_name(env::EnvCache, name::String) =
    env.pkg !== nothing && env.pkg.name == name
is_project_name(env::EnvCache, name::Nothing) = false
is_project_uuid(env::EnvCache, uuid::UUID) = project_uuid(env) == uuid

###########
# Context #
###########

const UPGRADABLE_STDLIBS = ["DelimitedFiles", "Statistics"]
const UPGRADABLE_STDLIBS_UUIDS = Set{UUID}()
const STDLIB = Ref{Union{DictStdLibs, Nothing}}(nothing)
function load_stdlib()
    stdlib = DictStdLibs()
    for name in readdir(stdlib_dir())
        projfile = projectfile_path(stdlib_path(name); strict=true)
        nothing === projfile && continue
        project = parse_toml(projfile)
        uuid = get(project, "uuid", nothing)::Union{String, Nothing}
        v_str = get(project, "version", nothing)::Union{String, Nothing}
        version = isnothing(v_str) ? nothing : VersionNumber(v_str)
        nothing === uuid && continue
        if name in UPGRADABLE_STDLIBS
            push!(UPGRADABLE_STDLIBS_UUIDS, UUID(uuid))
            continue
        end
        deps = UUID.(values(get(project, "deps", Dict{String,Any}())))
        weakdeps = UUID.(values(get(project, "weakdeps", Dict{String,Any}())))
        stdlib[UUID(uuid)] = StdlibInfo(name, Base.UUID(uuid), version, deps, weakdeps)
    end
    return stdlib
end

function stdlibs()
    # This maintains a compatible format for `stdlibs()`, but new code should always
    # prefer `stdlib_infos` as it is more future-proofed, by returning a structure
    # rather than a tuple of elements.
    return Dict(uuid => (info.name, info.version) for (uuid, info) in stdlib_infos())
end
function stdlib_infos()
    if STDLIB[] === nothing
        STDLIB[] = load_stdlib()
    end
    return STDLIB[]
end
is_stdlib(uuid::UUID) = uuid in keys(stdlib_infos())
# Includes former stdlibs
function is_or_was_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    return is_stdlib(uuid, julia_version) || uuid in UPGRADABLE_STDLIBS_UUIDS
end


function historical_stdlibs_check()
    if isempty(STDLIBS_BY_VERSION)
        pkgerror("If you want to set `julia_version`, you must first populate the `STDLIBS_BY_VERSION` global constant.  Try `using HistoricalStdlibVersions`")
    end
end

# Find the entry in `STDLIBS_BY_VERSION`
# that corresponds to the requested version, and use that.
# If we can't find one, defaults to `UNREGISTERED_STDLIBS`
function get_last_stdlibs(julia_version::VersionNumber; use_historical_for_current_version = false)
    if !use_historical_for_current_version && julia_version == VERSION
        return stdlib_infos()
    end
    historical_stdlibs_check()
    last_stdlibs = UNREGISTERED_STDLIBS
    for (version, stdlibs) in STDLIBS_BY_VERSION
        if VersionNumber(julia_version.major, julia_version.minor, julia_version.patch) < version
            break
        end
        last_stdlibs = stdlibs
    end
    return last_stdlibs
end
# If `julia_version` is set to `nothing`, that means (essentially) treat all registered
# stdlibs as normal packages so that we get the latest versions of everything, ignoring
# julia compat.  So we set the list of stdlibs to that of only the unregistered stdlibs.
function get_last_stdlibs(::Nothing)
    historical_stdlibs_check()
    return UNREGISTERED_STDLIBS
end

# Allow asking if something is an stdlib for a particular version of Julia
function is_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    # Only use the cache if we are asking for stdlibs in a custom Julia version
    if julia_version == VERSION
        return is_stdlib(uuid)
    end

    last_stdlibs = get_last_stdlibs(julia_version)
    # Note that if the user asks for something like `julia_version = 0.7.0`, we'll
    # fall through with an empty `last_stdlibs`, which will always return `false`.
    return uuid in keys(last_stdlibs)
end

# Return the version of a stdlib with respect to a particular Julia version, or
# `nothing` if that stdlib is not versioned.  We only store version numbers for
# stdlibs that are external and thus could be installed from their repositories,
# e.g. things like `GMP_jll`, `Tar`, etc...
function stdlib_version(uuid::UUID, julia_version::Union{VersionNumber,Nothing})
    last_stdlibs = get_last_stdlibs(julia_version)
    if !(uuid in keys(last_stdlibs))
        return nothing
    end
    return last_stdlibs[uuid].version
end

function is_unregistered_stdlib(uuid::UUID)
    historical_stdlibs_check()
    return haskey(UNREGISTERED_STDLIBS, uuid)
end

Context!(kw_context::Vector{Pair{Symbol,Any}})::Context =
    Context!(Context(); kw_context...)
function Context!(ctx::Context; kwargs...)
    for (k, v) in kwargs
        setfield!(ctx, k, v)
    end
    return ctx
end

function load_workspace_weak_deps(env::EnvCache)
    # TODO: Possible name collision between projects in a workspace?
    weakdeps = Dict{String, UUID}()
    merge!(weakdeps, env.project.weakdeps)
    for (_, proj) in env.workspace
        merge!(weakdeps, proj.weakdeps)
    end
    return weakdeps
end

# only hash the deps and compat fields as they are the only fields that affect a resolve
function workspace_resolve_hash(env::EnvCache)
    # Handle deps in both [deps] and [weakdeps]
    deps = Dict(pkg.name => pkg.uuid for pkg in Pkg.Operations.load_direct_deps(env))
    weakdeps = load_workspace_weak_deps(env)
    alldeps = merge(deps, weakdeps)
    compats = Dict(name => Pkg.Operations.get_compat_workspace(env, name) for (name, uuid) in alldeps)
    iob = IOBuffer()
    for (name, uuid) in sort!(collect(deps); by=first)
        println(iob, name, "=", uuid)
    end
    println(iob)
    for (name, uuid) in sort!(collect(weakdeps); by=first)
        println(iob, name, "=", uuid)
    end
    println(iob)
    for (name, compat) in sort!(collect(compats); by=first)
        println(iob, name, "=", compat)
    end
    str = String(take!(iob))
    return bytes2hex(sha1(str))
end


write_env_usage(source_file::AbstractString, usage_filepath::AbstractString) =
    write_env_usage([source_file], usage_filepath)

function write_env_usage(source_files, usage_filepath::AbstractString)
    # Don't record ghost usage
    source_files = filter(isfile, source_files)
    isempty(source_files) && return

    # Ensure that log dir exists
    !ispath(logdir()) && mkpath(logdir())

    usage_file = joinpath(logdir(), usage_filepath)
    timestamp = now()

    ## Atomically write usage file using process id locking
    FileWatching.mkpidlock(usage_file * ".pid", stale_age = 3) do
        usage = if isfile(usage_file)
            try
                TOML.parsefile(usage_file)
            catch err
                @warn "Failed to parse usage file `$usage_file`, ignoring." err
                Dict{String, Any}()
            end
        else
            Dict{String, Any}()
        end

        # record new usage
        for source_file in source_files
            usage[source_file] = [Dict("time" => timestamp)]
        end

        # keep only latest usage info
        for k in keys(usage)
            times = map(usage[k]) do d
                if haskey(d, "time")
                    Dates.DateTime(d["time"])
                else
                    # if there's no time entry because of a write failure be conservative and mark it as being used now
                    @debug "Usage file `$usage_filepath` has a missing `time` entry for `$k`. Marking as used `now()`"
                    Dates.now()
                end
            end
            usage[k] = [Dict("time" => maximum(times))]
        end

        tempfile = tempname()
        try
            open(tempfile, "w") do io
                TOML.print(io, usage, sorted=true)
            end
            TOML.parsefile(tempfile) # compare to `usage` ?
            mv(tempfile, usage_file; force=true) # only mv if parse succeeds
        catch err
            @error "Failed to write valid usage file `$usage_file`" tempfile
        end
    end
    return
end

function read_package(path::String)
    project = read_project(path)
    if project.name === nothing
        pkgerror("expected a `name` entry in project file at `$(abspath(path))`")
    end
    if project.uuid === nothing
        pkgerror("expected a `uuid` entry in project file at `$(abspath(path))`")
    end
    name = project.name
    entry_point = something(project.entryfile, joinpath("src", "$(name).jl"))
    pkgpath = joinpath(dirname(path), entry_point)
    if !isfile(pkgpath)
        pkgerror("expected the file `$pkgpath` to exist for package `$name` at `$(dirname(path))`")
    end
    return project
end

const refspecs = ["+refs/*:refs/remotes/cache/*"]

function relative_project_path(project_file::String, path::String)
    # compute path relative the project
    # realpath needed to expand symlinks before taking the relative path
    return relpath(Pkg.safe_realpath(abspath(path)),
                   Pkg.safe_realpath(dirname(project_file)))
end

function devpath(env::EnvCache, name::AbstractString, shared::Bool)
    @assert name != ""
    dev_dir = shared ? abspath(Pkg.devdir()) : joinpath(dirname(env.project_file), "dev")
    return joinpath(dev_dir, name)
end

function error_if_in_sysimage(pkg::PackageSpec)
    RESPECT_SYSIMAGE_VERSIONS[] || return false
    if pkg.uuid === nothing
        @error "Expected package $(pkg.name) to have a set UUID, please file a bug report."
        return false
    end
    pkgid = Base.PkgId(pkg.uuid, pkg.name)
    if Base.in_sysimage(pkgid)
        pkgerror("Tried to develop or add by URL package $(pkgid) which is already in the sysimage, use `Pkg.respect_sysimage_versions(false)` to disable this check.")
    end
end

function handle_repo_develop!(ctx::Context, pkg::PackageSpec, shared::Bool)
    # First, check if we can compute the path easily (which requires a given local path or name)
    is_local_path = pkg.repo.source !== nothing && !isurl(pkg.repo.source)
    if is_local_path || pkg.name !== nothing
        dev_path = is_local_path ? pkg.repo.source : devpath(ctx.env, pkg.name, shared)
        if pkg.repo.subdir !== nothing
            dev_path = joinpath(dev_path, pkg.repo.subdir)
        end
        # If given an explicit local path, that needs to exist
        if is_local_path && !isdir(dev_path)
            if isfile(dev_path)
                pkgerror("Dev path `$(dev_path)` is a file, but a directory is required.")
            else
                pkgerror("Dev path `$(dev_path)` does not exist.")
            end
        end
        if isdir(dev_path)
            resolve_projectfile!(pkg, dev_path)
            error_if_in_sysimage(pkg)
            if is_local_path
                pkg.path = isabspath(dev_path) ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
            else
                pkg.path = shared ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
            end
            return false
        end
    end
    # If we dev by name and it is in the Project + tracking a repo in the source we can get the repo from the Manifest
    if pkg.name !== nothing && pkg.uuid === nothing
        uuid = get(ctx.env.project.deps, pkg.name, nothing)
        if uuid !== nothing
            entry = manifest_info(ctx.env.manifest, uuid)
            if entry !== nothing
                pkg.repo.source = entry.repo.source
                pkg.repo.subdir = entry.repo.subdir
            end
        end
    end

    # Still haven't found the source, try get it from the registry
    if pkg.repo.source === nothing
        set_repo_source_from_registry!(ctx, pkg)
    end
    @assert pkg.repo.source !== nothing

    repo_path = tempname()
    cloned = false
    package_path = pkg.repo.subdir === nothing ? repo_path : joinpath(repo_path, pkg.repo.subdir)
    if !has_name(pkg)
        LibGit2.close(GitTools.ensure_clone(ctx.io, repo_path, pkg.repo.source))
        cloned = true
        resolve_projectfile!(pkg, package_path)
    end
    if pkg.repo.subdir !== nothing
        repo_name = split(pkg.repo.source, '/', keepempty=false)[end]
        # Make the develop path prettier.
        if endswith(repo_name, ".git")
            repo_name = chop(repo_name, tail=4)
        end
        if endswith(repo_name, ".jl")
            repo_name = chop(repo_name, tail=3)
        end
        dev_path = devpath(ctx.env, repo_name, shared)
    else
        dev_path = devpath(ctx.env, pkg.name, shared)
    end
    if isdir(dev_path)
        println(ctx.io, "Path `$(dev_path)` exists and looks like the correct repo. Using existing path.")
        new = false
    else
        mkpath(dirname(dev_path))
        if !cloned
            LibGit2.close(GitTools.ensure_clone(ctx.io, dev_path, pkg.repo.source))
        else
            mv(repo_path, dev_path)
        end
        new = true
    end
    if !has_uuid(pkg)
        resolve_projectfile!(pkg, dev_path)
    end
    error_if_in_sysimage(pkg)
    pkg.path = shared ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
    if pkg.repo.subdir !== nothing
        pkg.path = joinpath(pkg.path, pkg.repo.subdir)
    end

    return new
end

function handle_repos_develop!(ctx::Context, pkgs::AbstractVector{PackageSpec}, shared::Bool)
    new_uuids = Set{UUID}()
    for pkg in pkgs
        new = handle_repo_develop!(ctx, pkg, shared)
        new && push!(new_uuids, pkg.uuid)
        @assert pkg.path !== nothing
        @assert has_uuid(pkg)
        pkg.repo = GitRepo() # clear repo field, no longer needed
    end
    return new_uuids
end

add_repo_cache_path(url::String) = joinpath(depots1(), "clones", string(hash(url)))

function set_repo_source_from_registry!(ctx, pkg)
    registry_resolve!(ctx.registries, pkg)
    # Didn't find the package in the registry, but maybe it exists in the updated registry
    if !isresolved(pkg)
        Pkg.Operations.update_registries(ctx; force=false)
        registry_resolve!(ctx.registries, pkg)
    end
    ensure_resolved(ctx, ctx.env.manifest, [pkg]; registry=true)
    # We might have been given a name / uuid combo that does not have an entry in the registry
    for reg in ctx.registries
        regpkg = get(reg, pkg.uuid, nothing)
        regpkg === nothing && continue
        info = Pkg.Registry.registry_info(regpkg)
        url = info.repo
        url === nothing && continue
        pkg.repo.source = url
        if info.subdir !== nothing
            pkg.repo.subdir = info.subdir
        end
        return
    end
    pkgerror("Repository for package with UUID `$(pkg.uuid)` could not be found in a registry.")
end


function handle_repo_add!(ctx::Context, pkg::PackageSpec)
    # The first goal is to populate pkg.repo.source if that wasn't given explicitly
    if pkg.repo.source === nothing
        @assert pkg.repo.rev !== nothing
        # First, we try resolving against the manifest and current registry to avoid updating registries if at all possible.
        # This also handles the case where we _only_ wish to switch the tracking branch for a package.
        manifest_resolve!(ctx.env.manifest, [pkg]; force=true)
        if isresolved(pkg)
            entry = manifest_info(ctx.env.manifest, pkg.uuid)
            if entry !== nothing
                pkg.repo.source = entry.repo.source
                pkg.repo.subdir = entry.repo.subdir
            end
        end
        if pkg.repo.source === nothing
            set_repo_source_from_registry!(ctx, pkg)
        end
    end
    @assert pkg.repo.source !== nothing

    # We now have the source of the package repo, check if it is a local path and if that exists
    repo_source = pkg.repo.source
    if !isurl(pkg.repo.source)
        if isdir(pkg.repo.source)
            if !isdir(joinpath(pkg.repo.source, ".git"))
                msg = "Did not find a git repository at `$(pkg.repo.source)`"
                if isfile(joinpath(pkg.repo.source, "Project.toml")) || isfile(joinpath(pkg.repo.source, "JuliaProject.toml"))
                    msg *= ", perhaps you meant `Pkg.develop`?"
                end
                pkgerror(msg)
            end
            LibGit2.with(GitTools.check_valid_HEAD, LibGit2.GitRepo(pkg.repo.source)) # check for valid git HEAD
            pkg.repo.source = isabspath(pkg.repo.source) ? safe_realpath(pkg.repo.source) : relative_project_path(ctx.env.manifest_file, pkg.repo.source)
            repo_source = normpath(joinpath(dirname(ctx.env.manifest_file), pkg.repo.source))
        else
            pkgerror("Path `$(pkg.repo.source)` does not exist.")
        end
    end

    let repo_source = repo_source
        # The type-assertions below are necessary presumably due to julia#36454
        LibGit2.with(GitTools.ensure_clone(ctx.io, add_repo_cache_path(repo_source::Union{Nothing,String}), repo_source::Union{Nothing,String}; isbare=true)) do repo
            repo_source_typed = repo_source::Union{Nothing,String}
            GitTools.check_valid_HEAD(repo)

            # If the user didn't specify rev, assume they want the default (master) branch if on a branch, otherwise the current commit
            if pkg.repo.rev === nothing
                pkg.repo.rev = LibGit2.isattached(repo) ? LibGit2.branch(repo) : string(LibGit2.GitHash(LibGit2.head(repo)))
            end
            rev_or_hash = pkg.tree_hash === nothing ? pkg.repo.rev : pkg.tree_hash
            obj_branch = get_object_or_branch(repo, rev_or_hash)
            fetched = false
            if obj_branch === nothing
                fetched = true
                GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs=refspecs)
                obj_branch = get_object_or_branch(repo, rev_or_hash)
                if obj_branch === nothing
                    pkgerror("Did not find rev $(rev_or_hash) in repository")
                end
            end
            gitobject, isbranch = obj_branch

            # If we are tracking a branch and are not pinned we want to update the repo if we haven't done that yet
            innerentry = manifest_info(ctx.env.manifest, pkg.uuid)
            ispinned = innerentry !== nothing && innerentry.pinned
            if isbranch && !fetched && !ispinned
                GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs=refspecs)
                gitobject, isbranch = get_object_or_branch(repo, rev_or_hash)
            end

            # Now we have the gitobject for our ref, time to find the tree hash for it
            tree_hash_object = LibGit2.peel(LibGit2.GitTree, gitobject)
            if pkg.repo.subdir !== nothing
                try
                    tree_hash_object = tree_hash_object[pkg.repo.subdir]
                catch e
                    e isa KeyError || rethrow()
                    pkgerror("Did not find subdirectory `$(pkg.repo.subdir)`")
                end
            end
            pkg.tree_hash = SHA1(string(LibGit2.GitHash(tree_hash_object)))

            # If we already resolved a uuid, we can bail early if this package is already installed at the current tree_hash
            if has_uuid(pkg)
                error_if_in_sysimage(pkg)
                version_path = Pkg.Operations.source_path(ctx.env.project_file, pkg, ctx.julia_version)
                isdir(version_path) && return false
            end

            temp_path = mktempdir()
            GitTools.checkout_tree_to_path(repo, tree_hash_object, temp_path)
            resolve_projectfile!(pkg, temp_path)
            error_if_in_sysimage(pkg)

            # Now that we are fully resolved (name, UUID, tree_hash, repo.source, repo.rev), we can finally
            # check to see if the package exists at its canonical path.
            version_path = Pkg.Operations.source_path(ctx.env.project_file, pkg, ctx.julia_version)
            isdir(version_path) && return false

            # Otherwise, move the temporary path into its correct place and set read only
            mkpath(version_path)
            mv(temp_path, version_path; force=true)
            set_readonly(version_path)
            return true
        end
    end
end

function handle_repos_add!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    new_uuids = Set{UUID}()
    for pkg in pkgs
        handle_repo_add!(ctx, pkg) && push!(new_uuids, pkg.uuid)
        @assert pkg.name !== nothing && pkg.uuid !== nothing && pkg.tree_hash !== nothing
    end
    return new_uuids
end

function resolve_projectfile!(pkg, project_path)
    project_file = projectfile_path(project_path; strict=true)
    project_file === nothing && pkgerror(string("could not find project file (Project.toml or JuliaProject.toml) in package at `",
                    something(pkg.repo.source, pkg.path, project_path), "` maybe `subdir` needs to be specified"))
    project_data = read_package(project_file)
    if pkg.uuid === nothing || pkg.uuid == project_data.uuid
        pkg.uuid = project_data.uuid
    else
        pkgerror("UUID `$(project_data.uuid)` given by project file `$project_file` does not match given UUID `$(pkg.uuid)`")
    end
    if pkg.name === nothing || pkg.name == project_data.name
        pkg.name = project_data.name
    else
        pkgerror("name `$(project_data.name)` given by project file `$project_file` does not match given name `$(pkg.name)`")
    end
end

get_object_or_branch(repo, rev::SHA1) =
    get_object_or_branch(repo, string(rev))

# Returns nothing if rev could not be found in repo
function get_object_or_branch(repo, rev)
    try
        gitobject = LibGit2.GitObject(repo, "remotes/cache/heads/" * rev)
        return gitobject, true
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    try
        gitobject = LibGit2.GitObject(repo, "remotes/origin/" * rev)
        return gitobject, true
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    try
        gitobject = LibGit2.GitObject(repo, rev)
        return gitobject, false
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    return nothing
end

########################################
# Resolving packages from name or uuid #
########################################

function project_resolve!(env::EnvCache, pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        if has_uuid(pkg) && !has_name(pkg) && Types.is_project_uuid(env, pkg.uuid)
            pkg.name = env.pkg.name
        end
        if has_name(pkg) && !has_uuid(pkg) && Types.is_project_name(env, pkg.name)
            pkg.uuid = env.pkg.uuid
        end
    end
end

# Disambiguate name/uuid package specifications using project info.
function project_deps_resolve!(env::EnvCache, pkgs::AbstractVector{PackageSpec})
    uuids = copy(env.project.deps)
    for (_, project) in env.workspace
        merge!(uuids, project.deps)
    end
    names = Dict(uuid => name for (name, uuid) in uuids)
    for pkg in pkgs
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            pkg.uuid = uuids[pkg.name]
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
end

# Disambiguate name/uuid package specifications using manifest info.
function manifest_resolve!(manifest::Manifest, pkgs::AbstractVector{PackageSpec}; force=false)
    uuids = Dict{String,Vector{UUID}}()
    names = Dict{UUID,String}()
    for (uuid, entry) in manifest
        push!(get!(uuids, entry.name, UUID[]), uuid)
        names[uuid] = entry.name # can be duplicate but doesn't matter
    end
    for pkg in pkgs
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            length(uuids[pkg.name]) == 1 && (pkg.uuid = uuids[pkg.name][1])
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
end

# Disambiguate name/uuid package specifications using registry info.
registry_resolve!(registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec) = registry_resolve!(registries, [pkg])
function registry_resolve!(registries::Vector{Registry.RegistryInstance}, pkgs::AbstractVector{PackageSpec})
    # if there are no half-specified packages, return early
    any(pkg -> has_name(pkg) ⊻ has_uuid(pkg), pkgs) || return
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            pkg.uuid = registered_uuid(registries, pkg.name)
        end
        if has_uuid(pkg) && !has_name(pkg)
            pkg.name = registered_name(registries, pkg.uuid)
        end
    end
    return pkgs
end

function stdlib_resolve!(pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            for (uuid, info) in stdlib_infos()
                if info.name == pkg.name
                    pkg.uuid = uuid
                end
            end
        end
        if !has_name(pkg) && has_uuid(pkg)
            info = get(stdlib_infos(), pkg.uuid, nothing)
            if info !== nothing
                pkg.name = info.name
            end
        end
    end
end

include("fuzzysorting.jl")

# Ensure that all packages are fully resolved
function ensure_resolved(ctx::Context, manifest::Manifest,
        pkgs::AbstractVector{PackageSpec};
        registry::Bool=false,)::Nothing
    unresolved_uuids = Dict{String,Vector{UUID}}()
    for pkg in pkgs
        has_uuid(pkg) && continue
        !has_name(pkg) && pkgerror("Package $pkg has neither name nor uuid")
        uuids = [uuid for (uuid, entry) in manifest if entry.name == pkg.name]
        sort!(uuids, by=uuid -> uuid.value)
        unresolved_uuids[pkg.name] = uuids
    end
    unresolved_names = UUID[]
    for pkg in pkgs
        has_name(pkg) && continue
        push!(unresolved_names, pkg.uuid)
    end
    isempty(unresolved_uuids) && isempty(unresolved_names) && return
    msg = sprint(context = ctx.io) do io
        if !isempty(unresolved_uuids)
            print(io, "The following package names could not be resolved:")
            for (name, uuids) in sort!(collect(unresolved_uuids), by=lowercase ∘ first)
                print(io, "\n * $name (")
                if length(uuids) == 0
                    what = ["project", "manifest"]
                    registry && push!(what, "registry")
                    print(io, "not found in ")
                    join(io, what, ", ", " or ")
                    print(io, ")")
                    all_names = available_names(ctx; manifest, include_registries = registry)
                    all_names_ranked, any_score_gt_thresh = FuzzySorting.fuzzysort(name, all_names)
                    if any_score_gt_thresh
                        println(io)
                        prefix = "   Suggestions:"
                        printstyled(io, prefix, color = Base.info_color())
                        FuzzySorting.printmatches(io, name, all_names_ranked; cols = FuzzySorting._displaysize(ctx.io)[2] - length(prefix))
                    end
                else
                    join(io, uuids, ", ", " or ")
                    print(io, " in manifest but not in project)")
                end
            end
        end
        if !isempty(unresolved_names)
            println(io, "The following package uuids could not be resolved:")
            for uuid in unresolved_names
                println(io, " * $uuid")
            end
        end
    end
    pkgerror(msg)
end

function available_names(ctx::Context = Context(); manifest::Manifest = ctx.env.manifest, include_registries::Bool = true)
    all_names = String[]
    for (_, pkgentry) in manifest
        push!(all_names, pkgentry.name)
    end
    if include_registries
        for reg in ctx.registries
            for (_, pkgentry) in reg.pkgs
                push!(all_names, pkgentry.name)
            end
        end
    end
    return unique(all_names)
end

function registered_uuids(registries::Vector{Registry.RegistryInstance}, name::String)
    uuids = Set{UUID}()
    for reg in registries
        union!(uuids, Registry.uuids_from_name(reg, name))
    end
    return uuids
end
# Determine a single UUID for a given name, prompting if needed
function registered_uuid(registries::Vector{Registry.RegistryInstance}, name::String)::Union{Nothing,UUID}
    uuids = registered_uuids(registries, name)
    length(uuids) == 0 && return nothing
    length(uuids) == 1 && return first(uuids)
    repo_infos = Tuple{String, String, UUID}[]
    for uuid in uuids
        for reg in registries
            pkg = get(reg, uuid, nothing)
            pkg === nothing && continue
            info = Pkg.Registry.registry_info(pkg)
            repo = info.repo
            repo === nothing && continue
            push!(repo_infos, (reg.name, repo, uuid))
        end
    end
    pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
end

# Determine current name for a given package UUID

function registered_name(registries::Vector{Registry.RegistryInstance}, uuid::UUID)::Union{Nothing,String}
    name = nothing
    for reg in registries
        regpkg = get(reg, uuid, nothing)
        regpkg === nothing && continue
        name′ = regpkg.name
        if name !== nothing
            name′ == name || pkgerror("package `$uuid` has multiple registered name values: $name, $name′")
        end
        name = name′
    end
    return name
end

# Find package by UUID in the manifest file
manifest_info(::Manifest, uuid::Nothing) = nothing
function manifest_info(manifest::Manifest, uuid::UUID)::Union{PackageEntry,Nothing}
    return get(manifest, uuid, nothing)
end
function write_env(env::EnvCache; update_undo=true,
                   skip_writing_project::Bool=false)
    # Verify that the generated manifest is consistent with `sources`
    for (pkg, uuid) in env.project.deps
        path, repo = get_path_repo(env.project, pkg)
        entry = manifest_info(env.manifest, uuid)
        if path !== nothing
            @assert entry.path == path
        end
        if repo != GitRepo()
            @assert entry.repo.source == repo.source
            if repo.rev !== nothing
                @assert entry.repo.rev == repo.rev
            end
            if entry.repo.subdir !== nothing
                @assert entry.repo.subdir == repo.subdir
            end
        end
        if entry.path !== nothing
            env.project.sources[pkg] = Dict("path" => entry.path)
        elseif entry.repo != GitRepo()
            d = Dict("url" => entry.repo.source)
            entry.repo.rev !== nothing && (d["rev"] = entry.repo.rev)
            env.project.sources[pkg] = d
        end
    end

    if (env.project != env.original_project) && (!skip_writing_project)
        write_project(env)
    end
    if env.manifest != env.original_manifest
        write_manifest(env)
    end
    update_undo && Pkg.API.add_snapshot_to_undo(env)
end



end # module
