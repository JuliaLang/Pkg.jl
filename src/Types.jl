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
    RegistrySpec

using ..PkgErrors, ..GitRepos, ..VersionTypes, ..Manifests, ..Projects, ..PackageSpecs,
    ..Utils, ..EnvCaches, ..Contexts, ..RegistrySpecs

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
    version_path = Pkg.Operations.find_installed(pkg.name, pkg.uuid, pkg.tree_hash)
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
function manifest_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    uuids = Dict{String,Vector{UUID}}()
    names = Dict{UUID,String}()
    for (uuid, entry) in ctx.env.manifest
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
function ensure_resolved(ctx::Context,
    pkgs::AbstractVector{PackageSpec};
    registry::Bool=false,)::Nothing
    unresolved = Dict{String,Vector{UUID}}()
    for name in [pkg.name for pkg in pkgs if !has_uuid(pkg)]
        uuids = [uuid for (uuid, entry) in ctx.env.manifest if entry.name == name]
        sort!(uuids, by=uuid -> uuid.value)
        unresolved[name] = uuids
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

const DEFAULT_REGISTRIES =
    RegistrySpec[RegistrySpec(name = "General",
                              uuid = UUID("23338594-aafe-5451-b93e-139f81909106"),
                              url = "https://github.com/JuliaRegistries/General.git")]

function clone_default_registries(ctx::Context)
    if isempty(collect_registries()) # only clone if there are no installed registries
        printpkgstyle(ctx, :Cloning, "default registries into $(pathrepr(depots1()))")
        clone_or_cp_registries(DEFAULT_REGISTRIES)
    end
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
    if ctx.preview
        println(ctx.io, "Skipping adding registries in preview mode")
        return nothing
    end
    populate_known_registries_with_urls!(regs)
    for reg in regs
        if reg.path !== nothing && reg.url !== nothing
            pkgerror("ambiguous registry specification; both url and path is set.")
        end
        # clone to tmpdir first
        tmp = mktempdir()
        if reg.path !== nothing # copy from local source
            printpkgstyle(ctx, :Copying, "registry from `$(Base.contractuser(reg.path))`")
            cp(reg.path, tmp; force=true)
        elseif reg.url !== nothing # clone from url
            Base.shred!(LibGit2.CachedCredentials()) do creds
                LibGit2.with(GitTools.clone(ctx, reg.url, tmp; header = "registry from $(repr(reg.url))",
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
        # Clean up
        Base.rm(tmp; recursive=true, force=true)
    end
    return nothing
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
    if ctx.preview
        println(ctx.io, "skipping removing registries in preview mode")
        return nothing
    end
    for registry in find_installed_registries(ctx, regs)
        printpkgstyle(ctx, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        rm(registry.path; force=true, recursive=true)
    end
    return nothing
end

# entry point for `registry up`
function update_registries(ctx::Context, regs::Vector{RegistrySpec} = collect_registries(depots1());
                           force::Bool=false)
    !force && UPDATED_REGISTRY_THIS_SESSION[] && return
    errors = Tuple{String, String}[]
    if ctx.preview
        println(ctx.io, "skipping updating registries in preview mode")
        return nothing
    end
    for reg in unique(r -> r.uuid, find_installed_registries(ctx, regs))
        if isdir(joinpath(reg.path, ".git"))
            regpath = pathrepr(reg.path)
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
    names = filter(name -> !haskey(ctx.reg.uuids, name), names)
    uuids = filter(uuid -> !haskey(ctx.reg.paths, uuid), uuids)
    isempty(names) && isempty(uuids) && return

    # since we're looking anyway, look for everything
    save(name::String) =
        name in names || haskey(ctx.reg.uuids, name) || push!(names, name)
    save(uuid::UUID) =
        uuid in uuids || haskey(ctx.reg.paths, uuid) || push!(uuids, uuid)

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
    for name in names; ctx.reg.uuids[name] = UUID[]; end
    for uuid in uuids; ctx.reg.paths[uuid] = String[]; end
    for uuid in uuids; ctx.reg.names[uuid] = String[]; end

    # note: empty vectors will be left for names & uuids that aren't found
    clone_default_registries(ctx)
    for registry in collect_registries()
        data = read_registry(joinpath(registry.path, "Registry.toml"))
        for (_uuid, pkgdata) in data["packages"]
              uuid = UUID(_uuid)
              name = pkgdata["name"]
              path = abspath(registry.path, pkgdata["path"])
              push!(get!(ctx.reg.uuids, name, UUID[]), uuid)
              push!(get!(ctx.reg.paths, uuid, String[]), path)
              push!(get!(ctx.reg.names, uuid, String[]), name)
        end
    end
    for d in (ctx.reg.uuids, ctx.reg.paths, ctx.reg.names)
        for (k, v) in d
            unique!(v)
        end
    end
end

# Get registered uuids associated with a package name
function registered_uuids(ctx::Context, name::String)::Vector{UUID}
    find_registered!(ctx, [name], UUID[])
    return unique(ctx.reg.uuids[name])
end

# Get registered paths associated with a package uuid
function registered_paths(ctx::Context, uuid::UUID)::Vector{String}
    find_registered!(ctx, String[], [uuid])
    return ctx.reg.paths[uuid]
end

#Get registered names associated with a package uuid
function registered_names(ctx::Context, uuid::UUID)::Vector{String}
    find_registered!(ctx, String[], [uuid])
    return ctx.reg.names[uuid]
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
        ctx.reg.paths[choices_cache[choice][1]] = [choices_cache[choice][2]]
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
        name  == nothing && (name = value[2])
        name != value[2] && pkgerror("package `$uuid` has multiple registered name values: $name, $(value[2])")
    end
    return name
end

# Return most current package info for a registered UUID
function registered_info(ctx::Context, uuid::UUID, key::String)
    haskey(ctx.reg.paths, uuid) || find_registered!(ctx, [uuid])
    paths = ctx.reg.paths[uuid]
    isempty(paths) && pkgerror("`$uuid` is not registered")
    values = []
    for path in paths
        info = parse_toml(path, "Package.toml")
        value = get(info, key, nothing)
        push!(values, (path, value))
    end
    return values
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

###
### PackageInfo
###

Base.@kwdef struct PackageInfo
    name::String
    version::Union{Nothing,VersionNumber}
    ispinned::Bool
    isdeveloped::Bool
    source::String
    dependencies::Vector{UUID}
end

###
### ProjectInfo
###

Base.@kwdef struct ProjectInfo
    name::String
    uuid::UUID
    version::VersionNumber
    dependencies::Dict{String,UUID}
    path::String
end

end # module
