# This file is a part of Julia. License is MIT: https://julialang.org/license

module Types

using UUIDs
using Random
using Dates
import LibGit2
import REPL
import Base.string
using REPL.TerminalMenus

using ..TOML
import ...Pkg, ..UPDATED_REGISTRY_THIS_SESSION, ..DEFAULT_IO
import ...Pkg: GitTools, depots, depots1, logdir, set_readonly, safe_realpath, pkg_server
import ..BinaryPlatforms: Platform
import ..PlatformEngines: probe_platform_engines!, download, download_verify_unpack

import Base: SHA1
using SHA

export UUID, pkgID, SHA1, VersionRange, VersionSpec,
    PackageSpec, EnvCache, Context, PackageInfo, ProjectInfo, GitRepo, Context!, err_rep,
    PkgError, pkgerror, has_name, has_uuid, is_stdlib, stdlibs, write_env, write_env_usage, parse_toml, find_registered!,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved,
    manifest_info, registered_uuids, registered_paths, registered_uuid, registered_name,
    read_project, read_package, read_manifest, pathrepr, registries,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PreserveLevel, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_NONE,
    printpkgstyle, isurl,
    projectfile_path, manifestfile_path,
    RegistrySpec

include("versions.jl")

const URL_regex = r"((file|git|ssh|http(s)?)|(git@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)?(/)?"x

## user-friendly representation of package IDs ##
function pkgID(p::UUID, uuid_to_name::Dict{UUID,String})
    name = get(uuid_to_name, p, "(unknown)")
    uuid_short = string(p)[1:8]
    return "$name [$uuid_short]"
end

#################
# Pkg Error #
#################
struct PkgError <: Exception
    msg::String
end
pkgerror(msg::String...) = throw(PkgError(join(msg)))
Base.showerror(io::IO, err::PkgError) = print(io, err.msg)


############
# Artifact #
############
Base.@kwdef struct Artifact
    name::Union{String,Nothing} = nothing
    url::Union{String,Nothing} = nothing
    tree_hash::Union{SHA1,Nothing} = nothing
    tarball_hash::Union{Vector{UInt8},Nothing} = nothing
    extract::Bool = false
    filename::Union{String,Nothing} = nothing
    platform::Union{Platform,Nothing} = nothing
end


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

isurl(r::String) = occursin(URL_regex, r)

Base.@kwdef mutable struct PackageSpec
    name::Union{Nothing,String} = nothing
    uuid::Union{Nothing,UUID} = nothing
    version::VersionTypes = VersionSpec()
    tree_hash::Union{Nothing,SHA1} = nothing
    repo::GitRepo = GitRepo()
    path::Union{Nothing,String} = nothing
    pinned::Bool = false
    mode::PackageMode = PKGMODE_PROJECT
end
PackageSpec(name::AbstractString) = PackageSpec(;name=name)
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(;name=name, uuid=uuid)
PackageSpec(name::AbstractString, version::VersionTypes) = PackageSpec(;name=name, version=version)
PackageSpec(n::AbstractString, u::UUID, v::VersionTypes) = PackageSpec(;name=n, uuid=u, version=v)

function Base.:(==)(a::PackageSpec, b::PackageSpec)
    return a.name == b.name && a.uuid == b.uuid && a.version == b.version &&
    a.tree_hash == b.tree_hash && a.repo == b.repo && a.path == b.path &&
    a.pinned == b.pinned && a.mode == b.mode
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
    pkg.path !== nothing && push!(f, "dev/path" => pkg.path)
    pkg.pinned && push!(f, "pinned" => pkg.pinned)
    push!(f, "version" => (vstr == "VersionSpec(\"*\")" ? "*" : vstr))
    if pkg.repo.source !== nothing
        push!(f, "url/path" => string("\"", pkg.repo.source, "\""))
    end
    if pkg.repo.rev !== nothing
        push!(f, "rev" => pkg.repo.rev)
    end
    if pkg.repo.subdir !== nothing
        push!(f, "subdir" => pkg.repo.subdir)
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

function parse_toml(path::String...; fakeit::Bool=false)
    p = joinpath(path...)
    !fakeit || isfile(p) ? TOML.parsefile(p) : Dict{String,Any}()
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
    compat::Dict{String,String} = Dict{String,String}()# TODO Dict{String, VersionSpec}
end
Base.:(==)(t1::Project, t2::Project) = all([getfield(t1, x) == getfield(t2, x) for x in fieldnames(Project)])
Base.hash(x::Project, h::UInt) = foldr(hash, [getfield(t, x) for x in fieldnames(Project)], init=h)


Base.@kwdef mutable struct PackageEntry
    name::Union{String,Nothing} = nothing
    version::Union{VersionNumber,Nothing} = nothing
    path::Union{String,Nothing} = nothing
    pinned::Bool = false
    repo::GitRepo = GitRepo()
    tree_hash::Union{Nothing,SHA1} = nothing
    deps::Dict{String,UUID} = Dict{String,UUID}()
    other::Union{Dict,Nothing} = nothing
end
Base.:(==)(t1::PackageEntry, t2::PackageEntry) = t1.name == t2.name &&
    t1.version == t2.version &&
    t1.path == t2.path &&
    t1.pinned == t2.pinned &&
    t1.repo == t2.repo &&
    t1.tree_hash == t2.tree_hash &&
    t1.deps == t2.deps   # omits `other`
Base.hash(x::PackageEntry, h::UInt) = foldr(hash, [x.name, x.version, x.path, x.pinned, x.repo, x.tree_hash, x.deps], init=h)  # omits `other`
const Manifest = Dict{UUID,PackageEntry}

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
    # registered package info:
    uuids::Dict{String,Vector{UUID}}
    paths::Dict{UUID,Vector{String}}
    names::Dict{UUID,Vector{String}}
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

    env′ = EnvCache(env,
        project_file,
        manifest_file,
        project_package,
        project,
        manifest,
        deepcopy(project),
        deepcopy(manifest),
        uuids,
        paths,
        names,)

    # Save initial environment for undo/redo functionality
    if !Pkg.API.saved_initial_snapshot[]
        Pkg.API.add_snapshot_to_undo(env′)
        Pkg.API.saved_initial_snapshot[] = true
    end

    return env′
end

include("project.jl")
include("manifest.jl")

# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    io::IO = something(DEFAULT_IO[], stderr)
    use_libgit2_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    # NOTE: The JULIA_PKG_CONCURRENCY environment variable is likely to be removed in
    # the future. It currently stands as an unofficial workaround for issue #795.
    num_concurrent_downloads::Int = haskey(ENV, "JULIA_PKG_CONCURRENCY") ? parse(Int, ENV["JULIA_PKG_CONCURRENCY"]) : 8
    graph_verbose::Bool = false
    currently_running_target::Bool = false
    # test instrumenting
    status_io::Union{IO,Nothing} = nothing
end

project_uuid(ctx::Context) = ctx.env.pkg === nothing ? nothing : ctx.env.pkg.uuid
collides_with_project(ctx::Context, pkg::PackageSpec) =
    is_project_name(ctx, pkg.name) || is_project_uuid(ctx, pkg.uuid)
is_project(ctx::Context, pkg::PackageSpec) = is_project_uuid(ctx, pkg.uuid)
is_project_name(ctx::Context, name::String) =
    ctx.env.pkg !== nothing && ctx.env.pkg.name == name
is_project_name(ctx::Context, name::Nothing) = false
is_project_uuid(ctx::Context, uuid::UUID) = project_uuid(ctx) == uuid

###########
# Context #
###########
stdlib_dir() = normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"))
stdlib_path(stdlib::String) = joinpath(stdlib_dir(), stdlib)

const STDLIB = Ref{Dict{UUID,String}}()
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

function stdlibs()
    if !isassigned(STDLIB)
        STDLIB[] = load_stdlib()
    end
    return STDLIB[]
end
is_stdlib(uuid::UUID) = uuid in keys(stdlibs())

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

function relative_project_path(ctx::Context, path::String)
    # compute path relative the project
    # realpath needed to expand symlinks before taking the relative path
    return relpath(Pkg.safe_realpath(abspath(path)),
                   Pkg.safe_realpath(dirname(ctx.env.project_file)))
end

function devpath(ctx::Context, name::AbstractString, shared::Bool)
    @assert name != ""
    dev_dir = shared ? abspath(Pkg.devdir()) : joinpath(dirname(ctx.env.project_file), "dev")
    return joinpath(dev_dir, name)
end

function handle_repo_develop!(ctx::Context, pkg::PackageSpec, shared::Bool)
    # First, check if we can compute the path easily (which requires a given local path or name)
    is_local_path = pkg.repo.source !== nothing && !isurl(pkg.repo.source)
    if is_local_path || pkg.name !== nothing
        dev_path = is_local_path ? pkg.repo.source : devpath(ctx, pkg.name, shared)
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
            resolve_projectfile!(ctx, pkg, dev_path)
            println(ctx.io, "Path `$(dev_path)` exists and looks like the correct package. Using existing path.")
            if is_local_path
                pkg.path = isabspath(dev_path) ? dev_path : relative_project_path(ctx, dev_path)
            else
                pkg.path = shared ? dev_path : relative_project_path(ctx, dev_path)
            end
            return false
        end
    end
    # If we dev by name and it is in the Project + tracking a repo in the source we can get the repo from the Manifest
    if pkg.name !== nothing && pkg.uuid === nothing
        uuid = get(ctx.env.project.deps, pkg.name, nothing)
        if uuid !== nothing
            entry = manifest_info(ctx, uuid)
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
        LibGit2.close(GitTools.ensure_clone(ctx, repo_path, pkg.repo.source))
        cloned = true
        resolve_projectfile!(ctx, pkg, package_path)
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
        dev_path = devpath(ctx, repo_name, shared)
    else
        dev_path = devpath(ctx, pkg.name, shared)
    end
    if isdir(dev_path)
        println(ctx.io, "Path `$(dev_path)` exists and looks like the correct repo. Using existing path.")
        new = false
    else
        mkpath(dirname(dev_path))
        if !cloned
            LibGit2.close(GitTools.ensure_clone(ctx, dev_path, pkg.repo.source))
        else
            mv(repo_path, dev_path)
        end
        new = true
    end
    if !has_uuid(pkg)
        resolve_projectfile!(ctx, pkg, dev_path)
    end
    pkg.path = shared ? dev_path : relative_project_path(ctx, dev_path)
    if pkg.repo.subdir !== nothing
        pkg.path = joinpath(pkg.path, pkg.repo.subdir)
    end

    return new
end

function handle_repos_develop!(ctx::Context, pkgs::AbstractVector{PackageSpec}, shared::Bool)
    new_uuids = UUID[]
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
    registry_resolve!(ctx, pkg)
    # Didn't find the package in the registry, but maybe it exists in the updated registry
    if !isresolved(pkg)
        update_registries(ctx)
        registry_resolve!(ctx, pkg)
    end
    ensure_resolved(ctx, [pkg]; registry=true)
    # We might have been given a name / uuid combo that does not have an entry in the registry
    repo_info = registered_info(ctx, pkg.uuid, "repo")
    if isempty(repo_info)
        pkgerror("Repository for package with UUID `$(pkg.uuid)` could not be found in a registry.")
    end
    _, repo_source = repo_info[1] # Just take the first repo we found
    pkg.repo.source = repo_source
    subdir_info = registered_info(ctx, pkg.uuid, "subdir")
    _, subdir = subdir_info[1] # Just take the first subdir we found
    if subdir !== nothing
        pkg.repo.subdir = subdir
    end
end


function handle_repo_add!(ctx::Context, pkg::PackageSpec)
    # The first goal is to populate pkg.repo.source if that wasn't given explicitly
    if pkg.repo.source === nothing
        @assert pkg.repo.rev !== nothing
        # First, we try resolving against the manifest and current registry to avoid updating registries if at all possible.
        # This also handles the case where we _only_ wish to switch the tracking branch for a package.
        manifest_resolve!(ctx, [pkg]; force=true)
        if isresolved(pkg)
            entry = manifest_info(ctx, pkg.uuid)
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
                pkgerror("Did not find a git repository at `$(pkg.repo.source)`")
            end
            LibGit2.with(GitTools.check_valid_HEAD, LibGit2.GitRepo(pkg.repo.source)) # check for valid git HEAD
            pkg.repo.source = isabspath(pkg.repo.source) ? safe_realpath(pkg.repo.source) : relative_project_path(ctx, pkg.repo.source)
            repo_source = normpath(joinpath(dirname(ctx.env.project_file), pkg.repo.source))
        else
            pkgerror("Path `$(pkg.repo.source)` does not exist.")
        end
    end

    LibGit2.with(GitTools.ensure_clone(ctx, add_repo_cache_path(repo_source), repo_source; isbare=true)) do repo
        GitTools.check_valid_HEAD(repo)

        # If the user didn't specify rev, assume they want the default (master) branch if on a branch, otherwise the current commit
        if pkg.repo.rev === nothing
            pkg.repo.rev = LibGit2.isattached(repo) ? LibGit2.branch(repo) : string(LibGit2.GitHash(LibGit2.head(repo)))
        end

        obj_branch = get_object_or_branch(repo, pkg.repo.rev)
        fetched = false
        if obj_branch === nothing
            fetched = true
            GitTools.fetch(ctx, repo, repo_source; refspecs=refspecs)
            obj_branch = get_object_or_branch(repo, pkg.repo.rev)
            if obj_branch === nothing
                pkgerror("Did not find rev $(pkg.repo.rev) in repository")
            end
        end
        gitobject, isbranch = obj_branch

        # If we are tracking a branch and are not pinned we want to update the repo if we haven't done that yet
        entry = manifest_info(ctx, pkg.uuid)
        ispinned = entry !== nothing && entry.pinned
        if isbranch && !fetched && !ispinned
            GitTools.fetch(ctx, repo, repo_source; refspecs=refspecs)
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
            version_path = Pkg.Operations.source_path(ctx, pkg)
            isdir(version_path) && return false
        end

        temp_path = mktempdir()
        GitTools.checkout_tree_to_path(repo, tree_hash_object, temp_path)
        package = resolve_projectfile!(ctx, pkg, temp_path)

        # Now that we are fully resolved (name, UUID, tree_hash, repo.source, repo.rev), we can finally
        # check to see if the package exists at its canonical path.
        version_path = Pkg.Operations.source_path(ctx, pkg)
        isdir(version_path) && return false

        # Otherwise, move the temporary path into its correct place and set read only
        mkpath(version_path)
        mv(temp_path, version_path; force=true)
        set_readonly(version_path)
        return true
    end
end

function handle_repos_add!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    new_uuids = UUID[]
    for pkg in pkgs
        handle_repo_add!(ctx, pkg) && push!(new_uuids, pkg.uuid)
        @assert pkg.name !== nothing && pkg.uuid !== nothing && pkg.tree_hash !== nothing
    end
    return new_uuids
end

function resolve_projectfile!(ctx, pkg, project_path)
    env = ctx.env
    project_file = projectfile_path(project_path; strict=true)
    project_file === nothing && pkgerror(string("could not find project file in package at `",
                                                pkg.repo.source !== nothing ? pkg.repo.source : (pkg.path)), "` maybe `subdir` needs to be specified")
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

function project_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        if has_uuid(pkg) && !has_name(pkg) && Types.is_project_uuid(ctx, pkg.uuid)
            pkg.name = ctx.env.pkg.name
        end
        if has_name(pkg) && !has_uuid(pkg) && Types.is_project_name(ctx, pkg.name)
            pkg.uuid = ctx.env.pkg.uuid
        end
    end
end

# Disambiguate name/uuid package specifications using project info.
function project_deps_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    uuids = ctx.env.project.deps
    names = Dict(uuid => name for (name, uuid) in uuids)
    for pkg in pkgs
        pkg.mode == PKGMODE_PROJECT || continue
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            pkg.uuid = uuids[pkg.name]
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
end

# Disambiguate name/uuid package specifications using manifest info.
function manifest_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec}; force=false)
    uuids = Dict{String,Vector{UUID}}()
    names = Dict{UUID,String}()
    for (uuid, entry) in ctx.env.manifest
        push!(get!(uuids, entry.name, UUID[]), uuid)
        names[uuid] = entry.name # can be duplicate but doesn't matter
    end
    for pkg in pkgs
        force || pkg.mode == PKGMODE_MANIFEST || continue
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            length(uuids[pkg.name]) == 1 && (pkg.uuid = uuids[pkg.name][1])
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
end

# Disambiguate name/uuid package specifications using registry info.
registry_resolve!(ctx::Context, pkg::PackageSpec) = registry_resolve!(ctx, [pkg])
function registry_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    # if there are no half-specified packages, return early
    any(pkg -> has_name(pkg) ⊻ has_uuid(pkg), pkgs) || return
    # collect all names and uuids since we're looking anyway
    names = String[pkg.name for pkg in pkgs if has_name(pkg)]
    uuids = UUID[pkg.uuid for pkg in pkgs if has_uuid(pkg)]
    find_registered!(ctx, names, uuids)
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            pkg.uuid = registered_uuid(ctx, pkg.name)
        end
        if has_uuid(pkg) && !has_name(pkg)
            pkg.name = registered_name(ctx, pkg.uuid)
        end
    end
    return pkgs
end

function stdlib_resolve!(pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            for (uuid, name) in stdlibs()
                name == pkg.name && (pkg.uuid = uuid)
            end
        end
        if !has_name(pkg) && has_uuid(pkg)
            name = get(stdlibs(), pkg.uuid, nothing)
            nothing !== name && (pkg.name = name)
        end
    end
end

# Ensure that all packages are fully resolved
function ensure_resolved(ctx::Context,
        pkgs::AbstractVector{PackageSpec};
        registry::Bool=false,)::Nothing
        unresolved_uuids = Dict{String,Vector{UUID}}()
    for name in [pkg.name for pkg in pkgs if !has_uuid(pkg)]
        uuids = [uuid for (uuid, entry) in ctx.env.manifest if entry.name == name]
        sort!(uuids, by=uuid -> uuid.value)
        unresolved_uuids[name] = uuids
    end
    unresolved_names = UUID[]
    for uuid in [pkg.uuid for pkg in pkgs if !has_name(pkg)]
        push!(unresolved_names, uuid)
    end
    isempty(unresolved_uuids) && isempty(unresolved_names) && return
    msg = sprint() do io
        if !isempty(unresolved_uuids)
            println(io, "The following package names could not be resolved:")
            for (name, uuids) in sort!(collect(unresolved_uuids), by=lowercase ∘ first)
                print(io, " * $name (")
                if length(uuids) == 0
                    what = ["project", "manifest"]
                    registry && push!(what, "registry")
                    print(io, "not found in ")
                    join(io, what, ", ", " or ")
                else
                    join(io, uuids, ", ", " or ")
                    print(io, " in manifest but not in project")
                end
                println(io, ")")
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

##############
# Registries #
##############

mutable struct RegistrySpec
    name::Union{String,Nothing}
    uuid::Union{UUID,Nothing}
    url::Union{String,Nothing}
    # the path field can be a local source when adding a registry
    # otherwise it is the path where the registry is installed
    path::Union{String,Nothing}
    RegistrySpec(name::String) = RegistrySpec(name = name)
    RegistrySpec(;name=nothing, uuid=nothing, url=nothing, path=nothing) =
        new(name, isa(uuid, String) ? UUID(uuid) : uuid, url, path)
end

const DEFAULT_REGISTRIES =
    RegistrySpec[RegistrySpec(name = "General",
                              uuid = UUID("23338594-aafe-5451-b93e-139f81909106"),
                              url = "https://github.com/JuliaRegistries/General.git")]

function clone_default_registries(ctx::Context; only_if_empty = true)
    installed_registries = [reg.uuid for reg in collect_registries()]
    # Only clone if there are no installed registries, unless called
    # with false keyword argument.
    if isempty(installed_registries) || !only_if_empty
        printpkgstyle(ctx, :Installing, "known registries into $(pathrepr(depots1()))")
        registries = copy(DEFAULT_REGISTRIES)
        for uuid in keys(pkg_server_registry_urls())
            if !(uuid in (reg.uuid for reg in registries))
                push!(registries, RegistrySpec(uuid = uuid))
            end
        end
        filter!(reg -> !(reg.uuid in installed_registries), registries)
        clone_or_cp_registries(registries)
    end
end

# Return `RegistrySpec`s of each registry in a depot
function collect_registries(depot::String)
    d = joinpath(depot, "registries")
    regs = RegistrySpec[]
    ispath(d) || return regs
    for name in readdir(d)
        file = joinpath(d, name, "Registry.toml")
        if isfile(file)
            registry = read_registry(file)
            verify_registry(registry)
            spec = RegistrySpec(name = registry["name"],
                                uuid = UUID(registry["uuid"]),
                                url = get(registry, "repo", nothing),
                                path = dirname(file))
            push!(regs, spec)
        end
    end
    return regs
end
# Return `RegistrySpec`s of all registries in all depots
function collect_registries()
    isempty(depots()) && return RegistrySpec[]
    return RegistrySpec[r for d in depots() for r in collect_registries(d)]
end

# Hacky way to make e.g. `registry add General` work.
function populate_known_registries_with_urls!(registries::Vector{RegistrySpec})
    known_registries = DEFAULT_REGISTRIES # TODO: Some way to add stuff here?
    for reg in registries, known in known_registries
        if reg.uuid !== nothing
            if reg.uuid === known.uuid
                reg.url = known.url
            end
        elseif reg.name !== nothing
            if reg.name == known.name
                named_regs = filter(r -> r.name == reg.name, known_registries)
                if !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                    pkgerror("multiple registries with name `$(reg.name)`, please specify with uuid.")
                end
                reg.url = known.url
                reg.uuid = known.uuid
            end
        end
    end
end

# Use the pattern
#
# registry_urls = nothing
# for ...
#     url, registry_urls = pkg_server_registry_url(uuid, registry_urls)
# end
#
# to query the pkg server at most once for registries.
pkg_server_registry_url(uuid::UUID, ::Nothing) =
    pkg_server_registry_url(uuid, pkg_server_registry_urls())

pkg_server_registry_url(uuid::UUID, registry_urls::Dict{UUID, String}) =
    get(registry_urls, uuid, nothing), registry_urls

pkg_server_registry_url(::Nothing, registry_urls) = nothing, registry_urls

function pkg_server_registry_urls()
    registry_urls = Dict{UUID, String}()
    server = pkg_server()
    server === nothing && return registry_urls
    probe_platform_engines!()
    tmp_path = tempname()
    download_ok = false
    try
        download("$server/registries", tmp_path, verbose=false)
        download_ok = true
    catch err
        @warn "could not download $server/registries"
    end
    download_ok || return registry_urls
    open(tmp_path) do io
        for line in eachline(io)
            if (m = match(r"^/registry/([^/]+)/([^/]+)$", line)) !== nothing
                uuid = UUID(m.captures[1])
                hash = String(m.captures[2])
                registry_urls[uuid] = "$server/registry/$uuid/$hash"
            end
        end
    end
    rm(tmp_path, force=true)
    return registry_urls
end

pkg_server_url_hash(url::String) = split(url, '/')[end]

# entry point for `registry add`
clone_or_cp_registries(regs::Vector{RegistrySpec}, depot::String=depots1()) =
    clone_or_cp_registries(Context(), regs, depot)
function clone_or_cp_registries(ctx::Context, regs::Vector{RegistrySpec}, depot::String=depots1())
    populate_known_registries_with_urls!(regs)
    registry_urls = nothing
    for reg in regs
        if reg.path !== nothing && reg.url !== nothing
            pkgerror("ambiguous registry specification; both url and path is set.")
        end
        # clone to tmpdir first
        mktempdir() do tmp
            url, registry_urls = pkg_server_registry_url(reg.uuid, registry_urls)
            if url !== nothing
                # download from Pkg server
                try
                    download_verify_unpack(url, nothing, tmp, ignore_existence = true)
                catch err
                    pkgerror("could not download $url")
                end
                tree_info_file = joinpath(tmp, ".tree_info.toml")
                ispath(tree_info_file) &&
                    error("tree info file $tree_info_file already exists")
                open(tree_info_file, write=true) do io
                    hash = pkg_server_url_hash(url)
                    println(io, "git-tree-sha1 = ", repr(hash))
                end
            elseif reg.path !== nothing # copy from local source
                printpkgstyle(ctx, :Copying, "registry from `$(Base.contractuser(reg.path))`")
                cp(reg.path, tmp; force=true)
            elseif reg.url !== nothing # clone from url
                LibGit2.with(GitTools.clone(ctx, reg.url, tmp; header = "registry from $(repr(reg.url))")) do repo
                end
            else
                pkgerror("no path or url specified for registry")
            end
            # verify that the clone looks like a registry
            if !isfile(joinpath(tmp, "Registry.toml"))
                pkgerror("no `Registry.toml` file in cloned registry.")
            end
            registry = read_registry(joinpath(tmp, "Registry.toml"); cache=false) # don't cache this tmp registry
            verify_registry(registry)
            # copy to `depot`
            # slug = Base.package_slug(UUID(registry["uuid"]))
            regpath = joinpath(depot, "registries", registry["name"]#=, slug=#)
            ispath(dirname(regpath)) || mkpath(dirname(regpath))
            if Pkg.isdir_nothrow(regpath)
                existing_registry = read_registry(joinpath(regpath, "Registry.toml"))
                if registry["uuid"] == existing_registry["uuid"]
                    println(ctx.io,
                            "registry `$(registry["name"])` already exist in `$(Base.contractuser(regpath))`.")
                else
                    throw(PkgError("registry `$(registry["name"])=\"$(registry["uuid"])\"` conflicts with " *
                        "existing registry `$(existing_registry["name"])=\"$(existing_registry["uuid"])\"`. " *
                        "To install it you can clone it manually into e.g. " *
                        "`$(Base.contractuser(joinpath(depot, "registries", registry["name"]*"-2")))`."))
                end
            else
                cp(tmp, regpath)
                printpkgstyle(ctx, :Added, "registry `$(registry["name"])` to `$(Base.contractuser(regpath))`")
            end
        end
    end
    return nothing
end

# path -> (mtime, TOML Dict)
const REGISTRY_CACHE = Dict{String, Tuple{Float64, Dict{String, Any}}}()

function read_registry(reg_file; cache=true)
    t = mtime(reg_file)
    if haskey(REGISTRY_CACHE, reg_file)
        prev_t, registry = REGISTRY_CACHE[reg_file]
        t == prev_t && return registry
    end
    registry = TOML.parsefile(reg_file)
    cache && (REGISTRY_CACHE[reg_file] = (t, registry))
    return registry
end

# verify that the registry looks like a registry
const REQUIRED_REGISTRY_ENTRIES = ("name", "uuid", "repo", "packages") # ??

function verify_registry(registry::Dict{String, Any})
    for key in REQUIRED_REGISTRY_ENTRIES
        haskey(registry, key) || pkgerror("no `$key` entry in `Registry.toml`.")
    end
end

# Search for the input registries among installed ones
function find_installed_registries(ctx::Context,
                                   needles::Vector{RegistrySpec},
                                   haystack::Vector{RegistrySpec}=collect_registries())
    output = RegistrySpec[]
    for needle in needles
        if needle.name === nothing && needle.uuid === nothing
            pkgerror("no name or uuid specified for registry.")
        end
        found = false
        for candidate in haystack
            if needle.uuid !== nothing
                if needle.uuid == candidate.uuid
                    push!(output, candidate)
                    found = true
                end
            elseif needle.name !== nothing
                if needle.name == candidate.name
                    named_regs = filter(r -> r.name == needle.name, haystack)
                    if !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                        pkgerror("multiple registries with name `$(needle.name)`, please specify with uuid.")
                    end
                    push!(output, candidate)
                    found = true
                end
            end
        end
        if !found
            println(ctx.io, "registry `$(needle.name === nothing ? needle.uuid :
                                         needle.uuid === nothing ? needle.name :
                                         "$(needle.name)=$(needle.uuid)")` not found.")
        end
    end
    return output
end

# entry point for `registry rm`
function remove_registries(ctx::Context, regs::Vector{RegistrySpec})
    for registry in find_installed_registries(ctx, regs)
        printpkgstyle(ctx, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        rm(registry.path; force=true, recursive=true)
    end
    return nothing
end

# entry point for `registry up`
function update_registries(ctx::Context, regs::Vector{RegistrySpec} = collect_registries(depots1());
                           force::Bool=false)
    Pkg.OFFLINE_MODE[] && return
    !force && UPDATED_REGISTRY_THIS_SESSION[] && return
    errors = Tuple{String, String}[]
    registry_urls = nothing
    for reg in unique(r -> r.uuid, find_installed_registries(ctx, regs))
        regpath = pathrepr(reg.path)
        if isfile(joinpath(reg.path, ".tree_info.toml"))
            printpkgstyle(ctx, :Updating, "registry at " * regpath)
            tree_info = TOML.parsefile(joinpath(reg.path, ".tree_info.toml"))
            old_hash = tree_info["git-tree-sha1"]
            url, registry_urls = pkg_server_registry_url(reg.uuid, registry_urls)
            if url !== nothing && (new_hash = pkg_server_url_hash(url)) != old_hash
                # TODO: update faster by using a diff, if available
                mktempdir() do tmp
                    try
                        download_verify_unpack(url, nothing, tmp, ignore_existence = true)
                    catch err
                        @warn "could not download $url"
                    end
                    tree_info_file = joinpath(tmp, ".tree_info.toml")
                    ispath(tree_info_file) &&
                        error("tree info file $tree_info_file already exists")
                    open(tree_info_file, write=true) do io
                        println(io, "git-tree-sha1 = ", repr(new_hash))
                    end
                    registry_file = joinpath(tmp, "Registry.toml")
                    registry = read_registry(registry_file; cache=false)
                    verify_registry(registry)
                    cp(tmp, reg.path, force=true)
                end
            end
        elseif isdir(joinpath(reg.path, ".git"))
            printpkgstyle(ctx, :Updating, "registry at " * regpath)
            # Using LibGit2.with here crashes julia when running the
            # tests for PkgDev wiht "Unreachable reached".
            # This seems to work around it.
            repo = nothing
            try
                repo = LibGit2.GitRepo(reg.path)
                if LibGit2.isdirty(repo)
                    push!(errors, (regpath, "registry dirty"))
                    @goto done
                end
                if !LibGit2.isattached(repo)
                    push!(errors, (regpath, "registry detached"))
                    @goto done
                end
                if !("origin" in LibGit2.remotes(repo))
                    push!(errors, (regpath, "origin not in the list of remotes"))
                    @goto done
                end
                branch = LibGit2.headname(repo)
                try
                    GitTools.fetch(ctx, repo; refspecs=["+refs/heads/$branch:refs/remotes/origin/$branch"])
                catch e
                    e isa PkgError || rethrow()
                    push!(errors, (reg.path, "failed to fetch from repo"))
                    @goto done
                end
                ff_succeeded = try
                    LibGit2.merge!(repo; branch="refs/remotes/origin/$branch", fastforward=true)
                catch e
                    e isa LibGit2.GitError && e.code == LibGit2.Error.ENOTFOUND || rethrow()
                    push!(errors, (reg.path, "branch origin/$branch not found"))
                    @goto done
                end

                if !ff_succeeded
                    try LibGit2.rebase!(repo, "origin/$branch")
                    catch e
                        e isa LibGit2.GitError || rethrow()
                        push!(errors, (reg.path, "registry failed to rebase on origin/$branch"))
                        @goto done
                    end
                end
                @label done
            finally
                if repo isa LibGit2.GitRepo
                    close(repo)
                end
            end
        end
    end
    if !isempty(errors)
        warn_str = "Some registries failed to update:"
        for (reg, err) in errors
            warn_str *= "\n    — $reg — $err"
        end
        @warn warn_str
    end
    UPDATED_REGISTRY_THIS_SESSION[] = true
    return
end

find_registered!(ctx::Context, uuids::Vector{UUID}) =
    find_registered!(ctx, String[], uuids)
# Lookup package names & uuids in a single pass through registries
function find_registered!(ctx::Context,
    names::Vector{String},
    uuids::Vector{UUID}=UUID[]
)::Nothing
    # only look if there's something new to see
    names = filter(name -> !haskey(ctx.env.uuids, name), names)
    uuids = filter(uuid -> !haskey(ctx.env.paths, uuid), uuids)
    isempty(names) && isempty(uuids) && return

    # since we're looking anyway, look for everything
    save(name::String) =
        name in names || haskey(ctx.env.uuids, name) || push!(names, name)
    save(uuid::UUID) =
        uuid in uuids || haskey(ctx.env.paths, uuid) || push!(uuids, uuid)

    # lookup any dependency in the project file
    for (name, uuid) in ctx.env.project.deps
        save(name); save(uuid)
    end
    # lookup anything mentioned in the manifest file
    for (uuid, entry) in ctx.env.manifest
        save(uuid)
        save(entry.name)
        for (uuid, name) in entry.deps
            save(uuid)
            save(name)
        end
    end
    # if there's still nothing to look for, return early
    isempty(names) && isempty(uuids) && return
    # initialize env entries for names and uuids
    for name in names; ctx.env.uuids[name] = UUID[]; end
    for uuid in uuids; ctx.env.paths[uuid] = String[]; end
    for uuid in uuids; ctx.env.names[uuid] = String[]; end

    # note: empty vectors will be left for names & uuids that aren't found
    clone_default_registries(ctx)
    for registry in collect_registries()
        reg_abspath = abspath(registry.path)
        data = read_registry(joinpath(registry.path, "Registry.toml"))
        for (_uuid, pkgdata) in data["packages"]
              uuid = UUID(_uuid)
              name = pkgdata["name"]
              path = joinpath(reg_abspath, pkgdata["path"])
              push!(get!(ctx.env.uuids, name, UUID[]), uuid)
              push!(get!(ctx.env.paths, uuid, String[]), path)
              push!(get!(ctx.env.names, uuid, String[]), name)
        end
    end
    for d in (ctx.env.uuids, ctx.env.paths, ctx.env.names)
        for (k, v) in d
            unique!(v)
        end
    end
end

# Get registered uuids associated with a package name
function registered_uuids(ctx::Context, name::String)::Vector{UUID}
    find_registered!(ctx, [name], UUID[])
    return unique(ctx.env.uuids[name])
end

# Get registered paths associated with a package uuid
function registered_paths(ctx::Context, uuid::UUID)::Vector{String}
    find_registered!(ctx, String[], [uuid])
    return ctx.env.paths[uuid]
end

#Get registered names associated with a package uuid
function registered_names(ctx::Context, uuid::UUID)::Vector{String}
    find_registered!(ctx, String[], [uuid])
    return ctx.env.names[uuid]
end

# Determine a single UUID for a given name, prompting if needed
function registered_uuid(ctx::Context, name::String)::Union{Nothing,UUID}
    uuids = registered_uuids(ctx, name)
    length(uuids) == 0 && return nothing
    length(uuids) == 1 && return uuids[1]
    choices::Vector{String} = []
    choices_cache::Vector{Tuple{UUID,String}} = []
    for uuid in uuids
        values = registered_info(ctx, uuid, "repo")
        for value in values
            depot = "(unknown)"
            for d in depots()
                r = joinpath(d, "registries")
                startswith(value[1], r) || continue
                depot = split(relpath(value[1], r), Base.Filesystem.path_separator_re)[1]
                break
            end
            push!(choices, "Registry: $depot - Path: $(value[2])")
            push!(choices_cache, (uuid, value[1]))
        end
    end
    length(choices_cache) == 1 && return choices_cache[1][1]
    if isinteractive()
        # prompt for which UUID was intended:
        menu = RadioMenu(choices)
        choice = request("There are multiple registered `$name` packages, choose one:", menu)
        choice == -1 && return nothing
        ctx.env.paths[choices_cache[choice][1]] = [choices_cache[choice][2]]
        return choices_cache[choice][1]
    else
        pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
    end
end

# Determine current name for a given package UUID
function registered_name(ctx::Context, uuid::UUID)::Union{Nothing,String}
    names = registered_names(ctx, uuid)
    length(names) == 0 && return nothing
    length(names) == 1 && return names[1]
    values = registered_info(ctx, uuid, "name")
    name = nothing
    for value in values
        name  === nothing && (name = value[2])
        name != value[2] && pkgerror("package `$uuid` has multiple registered name values: $name, $(value[2])")
    end
    return name
end

# Return most current package info for a registered UUID
function registered_info(ctx::Context, uuid::UUID, key::String)
    haskey(ctx.env.paths, uuid) || find_registered!(ctx, [uuid])
    paths = ctx.env.paths[uuid]
    isempty(paths) && pkgerror("`$uuid` is not registered")
    values = []
    for path in paths
        info = parse_toml(path, "Package.toml")
        value = get(info, key, nothing)
        push!(values, (path, value))
    end
    return values
end

# Find package by UUID in the manifest file
manifest_info(ctx::Context, uuid::Nothing) = nothing
function manifest_info(ctx::Context, uuid::UUID)::Union{PackageEntry,Nothing}
    #any(uuids -> uuid in uuids, values(env.uuids)) || find_registered!(env, [uuid])
    return get(ctx.env.manifest, uuid, nothing)
end

function printpkgstyle(ctx::Context, cmd::Symbol, text::String, ignore_indent::Bool=false)
    printpkgstyle(ctx.io, cmd, text, ignore_indent)
end
function printpkgstyle(io::IO, cmd::Symbol, text::String, ignore_indent::Bool=false)
    indent = textwidth(string(:Downloading))
    ignore_indent && (indent = 0)
    printstyled(io, lpad(string(cmd), indent), color=:green, bold=true)
    println(io, " ", text)
end


function pathrepr(path::String)
    # print stdlib paths as @stdlib/Name
    if startswith(path, stdlib_dir())
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

function write_env(env::EnvCache; update_undo=true)
    write_project(env)
    write_manifest(env)
    update_undo && Pkg.API.add_snapshot_to_undo(env)
end

###
### PackageInfo
###

Base.@kwdef struct PackageInfo
    name::String
    version::Union{Nothing,VersionNumber}
    tree_hash::Union{Nothing,String}
    is_direct_dep::Bool
    is_pinned::Bool
    is_tracking_path::Bool
    is_tracking_repo::Bool
    is_tracking_registry::Bool
    git_revision::Union{Nothing,String}
    git_source::Union{Nothing,String}
    source::String
    dependencies::Dict{String,UUID}
end

function Base.:(==)(a::PackageInfo, b::PackageInfo)
    return a.name == b.name && a.version == b.version && a.tree_hash == b.tree_hash &&
        a.is_direct_dep == b.is_direct_dep &&
        a.is_pinned == b.is_pinned && a.is_tracking_path == b.is_tracking_path &&
        a.is_tracking_repo == a.is_tracking_repo &&
        a.is_tracking_registry == b.is_tracking_registry &&
        a.git_revision == b.git_revision && a.git_source == b.git_source &&
        a.source == b.source && a.dependencies == b.dependencies
end

###
### ProjectInfo
###

Base.@kwdef struct ProjectInfo
    name::Union{Nothing,String}
    uuid::Union{Nothing,UUID}
    version::Union{Nothing,VersionNumber}
    ispackage::Bool
    dependencies::Dict{String,UUID}
    path::String
end

end # module
