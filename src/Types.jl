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
import ..Pkg, ..UPDATED_REGISTRY_THIS_SESSION
import Pkg: GitTools, depots, depots1, logdir

import Base: SHA1
using SHA

export UUID, pkgID, SHA1, VersionRange, VersionSpec, empty_versionspec,
    Requires, Fixed, merge_requires!, satisfies, ResolverError,
    PackageSpec, EnvCache, Context, Context!, get_deps,
    PkgError, pkgerror, has_name, has_uuid, write_env, parse_toml, find_registered!,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved,
    manifest_info, registered_uuids, registered_paths, registered_uuid, registered_name,
    read_project, read_package, read_manifest, pathrepr, registries,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PackageSpecialAction, PKGSPEC_NOTHING, PKGSPEC_PINNED, PKGSPEC_FREED, PKGSPEC_DEVELOPED, PKGSPEC_TESTED, PKGSPEC_REPO_ADDED,
    printpkgstyle,
    projectfile_path,
    RegistrySpec

include("versions.jl")

## ordering of UUIDs ##

Base.isless(a::UUID, b::UUID) = a.value < b.value

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

## user-friendly representation of package IDs ##
function pkgID(p::UUID, uuid_to_name::Dict{UUID,String})
    name = get(uuid_to_name, p, "(unknown)")
    uuid_short = string(p)[1:8]
    return "$name [$uuid_short]"
end

####################
# Requires / Fixed #
####################
const Requires = Dict{UUID,VersionSpec}

function merge_requires!(A::Requires, B::Requires)
    for (pkg, vers) in B
        A[pkg] = haskey(A, pkg) ? intersect(A[pkg], vers) : vers
    end
    return A
end

satisfies(pkg::UUID, ver::VersionNumber, reqs::Requires) =
    !haskey(reqs, pkg) || in(ver, reqs[pkg])

struct Fixed
    version::VersionNumber
    requires::Requires
end
Fixed(v::VersionNumber) = Fixed(v, Requires())

Base.:(==)(a::Fixed, b::Fixed) = a.version == b.version && a.requires == b.requires
Base.hash(f::Fixed, h::UInt) = hash((f.version, f.requires), h + (0x68628b809fd417ca % UInt))

Base.show(io::IO, f::Fixed) = isempty(f.requires) ?
    print(io, "Fixed(", repr(f.version), ")") :
    print(io, "Fixed(", repr(f.version), ",", f.requires, ")")


struct ResolverError <: Exception
    msg::AbstractString
    ex::Union{Exception,Nothing}
end
ResolverError(msg::AbstractString) = ResolverError(msg, nothing)

function Base.showerror(io::IO, pkgerr::ResolverError)
    print(io, pkgerr.msg)
    if pkgerr.ex !== nothing
        pkgex = pkgerr.ex
        if isa(pkgex, CompositeException)
            for cex in pkgex
                print(io, "\n=> ")
                showerror(io, cex)
            end
        else
            print(io, "\n")
            showerror(io, pkgex)
        end
    end
end

#################
# Pkg Error #
#################
struct PkgError <: Exception
    msg::String
end
pkgerror(msg::String...) = throw(PkgError(join(msg)))
Base.show(io::IO, err::PkgError) = print(io, err.msg)


###############
# PackageSpec #
###############
@enum(UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR)
@enum(PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST, PKGMODE_COMBINED)
@enum(PackageSpecialAction, PKGSPEC_NOTHING, PKGSPEC_PINNED, PKGSPEC_FREED,
                            PKGSPEC_DEVELOPED, PKGSPEC_TESTED, PKGSPEC_REPO_ADDED)

const VersionTypes = Union{VersionNumber,VersionSpec,UpgradeLevel}

# The url field can also be a local path, rename?
Base.@kwdef mutable struct GitRepo
    url::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing
    tree_sha::Union{Nothing,SHA1} = nothing # git tree sha1
end

Base.:(==)(r1::GitRepo, r2::GitRepo) =
    r1.url == r2.url && r1.rev == r2.rev && r1.tree_sha == r2.tree_sha

Base.@kwdef mutable struct PackageSpec
    name::Union{Nothing,String} = nothing
    uuid::Union{Nothing,UUID} = nothing
    version::VersionTypes = VersionSpec()
    mode::PackageMode = PKGMODE_PROJECT
    path::Union{Nothing,String} = nothing
    special_action::PackageSpecialAction = PKGSPEC_NOTHING # If the package is currently being pinned, freed etc
    repo::Union{Nothing,GitRepo} = nothing
end
PackageSpec(name::AbstractString) = PackageSpec(;name=name)
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(;name=name, uuid=uuid)
PackageSpec(name::AbstractString, version::VersionTypes) = PackageSpec(;name=name, version=version)
PackageSpec(n::AbstractString, u::UUID, v::VersionTypes) = PackageSpec(;name=n, uuid=u, version=v)

has_name(pkg::PackageSpec) = pkg.name !== nothing
has_uuid(pkg::PackageSpec) = pkg.uuid !== nothing

function Base.show(io::IO, pkg::PackageSpec)
    vstr = repr(pkg.version)
    f = ["name" => pkg.name, "uuid" => has_uuid(pkg) ? pkg.uuid : "", "v" => (vstr == "VersionSpec(\"*\")" ? "" : vstr)]
    if pkg.repo !== nothing
        if pkg.repo.url !== nothing
            push!(f, "url/path" => string("\"", pkg.repo.url, "\""))
        end
        if pkg.repo.rev !== nothing
            push!(f, "rev" => pkg.repo.rev)
        end
    end
    print(io, "PackageSpec(")
    first = true
    for (field, value) in f
        value == "" && continue
        first || print(io, ", ")
        print(io, field, "=", value)
        first = false
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

let trynames(names) = begin
    return root_path::AbstractString -> begin
        for x in names
            maybe_file = joinpath(root_path, x)
            if isfile(maybe_file)
                return maybe_file
            end
        end
    end
end # trynames
    global projectfile_path = trynames(Base.project_names)
    global manifestfile_path = trynames(Base.manifest_names)
end # let

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

Base.@kwdef mutable struct PackageEntry
    name::Union{String,Nothing} = nothing
    version::Union{String,Nothing} = nothing
    path::Union{String,Nothing} = nothing
    pinned::Bool = false
    repo::GitRepo = GitRepo()
    deps::Dict{String,UUID} = Dict{String,UUID}()
    other::Union{Dict,Nothing} = nothing
end
const Manifest = Dict{UUID,PackageEntry}

mutable struct EnvCache
    # environment info:
    env::Union{Nothing,String}
    git::Union{Nothing,String}

    # paths for files:
    project_file::String
    manifest_file::String

    # name / uuid of the project
    pkg::Union{PackageSpec, Nothing}

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
    # use default name if still not determined
    manifest_file = something(manifest_file, joinpath(dir, "Manifest.toml"))
    write_env_usage(manifest_file)
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

collides_with_project(env::EnvCache, pkg::PackageSpec) =
    is_project_name(env, pkg.name) || is_project_uuid(env, pkg.uuid)
is_project(env::EnvCache, pkg::PackageSpec) = is_project_uuid(env, pkg.uuid)
is_project_name(env::EnvCache, name::String) =
    env.pkg !== nothing && env.pkg.name == name
is_project_uuid(env::EnvCache, uuid::UUID) =
    env.pkg !== nothing && env.pkg.uuid == uuid



###########
# Context #
###########
stdlib_dir() = normpath(joinpath(Sys.BINDIR, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"))
stdlib_path(stdlib::String) = joinpath(stdlib_dir(), stdlib)
const STDLIB = Ref{Dict{UUID,String}}()
function load_stdlib()
    stdlib = Dict{UUID,String}()
    for name in readdir(stdlib_dir())
        projfile = projectfile_path(stdlib_path(name))
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

# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    preview::Bool = false
    use_libgit2_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    # NOTE: The JULIA_PKG_CONCURRENCY environment variable is likely to be removed in
    # the future. It currently stands as an unofficial workaround for issue #795.
    num_concurrent_downloads::Int = haskey(ENV, "JULIA_PKG_CONCURRENCY") ? parse(Int, ENV["JULIA_PKG_CONCURRENCY"]) : 8
    graph_verbose::Bool = false
    stdlibs::Dict{UUID,String} = stdlib()
    # Remove next field when support for Pkg2 CI scripts is removed
    currently_running_target::Bool = false
    old_pkg2_clone_name::String = ""
end

Context!(kw_context::Vector{Pair{Symbol,Any}})::Context =
    Context!(Context(); kw_context...)
function Context!(ctx::Context; kwargs...)
    for (k, v) in kwargs
        setfield!(ctx, k, v)
    end
    return ctx
end

# target === nothing : main dependencies
# target === "*"     : main + all extras
# target === "name"  : named target deps
function deps_names(project::Project, target::Union{Nothing,String}=nothing)::Vector{String}
    deps = collect(keys(project.deps))
    if target === nothing
        x = String[]
    elseif target == "*"
        x = collect(keys(project.extras))
    else
        x = haskey(project.targets, target) ?
            collect(values(project.targets[target])) :
            String[]
    end
    return sort!(union!(deps, x))
end

function get_deps(project::Project, target::Union{Nothing,String}=nothing)
    names = deps_names(project, target)
    deps = filter(((dep, _),) -> dep in names, project.deps)
    extras = project.extras
    for name in names
        haskey(deps, name) && continue
        haskey(extras, name) ||
            pkgerror("target `$target` has unlisted dependency `$name`")
        deps[name] = extras[name]
    end
    return deps
end
get_deps(env::EnvCache, target::Union{Nothing,String}=nothing) =
    get_deps(env.project, target)
get_deps(ctx::Context, target::Union{Nothing,String}=nothing) =
    get_deps(ctx.env, target)

function project_compatibility(ctx::Context, name::String)
    compat = get(ctx.env.project.compat, name, nothing)
    return compat === nothing ? VersionSpec() : VersionSpec(semver_spec(compat))
end

function write_env_usage(manifest_file::AbstractString)
    !ispath(logdir()) && mkpath(logdir())
    usage_file = joinpath(logdir(), "manifest_usage.toml")
    touch(usage_file)
    !isfile(manifest_file) && return
    # Do not rewrite as do syntax (no longer precompilable)
    io = open(usage_file, "a")
    print(io, """
    [[$(repr(manifest_file))]]
    time = $(now())Z
    """)
    close(io)
end

function Project(raw::Dict)
    project = Project()
    project.other = raw
    # Name
    project.name = get(raw, "name", nothing)
    # UUID
    uuid = get(raw, "uuid", nothing)
    uuid !== nothing && (project.uuid = UUID(uuid))
    # Version
    version = get(raw, "version", nothing)
    version !== nothing && (project.version = VersionNumber(version))
    # Manifest
    project.manifest = get(raw, "manifest", nothing)
    # DEPS
    deps = get(raw, "deps", nothing)
    if deps !== nothing
        @assert deps isa Dict
        for (name, uuid) in deps
            project.deps[name] = UUID(uuid)
        end
    end
    # EXTRAS
    extras = get(raw, "extras", nothing)
    if extras !== nothing
        for (name, uuid) in extras
            project.extras[name] = UUID(uuid)
        end
    end
    # COMPAT
    compat = get(raw, "compat", nothing)
    if compat !== nothing
        for (name, version) in compat
            project.compat[name] = version # TODO semver_spec(version)
        end
    end
    # TARGETS
    targets = get(raw, "targets", nothing)
    if targets !== nothing
        for (target, deps) in targets
            project.targets[target] = deps
            # TODO make sure names in `project.targets[target]` make sense
        end
    end
    # TODO make sure all targets are listed in extras
    # TODO any other validation
    # validate(project)
    return project
end

function read_project(io::IO; path=nothing)
    raw = nothing
    try
        raw = TOML.parse(io)
    catch err
        if err isa TOML.ParserError
            pkgerror("Could not parse project $(something(path,"")): $(err.msg)")
        elseif all(x -> x isa TOML.ParserError, err)
            pkgerror("Could not parse project $(something(path,"")): $err")
        else
            rethrow()
        end
    end
    return Project(raw)
end

read_project(path::String) =
    isfile(path) ? open(io->read_project(io;path=path), path) : Project()

function read_package(f::String)
    _throw_package_err(x) = pkgerror("expected a `$x` entry in project file at $(abspath(f))")

    project = read_project(f)
    project.name === nothing && _throw_package_err("name")
    project.uuid === nothing && _throw_package_err("uuid")
    name = project.name
    if !isfile(joinpath(dirname(f), "src", "$name.jl"))
        pkgerror("expected the file `src/$name.jl` to exist for package $name at $(dirname(f))")
    end
    return project
end

function Manifest(raw::Dict)::Manifest
    manifest = Dict{UUID,PackageEntry}()
    # TODO is it easier to check all constraints of the TOML before?
    for (name, infos) in raw, info in infos
        deps = get(info, "deps", nothing)
        if deps !== nothing
            if deps isa AbstractVector
                for dep in info["deps"]
                    length(raw[dep]) == 1 ||
                        error("ambiguious dependency for $name: $dep")
                end
            else
                deps isa Dict ||
                    pkgerror("Error loading manifest file: Malformed deps entry for `$(name)`")
            end
        end

        uuid = UUID(info["uuid"]) # TODO check `haskey` first
        entry = PackageEntry()
        entry.name     = name
        entry.version  = get(info, "version",  nothing)
        entry.path     = get(info, "path",     nothing)
        entry.pinned   = get(info, "pinned", false)
        entry.repo.url = get(info, "repo-url", nothing)
        entry.repo.rev = get(info, "repo-rev", nothing)
        sha = get(info, "git-tree-sha1", nothing)
        sha !== nothing && (entry.repo.tree_sha = SHA1(sha))
        deps = get(info, "deps", nothing)
        if deps !== nothing
            if deps isa AbstractVector
                for dep in deps
                    dep_uuid = UUID(raw[dep][1]["uuid"]) # check that it exists first
                    entry.deps[dep] = dep_uuid
                end
            else
                for (name, uuid) in deps
                    dep_uuid = UUID(uuid)
                    entry.deps[name]  = dep_uuid
                end
            end
        end
        entry.other = info
        manifest[uuid] = entry # TODO make sure slot is not already taken
    end
    return manifest
end

function read_manifest(io::IO; path=nothing)
    raw = nothing
    try
        raw = TOML.parse(io)
    catch err
        if err isa TOML.ParserError
            pkgerror("Could not parse manifest $(something(path,"")): $(err.msg)")
        elseif all(x -> x isa TOML.ParserError, err)
            pkgerror("Could not parse manifest $(something(path,"")): $err")
        else
            rethrow()
        end
    end
    return Manifest(raw)
end

read_manifest(path::String)::Manifest =
    isfile(path) ? open(io->read_manifest(io;path=path), path) : Dict{UUID,PackageEntry}()

const refspecs = ["+refs/*:refs/remotes/cache/*"]
const reg_pkg = r"(?:^|[\/\\])(\w+?)(?:\.jl)?(?:\.git)?(?:[\/\\])?$"

# Windows sometimes throw on `isdir`...
function isdir_windows_workaround(path::String)
    try isdir(path)
    catch e
        false
    end
end

# try to call realpath on as much as possible
function safe_realpath(path)
    ispath(path) && return realpath(path)
    a, b = splitdir(path)
    return joinpath(safe_realpath(a), b)
end
function relative_project_path(ctx::Context, path::String)
    # compute path relative the project
    # realpath needed to expand symlinks before taking the relative path
    return relpath(safe_realpath(abspath(path)),
                   safe_realpath(dirname(ctx.env.project_file)))
end

casesensitive_isdir(dir::String) =
    isdir_windows_workaround(dir) && basename(dir) in readdir(joinpath(dir, ".."))

function git_checkout_latest!(repo_path::AbstractString)
    LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
        rev = LibGit2.isattached(repo) ?
            LibGit2.branch(repo) :
            string(LibGit2.GitHash(LibGit2.head(repo)))
        gitobject, isbranch = nothing, nothing
        Base.shred!(LibGit2.CachedCredentials()) do creds
            gitobject, isbranch = get_object_branch(repo, rev, creds)
        end
        try
            LibGit2.transact(repo) do r
                if isbranch
                    LibGit2.branch!(r, rev, track=LibGit2.Consts.REMOTE_ORIGIN)
                else
                    LibGit2.checkout!(r, string(LibGit2.GitHash(gitobject)))
                end
            end
        finally
            close(gitobject)
        end
    end
end

# Developing a local package, just point `pkg.path` to it
# - Absolute paths should stay absolute
# - Relative paths are given relative pwd() so we
#   translate that to be relative the project instead.
function explicit_dev_path(ctx::Context, pkg::PackageSpec)
    path = pkg.repo.url
    pkg.path = isabspath(path) ? path : relative_project_path(ctx, path)
    parse_package!(ctx, pkg, path)
end

function canonical_dev_path!(ctx::Context, pkg::PackageSpec, shared::Bool; default=nothing)
    dev_dir = shared ? Pkg.devdir() : joinpath(dirname(ctx.env.project_file), "dev")
    dev_path = joinpath(dev_dir, pkg.name)

    if isdir(dev_path)
        if !isfile(joinpath(dev_path, "src", pkg.name * ".jl"))
            pkgerror("Path `$(dev_path)` exists but it does not contain `src/$(pkg.name).jl")
        end
        @info "Path `$(dev_path)` exists and looks like the correct package, using existing path"
        default !== nothing && rm(default; force=true, recursive=true)
        pkg.path = shared ? dev_path : relative_project_path(ctx, dev_path)
        parse_package!(ctx, pkg, dev_path)
    elseif default !== nothing
        mkpath(dev_dir)
        mv(default, dev_path)
        # Save the path as relative if it is a --local dev, otherwise put in the absolute path.
        pkg.path = shared ? dev_path : relative_project_path(ctx, dev_path)
    end
end

function fresh_clone(pkg::PackageSpec)
    clone_path = joinpath(depots1(), "clones")
    mkpath(clone_path)
    repo_path = joinpath(clone_path, string(hash(pkg.repo.url), "_full"))
    # make sure you have a fresh clone
    repo = nothing
    try
        repo = GitTools.ensure_clone(repo_path, pkg.repo.url)
        Base.shred!(LibGit2.CachedCredentials()) do creds
            GitTools.fetch(repo, pkg.repo.url; refspecs=refspecs, credentials=creds)
        end
    finally
        repo isa LibGit2.GitRepo && LibGit2.close(repo)
    end
    # Copy the repo to a temporary place and check out the rev
    temp_repo = mktempdir()
    cp(repo_path, temp_repo; force=true)
    git_checkout_latest!(temp_repo)
    return temp_repo
end

function remote_dev_path!(ctx::Context, pkg::PackageSpec, shared::Bool)
    # Only update the registry in case of developing a non-local package
    UPDATED_REGISTRY_THIS_SESSION[] || update_registries(ctx)
    # We save the repo in case another environement wants to develop from the same repo,
    # this avoids having to reclone it from scratch.
    pkg.repo.url === nothing && set_repo_for_pkg!(ctx.env, pkg)
    temp_clone = fresh_clone(pkg)
    # parse repo to determine dev path
    parse_package!(ctx, pkg, temp_clone)
    canonical_dev_path!(ctx, pkg, shared; default=temp_clone)
    return pkg.uuid
end

function handle_repos_develop!(ctx::Context, pkgs::AbstractVector{PackageSpec}, shared::Bool)
    for pkg in pkgs
        pkg.repo === nothing && (pkg.repo = Types.GitRepo())
        pkg.repo.rev === nothing || pkgerror("git revision cannot be given to `develop`")
    end

    new_uuids = UUID[]
    for pkg in pkgs
        pkg.special_action = PKGSPEC_DEVELOPED
        if pkg.repo.url !== nothing && isdir_windows_workaround(pkg.repo.url)
            explicit_dev_path(ctx, pkg)
        elseif pkg.name !== nothing
            canonical_dev_path!(ctx, pkg, shared)
        end
        if pkg.path === nothing
            new_uuid = remote_dev_path!(ctx, pkg, shared)
            push!(new_uuids, new_uuid)
        end
        @assert pkg.path !== nothing
        @assert has_uuid(pkg)
    end
    return new_uuids
end

function handle_repos_add!(ctx::Context, pkgs::AbstractVector{PackageSpec};
                           upgrade_or_add::Bool=true, credentials=nothing)
    # Always update the registry when adding
    UPDATED_REGISTRY_THIS_SESSION[] || update_registries(ctx)
    creds = credentials !== nothing ? credentials : LibGit2.CachedCredentials()
    try
        env = ctx.env
        new_uuids = UUID[]
        for pkg in pkgs
            pkg.repo == nothing && continue
            pkg.special_action = PKGSPEC_REPO_ADDED
            pkg.repo.url === nothing && set_repo_for_pkg!(env, pkg)
            clones_dir = joinpath(depots1(), "clones")
            mkpath(clones_dir)
            repo_path = joinpath(clones_dir, string(hash(pkg.repo.url)))
            repo = nothing
            do_nothing_more = false
            project_path = nothing
            folder_already_downloaded = false
            try
                repo = GitTools.ensure_clone(repo_path, pkg.repo.url; isbare=true, credentials=creds)
                entry = manifest_info(env, pkg.uuid)
                pinned = (entry !== nothing && entry.pinned)
                upgrading = upgrade_or_add && !pinned
                if upgrading
                    GitTools.fetch(repo; refspecs=refspecs, credentials=creds)
                    rev = pkg.repo.rev
                    # see if we can get rev as a branch
                    if rev === nothing
                        rev = LibGit2.isattached(repo) ?
                            LibGit2.branch(repo) :
                            string(LibGit2.GitHash(LibGit2.head(repo)))
                    end
                else
                    # Not upgrading so the rev should be the current git-tree-sha
                    rev = entry.repo.tree_sha
                    pkg.version = VersionNumber(entry.version)
                end

                gitobject, isbranch = get_object_branch(repo, rev, creds)
                # If the user gave a shortened commit SHA, might as well update it to the full one
                try
                    if upgrading
                        pkg.repo.rev = isbranch ? rev : string(LibGit2.GitHash(gitobject))
                    end
                    LibGit2.with(LibGit2.peel(LibGit2.GitTree, gitobject)) do git_tree
                        @assert git_tree isa LibGit2.GitTree
                        pkg.repo.tree_sha = SHA1(string(LibGit2.GitHash(git_tree)))
                            version_path = nothing
                            folder_already_downloaded = false
                        if has_uuid(pkg) && has_name(pkg)
                            version_path = Pkg.Operations.find_installed(pkg.name, pkg.uuid, pkg.repo.tree_sha)
                            isdir(version_path) && (folder_already_downloaded = true)
                            entry = manifest_info(env, pkg.uuid)
                            if entry !== nothing &&
                                entry.repo.tree_sha == pkg.repo.tree_sha && folder_already_downloaded
                                # Same tree sha and this version already downloaded, nothing left to do
                                do_nothing_more = true
                            end
                        end
                        if folder_already_downloaded
                            project_path = version_path
                        else
                            project_path = mktempdir()
                            _project_path = project_path # https://github.com/JuliaLang/julia/issues/30048
                            GC.@preserve _project_path begin
                                opts = LibGit2.CheckoutOptions(
                                    checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
                                    target_directory = Base.unsafe_convert(Cstring, _project_path),
                                )
                                LibGit2.checkout_tree(repo, git_tree, options=opts)
                            end
                        end
                    end
                finally
                    close(gitobject)
                end
            finally
                repo isa LibGit2.GitRepo && close(repo)
            end
            do_nothing_more && continue
            parse_package!(ctx, pkg, project_path)
            if !folder_already_downloaded
                version_path = Pkg.Operations.find_installed(pkg.name, pkg.uuid, pkg.repo.tree_sha)
                mkpath(version_path)
                mv(project_path, version_path; force=true)
                push!(new_uuids, pkg.uuid)
                Base.rm(project_path; force = true, recursive = true)
            end
            @assert has_uuid(pkg)
        end
        return new_uuids
    finally
        creds !== credentials && Base.shred!(creds)
    end
end

function parse_package!(ctx, pkg, project_path)
    env = ctx.env
    project_file = projectfile_path(project_path)
    if project_file !== nothing
        project_data = read_package(project_file)
        pkg.uuid = project_data.uuid
        pkg.name = project_data.name
    else
        if !isempty(ctx.old_pkg2_clone_name) # remove when legacy CI script support is removed
            pkg.name = ctx.old_pkg2_clone_name
        else
            # This is an old style package, if not set, get the name from src/PackageName
            if !has_name(pkg)
                if isdir_windows_workaround(pkg.repo.url)
                    m = match(reg_pkg, abspath(pkg.repo.url))
                else
                    m = match(reg_pkg, pkg.repo.url)
                end
                m === nothing && pkgerror("cannot determine package name from URL or path: $(pkg.repo.url), provide a name argument to `PackageSpec`")
                pkg.name = m.captures[1]
            end
        end
        reg_uuids = registered_uuids(env, pkg.name)
        is_registered = !isempty(reg_uuids)
        if !is_registered
            # This is an unregistered old style package, give it a UUID and a version
            if !has_uuid(pkg)
                uuid_unreg_pkg = UUID(0xa9a2672e746f11e833ef119c5b888869)
                pkg.uuid = uuid5(uuid_unreg_pkg, pkg.name)
                @info "Assigning UUID $(pkg.uuid) to $(pkg.name)"
            end
        else
            @assert length(reg_uuids) == 1
            pkg.uuid = reg_uuids[1]
        end
    end
end

function set_repo_for_pkg!(env, pkg)
    if !has_uuid(pkg)
        registry_resolve!(env, [pkg])
        ensure_resolved(env, [pkg]; registry=true)
    end
    # TODO: look into [1]
    _, pkg.repo.url = Types.registered_info(env, pkg.uuid, "repo")[1]
end

get_object_branch(repo, rev::SHA1, creds) =
    get_object_branch(repo, string(rev), creds)

function get_object_branch(repo, rev, creds)
    gitobject = nothing
    isbranch = false
    try
        gitobject = LibGit2.GitObject(repo, "remotes/cache/heads/" * rev)
        isbranch = true
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    if gitobject == nothing
        try
            gitobject = LibGit2.GitObject(repo, rev)
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            GitTools.fetch(repo; refspecs=refspecs, credentials=creds)
            try
                gitobject = LibGit2.GitObject(repo, rev)
            catch err
                err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
                pkgerror("git object $(rev) could not be found")
            end
        end
    end
    return gitobject, isbranch
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
    # TODO: move this to `Project`
    length(uuids) < length(names) && # TODO: handle this somehow?
        pkgerror("duplicate UUID found in project file's [deps] section")
    for pkg in pkgs
        pkg.mode == PKGMODE_PROJECT || continue
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            pkg.uuid = uuids[pkg.name]
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
    return pkgs
end

# Disambiguate name/uuid package specifications using manifest info.
function manifest_resolve!(env::EnvCache, pkgs::AbstractVector{PackageSpec})
    uuids = Dict{String,Vector{UUID}}()
    names = Dict{UUID,String}()
    for (uuid, entry) in env.manifest
        push!(get!(uuids, entry.name, UUID[]), uuid)
        names[uuid] = entry.name # can be duplicate but doesn't matter
    end
    for pkg in pkgs
        pkg.mode == PKGMODE_MANIFEST || continue
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            length(uuids[pkg.name]) == 1 && (pkg.uuid = uuids[pkg.name][1])
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
    return pkgs
end

# Disambiguate name/uuid package specifications using registry info.
function registry_resolve!(env::EnvCache, pkgs::AbstractVector{PackageSpec})
    # if there are no half-specified packages, return early
    any(pkg -> has_name(pkg) ⊻ has_uuid(pkg), pkgs) || return
    # collect all names and uuids since we're looking anyway
    names = String[pkg.name for pkg in pkgs if has_name(pkg)]
    uuids = UUID[pkg.uuid for pkg in pkgs if has_uuid(pkg)]
    find_registered!(env, names, uuids)
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            pkg.uuid = registered_uuid(env, pkg.name)
        end
        if has_uuid(pkg) && !has_name(pkg)
            pkg.name = registered_name(env, pkg.uuid)
        end
    end
    return pkgs
end

function stdlib_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            for (uuid, name) in ctx.stdlibs
                name == pkg.name && (pkg.uuid = uuid)
            end
        end
        if !has_name(pkg) && has_uuid(pkg)
            name = get(ctx.stdlibs, pkg.uuid, nothing)
            nothing !== name && (pkg.name = name)
        end
    end
end

# Ensure that all packages are fully resolved
function ensure_resolved(env::EnvCache,
    pkgs::AbstractVector{PackageSpec};
    registry::Bool=false,)::Nothing
    unresolved = Dict{String,Vector{UUID}}()
    for pkg in pkgs
        has_uuid(pkg) && continue
        uuids = UUID[]
        for (uuid, entry) in env.manifest
            entry.name == pkg.name || continue
            uuid in uuids || push!(uuids, uuid)
        end
        sort!(uuids, by=uuid -> uuid.value)
        unresolved[pkg.name] = uuids
    end
    isempty(unresolved) && return
    msg = sprint() do io
        println(io, "The following package names could not be resolved:")
        for (name, uuids) in sort!(collect(unresolved), by=lowercase ∘ first)
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
        print(io, "Please specify by known `name=uuid`.")
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

function clone_default_registries()
    if isempty(collect_registries()) # only clone if there are no installed registries
        printpkgstyle(stdout, :Cloning, "default registries into $(pathrepr(depots1()))")
        clone_or_cp_registries(DEFAULT_REGISTRIES)
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
            end
        end
    end
end

# entry point for `registry add`
clone_or_cp_registries(regs::Vector{RegistrySpec}, depot::String=depots1()) =
    clone_or_cp_registries(Context(), regs, depot)
function clone_or_cp_registries(ctx::Context, regs::Vector{RegistrySpec}, depot::String=depots1())
    ctx.preview && (@info("Skipping adding registries in preview mode"); return nothing)
    populate_known_registries_with_urls!(regs)
    for reg in regs
        if reg.path !== nothing && reg.url !== nothing
            pkgerror("ambiguous registry specification; both url and path is set.")
        end
        # clone to tmpdir first
        tmp = mktempdir()
        if reg.path !== nothing # copy from local source
            printpkgstyle(stdout, :Copying, "registry from `$(Base.contractuser(reg.path))`")
            cp(reg.path, tmp; force=true)
        elseif reg.url !== nothing # clone from url
            Base.shred!(LibGit2.CachedCredentials()) do creds
                LibGit2.with(GitTools.clone(reg.url, tmp; header = "registry from $(repr(reg.url))",
                    credentials = creds)) do repo
                end
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
        if isdir_windows_workaround(regpath)
            existing_registry = read_registry(joinpath(regpath, "Registry.toml"))
            if registry["uuid"] == existing_registry["uuid"]
                @info("registry `$(registry["name"])` already exist in `$(Base.contractuser(regpath))`.")
            else
                throw(PkgError("registry `$(registry["name"])=\"$(registry["uuid"])\"` conflicts with " *
                    "existing registry `$(existing_registry["name"])=\"$(existing_registry["uuid"])\"`. " *
                    "To install it you can clone it manually into e.g. " *
                    "`$(Base.contractuser(joinpath(depot, "registries", registry["name"]*"-2")))`."))
            end
        else
            cp(tmp, regpath)
            printpkgstyle(stdout, :Added, "registry `$(registry["name"])` to `$(Base.contractuser(regpath))`")
        end
        # Clean up
        Base.rm(tmp; recursive=true, force=true)
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
function find_installed_registries(needles::Vector{RegistrySpec},
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
            @info("registry `$(needle.name === nothing ? needle.uuid :
                               needle.uuid === nothing ? needle.name :
                               "$(needle.name)=$(needle.uuid)")` not found.")
        end
    end
    return output
end

# entry point for `registry rm`
function remove_registries(ctx::Context, regs::Vector{RegistrySpec})
    ctx.preview && (@info("skipping removing registries in preview mode"); return nothing)
    for registry in find_installed_registries(regs)
        printpkgstyle(stdout, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        rm(registry.path; force=true, recursive=true)
    end
    return nothing
end

# entry point for `registry up`
function update_registries(ctx::Context, regs::Vector{RegistrySpec} = collect_registries(depots1()))
    errors = Tuple{String, String}[]
    ctx.preview && (@info("skipping updating registries in preview mode"); return nothing)
    for reg in unique(r -> r.uuid, find_installed_registries(regs))
        if isdir(joinpath(reg.path, ".git"))
            regpath = pathrepr(reg.path)
            printpkgstyle(ctx, :Updating, "registry at " * regpath)
            # Using LibGit2.with here crashes julia when running the
            # tests for PkgDev wiht "Unreachable reached".
            # This seems to work around it.
            local repo
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
                    GitTools.fetch(repo; refspecs=["+refs/heads/$branch:refs/remotes/origin/$branch"])
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
                close(repo)
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

# Lookup package names & uuids in a single pass through registries
function find_registered!(env::EnvCache,
    names::Vector{String},
    uuids::Vector{UUID}=UUID[]
)::Nothing
    # only look if there's something new to see
    names = filter(name -> !haskey(env.uuids, name), names)
    uuids = filter(uuid -> !haskey(env.paths, uuid), uuids)
    isempty(names) && isempty(uuids) && return

    # since we're looking anyway, look for everything
    save(name::String) =
        name in names || haskey(env.uuids, name) || push!(names, name)
    save(uuid::UUID) =
        uuid in uuids || haskey(env.paths, uuid) || push!(uuids, uuid)

    # lookup any dependency in the project file
    for (name, uuid) in env.project.deps
        save(name); save(uuid)
    end
    # lookup anything mentioned in the manifest file
    for (uuid, entry) in env.manifest
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
    for name in names; env.uuids[name] = UUID[]; end
    for uuid in uuids; env.paths[uuid] = String[]; end
    for uuid in uuids; env.names[uuid] = String[]; end

    # note: empty vectors will be left for names & uuids that aren't found
    clone_default_registries()
    for registry in collect_registries()
        data = read_registry(joinpath(registry.path, "Registry.toml"))
        for (_uuid, pkgdata) in data["packages"]
              uuid = UUID(_uuid)
              name = pkgdata["name"]
              path = abspath(registry.path, pkgdata["path"])
              push!(get!(env.uuids, name, UUID[]), uuid)
              push!(get!(env.paths, uuid, String[]), path)
              push!(get!(env.names, uuid, String[]), name)
        end
    end
    for d in (env.uuids, env.paths, env.names)
        for (k, v) in d
            unique!(v)
        end
    end
end

find_registered!(env::EnvCache, uuids::Vector{UUID}; force::Bool=false)::Nothing =
    find_registered!(env, String[], uuids)

# Get registered uuids associated with a package name
function registered_uuids(env::EnvCache, name::String)::Vector{UUID}
    find_registered!(env, [name], UUID[])
    return unique(env.uuids[name])
end

# Get registered paths associated with a package uuid
function registered_paths(env::EnvCache, uuid::UUID)::Vector{String}
    find_registered!(env, String[], [uuid])
    return env.paths[uuid]
end

#Get registered names associated with a package uuid
function registered_names(env::EnvCache, uuid::UUID)::Vector{String}
    find_registered!(env, String[], [uuid])
    return env.names[uuid]
end

# Determine a single UUID for a given name, prompting if needed
function registered_uuid(env::EnvCache, name::String)::Union{Nothing,UUID}
    uuids = registered_uuids(env, name)
    length(uuids) == 0 && return nothing
    length(uuids) == 1 && return uuids[1]
    choices::Vector{String} = []
    choices_cache::Vector{Tuple{UUID,String}} = []
    for uuid in uuids
        values = registered_info(env, uuid, "repo")
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
        env.paths[choices_cache[choice][1]] = [choices_cache[choice][2]]
        return choices_cache[choice][1]
    else
        pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
    end
end

# Determine current name for a given package UUID
function registered_name(env::EnvCache, uuid::UUID)::String
    names = registered_names(env, uuid)
    length(names) == 0 && return ""
    length(names) == 1 && return names[1]
    values = registered_info(env, uuid, "name")
    name = nothing
    for value in values
        name  == nothing && (name = value[2])
        name != value[2] && pkgerror("package `$uuid` has multiple registered name values: $name, $(value[2])")
    end
    return name
end

# Return most current package info for a registered UUID
function registered_info(env::EnvCache, uuid::UUID, key::String)
    paths = env.paths[uuid]
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
manifest_info(env::EnvCache, uuid::Nothing) = nothing
function manifest_info(env::EnvCache, uuid::UUID)::Union{PackageEntry,Nothing}
    any(uuids -> uuid in uuids, values(env.uuids)) || find_registered!(env, [uuid])
    return get(env.manifest, uuid, nothing)
end

# TODO: redirect to ctx stream
function printpkgstyle(io::IO, cmd::Symbol, text::String, ignore_indent::Bool=false)
    indent = textwidth(string(:Downloaded))
    ignore_indent && (indent = 0)
    printstyled(io, lpad(string(cmd), indent), color=:green, bold=true)
    println(io, " ", text)
end

# TODO: use ctx specific context
function printpkgstyle(ctx::Context, cmd::Symbol, text::String, ignore_indent::Bool=false)
    printpkgstyle(stdout, cmd, text)
end


function pathrepr(path::String)
    # print stdlib paths as @stdlib/Name
    if startswith(path, stdlib_dir())
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

function project_key_order(key::String)
    key == "name"     && return 1
    key == "uuid"     && return 2
    key == "keywords" && return 3
    key == "license"  && return 4
    key == "desc"     && return 5
    key == "deps"     && return 6
    key == "compat"   && return 7
    return 8
end

string(x::Vector{String}) = x

function destructure(project::Project)::Dict
    raw = project.other
    function entry!(key::String, src::Dict)
        if isempty(src)
            delete!(raw, key)
        else
            raw[key] = Dict(string(name) => string(uuid) for (name,uuid) in src)
        end
    end
    entry!(key::String, src) = src === nothing ? delete!(raw, key) : (raw[key] = string(src))

    entry!("name", project.name)
    entry!("uuid", project.uuid)
    entry!("version", project.version)
    entry!("manifest", project.manifest)
    entry!("deps", project.deps)
    entry!("extras", project.extras)
    entry!("compat", project.compat)
    entry!("targets", project.targets)
    return raw
end

function destructure(manifest::Manifest)::Dict
    function entry!(entry, key, value, default=nothing)
        if value == default
            delete!(entry, key)
        else
            entry[key] = value isa TOML.TYPE ? value : string(value)
        end
    end

    unique_name = Dict{String,Bool}()
    for (uuid, entry) in manifest
        unique_name[entry.name] = !haskey(unique_name, entry.name)
    end

    raw = Dict{String,Any}()
    for (uuid, entry) in manifest
        new_entry = something(entry.other, Dict{String,Any}())
        new_entry["uuid"] = string(uuid)
        entry!(new_entry, "version", entry.version)
        entry!(new_entry, "git-tree-sha1", entry.repo.tree_sha)
        entry!(new_entry, "pinned", entry.pinned, false)
        entry!(new_entry, "path", entry.path)
        entry!(new_entry, "repo-url", entry.repo.url)
        entry!(new_entry, "repo-rev", entry.repo.rev)
        if isempty(entry.deps)
            delete!(new_entry, "deps")
        else
            if all(dep -> unique_name[first(dep)], entry.deps)
                new_entry["deps"] = sort(collect(keys(entry.deps)))
            else
                new_entry["deps"] = Dict{String,String}()
                for (name, uuid) in entry.deps
                    new_entry["deps"][name] = string(uuid)
                end
            end
        end
        push!(get!(raw, entry.name, Dict{String,Any}[]), new_entry)
    end
    return raw
end

write_project(project::Project, project_file::AbstractString) =
    write_project(destructure(project), project_file)
write_project(project::Project, io::IO) =
    write_project(destructure(project), io)
write_project(project::Dict, project_file::AbstractString) =
    open(io -> write_project(project, io), project_file; truncate=true)
write_project(project::Dict, io::IO) =
    TOML.print(io, project, sorted=true, by=key -> (project_key_order(key), key))

function write_project(project::Project, env, old_env, ctx::Context; display_diff=true)
    project = destructure(ctx.env.project)
    if !isempty(project) || ispath(env.project_file)
        if display_diff && !(ctx.currently_running_target)
            printpkgstyle(ctx, :Updating, pathrepr(env.project_file))
            Pkg.Display.print_project_diff(ctx, old_env, env)
        end
        if !ctx.preview
            mkpath(dirname(env.project_file))
            write_project(project, env.project_file)
        end
    end
end

write_manifest(manifest::Manifest, manifest_file::AbstractString) =
    open(io -> write_manifest(manifest, io), manifest_file; truncate=true)

function write_manifest(manifest::Manifest,io::IO)
    raw = destructure(manifest)
    print(io, "# This file is machine-generated - editing it directly is not advised\n\n")
    TOML.print(io, raw, sorted=true)
end

function write_manifest(manifest::Manifest, env, old_env, ctx::Context; display_diff=true)
    isempty(manifest) && !ispath(env.manifest_file) && return

    if display_diff && !(ctx.currently_running_target)
        printpkgstyle(ctx, :Updating, pathrepr(env.manifest_file))
        Pkg.Display.print_manifest_diff(ctx, old_env, env)
    end
    !ctx.preview && write_manifest(manifest, env.manifest_file)
end

function write_env(ctx::Context; display_diff=true)
    env = ctx.env
    old_env = EnvCache(env.env) # load old environment for comparison
    write_project(env.project, env, old_env, ctx; display_diff=display_diff)
    write_manifest(env.manifest, env, old_env, ctx; display_diff=display_diff)
end

end # module
