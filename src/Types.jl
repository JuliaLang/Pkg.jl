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
import ..BinaryPlatforms: Platform

import Base: SHA1
using SHA

export UUID, pkgID, SHA1, VersionRange, VersionSpec, empty_versionspec,
    Requires, Fixed, merge_requires!, satisfies, ResolverError,
    PackageSpec, EnvCache, Context, PackageInfo, ProjectInfo, GitRepo, Context!, get_deps,
    PkgError, pkgerror, has_name, has_uuid, is_stdlib, write_env, write_env_usage, parse_toml, find_registered!,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved, instantiate_pkg_repo!,
    manifest_info, registered_uuids, registered_paths, registered_uuid, registered_name,
    read_project, read_package, read_manifest, pathrepr, registries,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PackageSpecialAction, PKGSPEC_NOTHING, PKGSPEC_PINNED, PKGSPEC_FREED, PKGSPEC_DEVELOPED, PKGSPEC_TESTED, PKGSPEC_REPO_ADDED,
    printpkgstyle,
    projectfile_path, manifestfile_path,
    RegistrySpec,
    is_tracking_registered_version, is_tracking_unregistered, find_installed, source_path

using ..PkgErrors, ..GitRepos, ..VersionTypes, ..Manifests, ..Projects, ..PackageSpecs,
    ..Utils, ..EnvCaches, ..Contexts, ..RegistrySpecs, ..ResolverTypes, ..PackageResolve,
    ..PkgSpecUtils
import ..PkgSpecUtils: find_installed
import ..Infos: ProjectInfo, PackageInfo
import ..RegistryOps: clone_or_cp_registries, remove_registries, update_registries, find_installed_registries,
    clone_default_registries, populate_known_registries_with_urls!, find_registered!, registered_uuids,
    registered_paths, registered_names, registered_info, DEFAULT_REGISTRIES

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

project_uuid(ctx::Context) = ctx.env.pkg === nothing ? nothing : ctx.env.pkg.uuid
collides_with_project(ctx::Context, pkg::PackageSpec) =
    is_project_name(ctx, pkg.name) || is_project_uuid(ctx, pkg.uuid)
is_project(ctx::Context, pkg::PackageSpec) = is_project_uuid(ctx, pkg.uuid)
is_project_name(ctx::Context, name::String) =
    ctx.env.pkg !== nothing && ctx.env.pkg.name == name
is_project_uuid(ctx::Context, uuid::UUID) = project_uuid(ctx) == uuid
Utils.is_stdlib(ctx::Context, uuid::UUID) = uuid in keys(ctx.stdlibs)

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

const refspecs = ["+refs/*:refs/remotes/cache/*"]
const reg_pkg = r"(?:^|[\/\\])(\w+?)(?:\.jl)?(?:\.git)?(?:[\/\\])?$"

function relative_project_path(ctx::Context, path::String)
    # compute path relative the project
    # realpath needed to expand symlinks before taking the relative path
    return relpath(safe_realpath(abspath(path)),
                   safe_realpath(dirname(ctx.env.project_file)))
end

function git_checkout_latest!(ctx::Context, repo_path::AbstractString)
    LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
        rev = LibGit2.isattached(repo) ?
            LibGit2.branch(repo) :
            string(LibGit2.GitHash(LibGit2.head(repo)))
        gitobject, isbranch = nothing, nothing
        Base.shred!(LibGit2.CachedCredentials()) do creds
            gitobject, isbranch = get_object_branch(ctx, repo, rev, creds)
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

    if casesensitive_isdir(dev_path)
        if !isfile(joinpath(dev_path, "src", pkg.name * ".jl"))
            pkgerror("Path `$(dev_path)` exists but it does not contain `src/$(pkg.name).jl")
        end
        println(ctx.io,
                "Path `$(dev_path)` exists and looks like the correct package. Using existing path.")
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

function fresh_clone(ctx::Context, pkg::PackageSpec)
    clone_path = joinpath(depots1(), "clones")
    mkpath(clone_path)
    repo_path = joinpath(clone_path, string(hash(pkg.repo.url), "_full"))
    # make sure you have a fresh clone
    repo = nothing
    try
        repo = GitTools.ensure_clone(ctx, repo_path, pkg.repo.url)
        Base.shred!(LibGit2.CachedCredentials()) do creds
            GitTools.fetch(ctx, repo, pkg.repo.url; refspecs=refspecs, credentials=creds)
        end
    finally
        repo isa LibGit2.GitRepo && LibGit2.close(repo)
    end
    # Copy the repo to a temporary place and check out the rev
    temp_repo = mktempdir()
    cp(repo_path, temp_repo; force=true)
    git_checkout_latest!(ctx, temp_repo)
    return temp_repo
end

function dev_resolve_pkg!(ctx::Context, pkg::PackageSpec)
    if pkg.uuid === nothing # have to resolve UUID
        uuid = get(ctx.env.project.deps, pkg.name, nothing)
        if uuid !== nothing # try to resolve with manifest
            entry = manifest_info(ctx, uuid)
            if entry.repo.url !== nothing
                @debug "Resolving dev repo against manifest."
                pkg.repo = entry.repo
                return nothing # no need to continue, found pkg info
            end
        end
        registry_resolve!(ctx, pkg)
        if pkg.uuid === nothing
            pkgerror("Package `$pkg.name` could not be found in the manifest ",
                     "or in a regsitry.")
        end
    end
    paths = registered_paths(ctx, pkg.uuid)
    isempty(paths) && pkgerror("Package with UUID `$(pkg.uuid)` could not be found in a registry.")
    _, pkg.repo.url = Types.registered_info(ctx, pkg.uuid, "repo")[1] #TODO look into [1]
end

function remote_dev_path!(ctx::Context, pkg::PackageSpec, shared::Bool)
    # Only update the registry in case of developing a non-local package
    update_registries(ctx)
    # We save the repo in case another environment wants to develop from the same repo,
    # this avoids having to reclone it from scratch.
    if pkg.repo.url === nothing # specified by name or uuid
        dev_resolve_pkg!(ctx, pkg)
    end
    temp_clone = fresh_clone(ctx, pkg)
    # parse repo to determine dev path
    parse_package!(ctx, pkg, temp_clone)
    canonical_dev_path!(ctx, pkg, shared; default=temp_clone)
    return pkg.uuid
end

function handle_repos_develop!(ctx::Context, pkgs::AbstractVector{PackageSpec}, shared::Bool)
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
        pkg.repo = GitRepo() # clear repo field, no longer needed
    end
    return new_uuids
end

clone_path(url) = joinpath(depots1(), "clones", string(hash(url)))
function clone_path!(ctx::Context, url)
    clone = clone_path(url)
    mkpath(dirname(clone))
    Base.shred!(LibGit2.CachedCredentials()) do creds
        LibGit2.with(GitTools.ensure_clone(ctx, clone, url; isbare=true, credentials=creds)) do repo
            GitTools.fetch(ctx, repo; refspecs=refspecs, credentials=creds)
        end
    end
    return clone
end

function guess_rev(ctx::Context, repo_path)::String
    rev = nothing
    LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
        rev = LibGit2.isattached(repo) ?
            LibGit2.branch(repo) :
            string(LibGit2.GitHash(LibGit2.head(repo)))
        gitobject, isbranch = nothing, nothing
        Base.shred!(LibGit2.CachedCredentials()) do creds
            gitobject, isbranch = get_object_branch(ctx, repo, rev, creds)
        end
        LibGit2.with(gitobject) do object
            rev = isbranch ? rev : string(LibGit2.GitHash(gitobject))
        end
    end
    return rev
end

function with_git_tree(fn, ctx::Context, repo_path::String, rev::String)
    gitobject = nothing
    Base.shred!(LibGit2.CachedCredentials()) do creds
        LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
            gitobject, isbranch = get_object_branch(ctx, repo, rev, creds)
            LibGit2.with(LibGit2.peel(LibGit2.GitTree, gitobject)) do git_tree
                @assert git_tree isa LibGit2.GitTree
                return applicable(fn, repo, git_tree) ?
                    fn(repo, git_tree) :
                    fn(git_tree)
            end
        end
    end
end

function repo_checkout(ctx::Context, repo_path, rev)
    project_path = mktempdir()
    with_git_tree(ctx, repo_path, rev) do repo, git_tree
        _project_path = project_path # https://github.com/JuliaLang/julia/issues/30048
        GC.@preserve _project_path begin
            opts = LibGit2.CheckoutOptions(
                checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
                target_directory = Base.unsafe_convert(Cstring, _project_path),
            )
            LibGit2.checkout_tree(repo, git_tree, options=opts)
        end
    end
    return project_path
end

function tree_hash(ctx::Context, repo_path, rev)
    with_git_tree(ctx, repo_path, rev) do git_tree
        return SHA1(string(LibGit2.GitHash(git_tree))) # TODO can it be just SHA1?
    end
end

function instantiate_pkg_repo!(ctx::Context, pkg::PackageSpec, cached_repo::Union{Nothing,String}=nothing)
    pkg.special_action = PKGSPEC_REPO_ADDED
    clone = clone_path!(ctx, pkg.repo.url)
    pkg.tree_hash = tree_hash(ctx, clone, pkg.repo.rev)
    version_path = find_installed(pkg.name, pkg.uuid, pkg.tree_hash)
    if cached_repo === nothing
        cached_repo = repo_checkout(ctx, clone, string(pkg.tree_hash))
    end
    isdir(version_path) && return false
    mkpath(version_path)
    mv(cached_repo, version_path; force=true)
    return true
end

# partial PackageSpec -> PackageSpec with all the relevant fields filled out
function resolve_repo_add!(ctx::Context, pkg::PackageSpec)
    cached_repo = nothing
    if pkg.repo.url !== nothing
        clone_path = clone_path!(ctx, pkg.repo.url)
        pkg.repo.rev = something(pkg.repo.rev, guess_rev(ctx, clone_path))
        cached_repo = repo_checkout(ctx, clone_path, pkg.repo.rev)
        package = parse_package!(ctx, pkg, cached_repo)
    elseif pkg.name !== nothing || pkg.uuid !== nothing
        pkg.repo.rev === nothing && pkgerror("Rev must be specified")
        registry_resolve!(ctx, pkg)
        ensure_resolved(ctx, [pkg]; registry=true)
        _, pkg.repo.url = Types.registered_info(ctx, pkg.uuid, "repo")[1]
    else
        @assert false "Package should be specified by name, URL, or UUID" # TODO
    end
    return cached_repo
end

function handle_repo_add!(ctx::Context, pkg::PackageSpec)
    cached_repo = resolve_repo_add!(ctx, pkg)
    # if pinned, return early
    entry = manifest_info(ctx, pkg.uuid)
    if (entry !== nothing && entry.pinned)
        cached_repo !== nothing && rm(cached_repo; recursive=true, force=true)
        pkg.tree_hash = entry.tree_hash
        return false
    end
    # instantiate repo
    return instantiate_pkg_repo!(ctx, pkg, cached_repo)
end

"""
Ensure repo specified by `repo` exists at version path for package
Set tree_hash
"""
function handle_repos_add!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    new_uuids = UUID[]
    for pkg in pkgs
        handle_repo_add!(ctx, pkg) && push!(new_uuids, pkg.uuid)
    end
    return new_uuids
end

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

function parse_package!(ctx, pkg, project_path)
    env = ctx.env
    project_file = projectfile_path(project_path; strict=true)
    if project_file !== nothing
        project_data = read_package(project_file)
        pkg.uuid = project_data.uuid # TODO check no overwrite
        pkg.name = project_data.name # TODO check no overwrite
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
        reg_uuids = registered_uuids(ctx, pkg.name)
        is_registered = !isempty(reg_uuids)
        if !is_registered
            # This is an unregistered old style package, give it a UUID and a version
            if !has_uuid(pkg)
                uuid_unreg_pkg = UUID(0xa9a2672e746f11e833ef119c5b888869)
                pkg.uuid = uuid5(uuid_unreg_pkg, pkg.name)
                println(ctx.io, "Assigning UUID $(pkg.uuid) to $(pkg.name)")
            end
        else
            @assert length(reg_uuids) == 1
            pkg.uuid = reg_uuids[1]
        end
    end
end

get_object_branch(ctx::Context, repo, rev::SHA1, creds) =
    get_object_branch(ctx, repo, string(rev), creds)

function get_object_branch(ctx::Context, repo, rev, creds)
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
            GitTools.fetch(ctx, repo; refspecs=refspecs, credentials=creds)
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

function Projects.write_project(project::Project, env, old_env, ctx::Context; display_diff=true)
    project = Projects.destructure(ctx.env.project)
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

function Manifests.write_manifest(manifest::Manifest, env, old_env, ctx::Context; display_diff=true)
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
