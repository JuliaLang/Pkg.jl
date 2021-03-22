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
import ..Pkg, ..DEFAULT_IO, ..Registry
import ..Pkg: GitTools, depots, depots1, logdir, set_readonly, safe_realpath, pkg_server, stdlib_dir, stdlib_path, isurl
import Base.BinaryPlatforms: Platform
import ..PlatformEngines: download, download_verify_unpack
using ..Pkg.Versions

import Base: SHA1
using SHA

export UUID, SHA1, VersionRange, VersionSpec,
    PackageSpec, PackageEntry, EnvCache, Context, GitRepo, Context!, Manifest, Project, err_rep,
    PkgError, pkgerror, has_name, has_uuid, is_stdlib, is_unregistered_stdlib, stdlibs, write_env, write_env_usage, parse_toml, find_registered!,
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

using ..Pkg: PackageSpec, has_name, has_uuid, isresolved,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PreserveLevel, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_NONE


using ..Environments: EnvCache, Project, Manifest, GitRepo,
    project_uuid, is_project_name, is_project_uuid, PackageEntry, write_project, write_manifest, manifestfile_path, write_env_usage,
    projectfile_path, read_package, read_project, read_manifest, manifest_info, write_env


#################
# Pkg Error #
#################
struct PkgError <: Exception
    msg::String
end
pkgerror(msg::String...) = throw(PkgError(join(msg)))
Base.showerror(io::IO, err::PkgError) = print(io, err.msg)



collides_with_project(env::EnvCache, pkg::PackageSpec) =
    is_project_name(env, pkg.name) || is_project_uuid(env, pkg.uuid)
is_project(env::EnvCache, pkg::PackageSpec) = is_project_uuid(env, pkg.uuid)




###########
# Context #
###########

# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    io::IO = something(DEFAULT_IO[])
    use_libgit2_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    num_concurrent_downloads::Int = 8

    # Registries
    registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries()

    # The Julia Version to resolve with respect to
    julia_version::Union{VersionNumber,Nothing} = VERSION
end


const STDLIB = Ref{Dict{UUID,String}}()
function load_stdlib()
    stdlib = Dict{UUID,String}()
    for name in readdir(stdlib_dir())
        projfile = projectfile_path(stdlib_path(name); strict=true)
        nothing === projfile && continue
        project = Base.parsed_toml(projfile)
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

# Allow asking if something is an stdlib for a particular version of Julia
function is_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    # Only use the cache if we are asking for stdlibs in a custom Julia version
    if julia_version == VERSION
        return is_stdlib(uuid)
    end

    # If this UUID is known to be unregistered, always return `true`
    if haskey(UNREGISTERED_STDLIBS, uuid)
        return true
    end

    # Otherwise, if the `julia_version` is `nothing`, all registered stdlibs
    # will be treated like normal packages.
    if julia_version === nothing
        return false
    end

    # If we are given an actual version, find the entry in `STDLIBS_BY_VERSION`
    # that corresponds to the requested version, and use that.
    last_stdlibs = Dict{UUID,String}()
    for (version, stdlibs) in STDLIBS_BY_VERSION
        if VersionNumber(julia_version.major, julia_version.minor, julia_version.patch) < version
            break
        end
        last_stdlibs = stdlibs
    end

    # Note that if the user asks for something like `julia_version = 0.7.0`, we'll
    # fall through with an empty `last_stdlibs`, which will always return `false`.
    return uuid in keys(last_stdlibs)
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
            println(ctx.io, "Path `$(dev_path)` exists and looks like the correct package. Using existing path.")
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
    pkg.path = shared ? dev_path : relative_project_path(ctx.env.project_file, dev_path)
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
    registry_resolve!(ctx.registries, pkg)
    # Didn't find the package in the registry, but maybe it exists in the updated registry
    if !isresolved(pkg)
        Registry.update(; io=ctx.io, force=false)
        registry_resolve!(ctx.registries, pkg)
    end
    ensure_resolved(ctx.env.manifest, [pkg]; registry=true)
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
                pkgerror("Did not find a git repository at `$(pkg.repo.source)`")
            end
            LibGit2.with(GitTools.check_valid_HEAD, LibGit2.GitRepo(pkg.repo.source)) # check for valid git HEAD
            pkg.repo.source = isabspath(pkg.repo.source) ? safe_realpath(pkg.repo.source) : relative_project_path(ctx.env.project_file, pkg.repo.source)
            repo_source = normpath(joinpath(dirname(ctx.env.project_file), pkg.repo.source))
        else
            pkgerror("Path `$(pkg.repo.source)` does not exist.")
        end
    end

    let repo_source = repo_source
        LibGit2.with(GitTools.ensure_clone(ctx.io, add_repo_cache_path(repo_source), repo_source; isbare=true)) do repo
            GitTools.check_valid_HEAD(repo)

            # If the user didn't specify rev, assume they want the default (master) branch if on a branch, otherwise the current commit
            if pkg.repo.rev === nothing
                pkg.repo.rev = LibGit2.isattached(repo) ? LibGit2.branch(repo) : string(LibGit2.GitHash(LibGit2.head(repo)))
            end

            obj_branch = get_object_or_branch(repo, pkg.repo.rev)
            fetched = false
            if obj_branch === nothing
                fetched = true
                GitTools.fetch(ctx.io, repo, repo_source; refspecs=refspecs)
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
                GitTools.fetch(ctx.io, repo, repo_source; refspecs=refspecs)
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
                version_path = Pkg.Operations.source_path(ctx.env.project_file, pkg, ctx.julia_version)
                isdir(version_path) && return false
            end

            temp_path = mktempdir()
            GitTools.checkout_tree_to_path(repo, tree_hash_object, temp_path)
            package = resolve_projectfile!(ctx.env, pkg, temp_path)

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
    new_uuids = UUID[]
    for pkg in pkgs
        handle_repo_add!(ctx, pkg) && push!(new_uuids, pkg.uuid)
        @assert pkg.name !== nothing && pkg.uuid !== nothing && pkg.tree_hash !== nothing
    end
    return new_uuids
end

function resolve_projectfile!(env::EnvCache, pkg, project_path)
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
function manifest_resolve!(manifest::Manifest, pkgs::AbstractVector{PackageSpec}; force=false)
    uuids = Dict{String,Vector{UUID}}()
    names = Dict{UUID,String}()
    for (uuid, entry) in manifest
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
function ensure_resolved(manifest::Manifest,
        pkgs::AbstractVector{PackageSpec};
        registry::Bool=false,)::Nothing
        unresolved_uuids = Dict{String,Vector{UUID}}()
    for pkg in pkgs
        has_uuid(pkg) && continue
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

end # module
