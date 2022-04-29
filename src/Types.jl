# This file is a part of Julia. License is MIT: https://julialang.org/license

module Types

using UUIDs
using Random
using Dates
import LibGit2
import REPL
import Base.string
using REPL.TerminalMenus

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
    PkgError, pkgerror, has_name, has_uuid, is_stdlib, stdlib_version, is_unregistered_stdlib, stdlibs, write_env, write_env_usage, parse_toml,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved,
    registered_name,
    manifest_info,
    read_project, read_package, read_manifest,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PreserveLevel, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_NONE,
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
const TOML_CACHE = Base.TOMLCache(TOML.Parser(), Dict{String, Dict{String, Any}}())
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
@enum(PreserveLevel, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_NONE)
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
    url
    rev
    subdir

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
PackageSpec(name::AbstractString) = PackageSpec(;name=name)
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(;name=name, uuid=uuid)
PackageSpec(name::AbstractString, version::VersionTypes) = PackageSpec(;name=name, version=version)
PackageSpec(n::AbstractString, u::UUID, v::VersionTypes) = PackageSpec(;name=n, uuid=u, version=v)

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
    f = []
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
        push!(f, "repo/source" => string("\"", pkg.repo.source, "\""))
    end
    if pkg.repo.rev !== nothing
        push!(f, "repo/rev" => pkg.repo.rev)
    end
    if pkg.repo.subdir !== nothing
        push!(f, "repo/subdir" => pkg.repo.subdir)
    end
    print(io, "PackageSpec(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", value, "\n")
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
    man_names = @static Base.manifest_names isa Tuple ? Base.manifest_names : Base.manifest_names()
    for name in man_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    if strict
        return nothing
    else
        n_names = length(man_names)
        if n_names == 1
            return joinpath(env_path, only(man_name))
        else
            project = basename(projectfile_path(env_path)::String)
            idx = findfirst(x -> x == project, Base.project_names)
            @assert idx !== nothing
            idx = idx + (n_names - length(Base.project_names)) # ignore custom name if present
            return joinpath(env_path, man_names[idx])
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

Base.@kwdef mutable struct Project
    other::Dict{String,Any} = Dict{String,Any}()
    # Fields
    name::Union{String, Nothing} = nothing
    uuid::Union{UUID, Nothing} = nothing
    version::Union{VersionTypes, Nothing} = nothing
    manifest::Union{String, Nothing} = nothing
    # Sections
    deps::Dict{String,UUID} = Dict{String,UUID}()
    extras::Dict{String,UUID} = Dict{String,UUID}()
    targets::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    compat::Dict{String,Compat} = Dict{String,Compat}()
end
Base.:(==)(t1::Project, t2::Project) = all(x -> (getfield(t1, x) == getfield(t2, x))::Bool, fieldnames(Project))
Base.hash(t::Project, h::UInt) = foldr(hash, [getfield(t, x) for x in fieldnames(Project)], init=h)

# only hash the deps and compat fields as they are the only fields that affect a resolve
function project_resolve_hash(t::Project)
    iob = IOBuffer()
    foreach(((name, uuid),) -> println(iob, name, "=", uuid), sort!(collect(t.deps); by=first))
    foreach(((name, compat),) -> println(iob, name, "=", compat.val), sort!(collect(t.compat); by=first))
    return bytes2hex(sha1(seekstart(iob)))
end

Base.@kwdef mutable struct PackageEntry
    name::Union{String,Nothing} = nothing
    version::Union{VersionNumber,Nothing} = nothing
    path::Union{String,Nothing} = nothing
    pinned::Bool = false
    repo::GitRepo = GitRepo()
    tree_hash::Union{Nothing,SHA1} = nothing
    deps::Dict{String,UUID} = Dict{String,UUID}()
    uuid::Union{Nothing, UUID} = nothing
    other::Union{Dict,Nothing} = nothing
end
Base.:(==)(t1::PackageEntry, t2::PackageEntry) = t1.name == t2.name &&
    t1.version == t2.version &&
    t1.path == t2.path &&
    t1.pinned == t2.pinned &&
    t1.repo == t2.repo &&
    t1.tree_hash == t2.tree_hash &&
    t1.deps == t2.deps &&
    t1.uuid == t2.uuid
    # omits `other`
Base.hash(x::PackageEntry, h::UInt) = foldr(hash, [x.name, x.version, x.path, x.pinned, x.repo, x.tree_hash, x.deps, x.uuid], init=h)  # omits `other`

Base.@kwdef mutable struct Manifest
    julia_version::Union{Nothing,VersionNumber} = nothing # only set to VERSION when resolving
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

include("project.jl")
include("manifest.jl")

# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    io::IO = stderr_f()
    use_git_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    num_concurrent_downloads::Int = 8

    # Registris
    registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries()

    # The Julia Version to resolve with respect to
    julia_version::Union{VersionNumber,Nothing} = VERSION
end

project_uuid(env::EnvCache) = env.pkg === nothing ? nothing : env.pkg.uuid
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

const STDLIB = Ref{Dict{UUID,Tuple{String,Union{VersionNumber,Nothing}}}}()
function load_stdlib()
    stdlib = Dict{UUID,Tuple{String,Union{VersionNumber,Nothing}}}()
    for name in readdir(stdlib_dir())
        projfile = projectfile_path(stdlib_path(name); strict=true)
        nothing === projfile && continue
        project = parse_toml(projfile)
        uuid = get(project, "uuid", nothing)
        v_str = get(project, "version", nothing)
        version = isnothing(v_str) ? nothing : VersionNumber(v_str)
        nothing === uuid && continue
        stdlib[UUID(uuid)] = (name, version)
    end
    return stdlib
end

function stdlibs()
    if !isassigned(STDLIB)
        STDLIB[] = load_stdlib()
    end
    return STDLIB[]
end
is_stdlib(uuid::UUID) = uuid in keys(stdlibs())

# Find the entry in `STDLIBS_BY_VERSION`
# that corresponds to the requested version, and use that.
# If we can't find one, defaults to `UNREGISTERED_STDLIBS`
function get_last_stdlibs(julia_version::VersionNumber; use_historical_for_current_version = false)
    if !use_historical_for_current_version && julia_version == VERSION
        return stdlibs()
    end
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
get_last_stdlibs(::Nothing) = UNREGISTERED_STDLIBS

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
    return last_stdlibs[uuid][2]
end

is_unregistered_stdlib(uuid::UUID) = haskey(UNREGISTERED_STDLIBS, uuid)

Context!(kw_context::Vector{Pair{Symbol,Any}})::Context =
    Context!(Context(); kw_context...)
function Context!(ctx::Context; kwargs...)
    for (k, v) in kwargs
        setfield!(ctx, k, v)
    end
    return ctx
end

function write_env_usage(source_file::AbstractString, usage_filepath::AbstractString)
    # Don't record ghost usage
    !isfile(source_file) && return

    # Ensure that log dir exists
    !ispath(logdir()) && mkpath(logdir())

    usage_file = joinpath(logdir(), usage_filepath)
    timestamp = now()

    ## Atomically write usage file using process id locking
    FileWatching.mkpidlock(usage_file * ".pid", stale_age = 3) do
        usage = if isfile(usage_file)
            TOML.parsefile(usage_file)
        else
            Dict{String, Any}()
        end

        # record new usage
        usage[source_file] = [Dict("time" => timestamp)]

        # keep only latest usage info
        for k in keys(usage)
            times = map(d -> Dates.DateTime(d["time"]), usage[k])
            usage[k] = [Dict("time" => maximum(times))]
        end

        open(usage_file, "w") do io
            TOML.print(io, usage, sorted=true)
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
    if !isfile(joinpath(dirname(path), "src", "$name.jl"))
        pkgerror("expected the file `src/$name.jl` to exist for package `$name` at `$(dirname(path))`")
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
            resolve_projectfile!(ctx.env, pkg, dev_path)
            error_if_in_sysimage(pkg)
            if is_local_path
                pkg.path = isabspath(dev_path) ? dev_path : relative_project_path(ctx.env.project_file, dev_path)
            else
                pkg.path = shared ? dev_path : relative_project_path(ctx.env.project_file, dev_path)
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
        resolve_projectfile!(ctx.env, pkg, package_path)
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
        resolve_projectfile!(ctx.env, pkg, dev_path)
    end
    error_if_in_sysimage(pkg)
    pkg.path = shared ? dev_path : relative_project_path(ctx.env.project_file, dev_path)
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
            if entry !== nothing && entry.repo.source !== nothing # reuse source in manifest
                pkg.repo.source = entry.repo.source
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
            pkg.repo.source = isabspath(pkg.repo.source) ? safe_realpath(pkg.repo.source) : relative_project_path(ctx.env.project_file, pkg.repo.source)
            repo_source = normpath(joinpath(dirname(ctx.env.project_file), pkg.repo.source))
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

            obj_branch = get_object_or_branch(repo, pkg.repo.rev)
            fetched = false
            if obj_branch === nothing
                fetched = true
                GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs=refspecs)
                obj_branch = get_object_or_branch(repo, pkg.repo.rev)
                if obj_branch === nothing
                    pkgerror("Did not find rev $(pkg.repo.rev) in repository")
                end
            end
            gitobject, isbranch = obj_branch

            # If we are tracking a branch and are not pinned we want to update the repo if we haven't done that yet
            innerentry = manifest_info(ctx.env.manifest, pkg.uuid)
            ispinned = innerentry !== nothing && innerentry.pinned
            if isbranch && !fetched && !ispinned
                GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs=refspecs)
                gitobject, isbranch = get_object_or_branch(repo, pkg.repo.rev)
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
            resolve_projectfile!(ctx.env, pkg, temp_path)
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

function resolve_projectfile!(env::EnvCache, pkg, project_path)
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
    uuids = env.project.deps
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
    # collect all names and uuids since we're looking anyway
    names = [pkg.name::String for pkg in pkgs if has_name(pkg)]
    uuids = [pkg.uuid::UUID for pkg in pkgs if has_uuid(pkg)]
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
            for (uuid, (name, version)) in stdlibs()
                name == pkg.name && (pkg.uuid = uuid)
            end
        end
        if !has_name(pkg) && has_uuid(pkg)
            name, version = get(stdlibs(), pkg.uuid, (nothing, nothing))
            nothing !== name && (pkg.name = name)
        end
    end
end

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
                    all_names_ranked, any_score_gt_zero = fuzzysort(name, all_names)
                    if any_score_gt_zero
                        println(io)
                        prefix = "   Suggestions:"
                        printstyled(io, prefix, color = Base.info_color())
                        REPL.printmatches(io, name, all_names_ranked; cols = REPL._displaysize(ctx.io)[2] - length(prefix))
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

# copied from REPL to efficiently expose if any score is >0
function fuzzysort(search::String, candidates::Vector{String})
    scores = map(cand -> (REPL.fuzzyscore(search, cand), -Float64(REPL.levenshtein(search, cand))), candidates)
    candidates[sortperm(scores)] |> reverse, any(s -> s[1] > 0, scores)
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
            info.repo === nothing && continue
            push!(repo_infos, (reg.name, info.repo, uuid))
        end
    end
    unique!(repo_infos)
    if isinteractive()
        # prompt for which UUID was intended:
        menu = RadioMenu(String["Registry: $(value[1]) - Repo: $(value[2]) - UUID: $(value[3])" for value in repo_infos])
        choice = request("There are multiple registered `$name` packages, choose one:", menu)
        choice == -1 && return nothing
        return repo_infos[choice][3]
    else
        pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
    end
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
    if (env.project != env.original_project) && (!skip_writing_project)
        write_project(env)
    end
    if env.manifest != env.original_manifest
        write_manifest(env)
    end
    update_undo && Pkg.API.add_snapshot_to_undo(env)
end



end # module
