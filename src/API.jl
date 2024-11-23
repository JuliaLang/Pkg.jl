# This file is a part of Julia. License is MIT: https://julialang.org/license

module API

using UUIDs
using Printf
import Random
using Dates
import LibGit2
import Logging
using Serialization
using REPL.TerminalMenus
import FileWatching

import Base: StaleCacheKey

import ..depots, ..depots1, ..logdir, ..devdir, ..printpkgstyle
import ..Operations, ..GitTools, ..Pkg, ..Registry
import ..can_fancyprint, ..pathrepr, ..isurl, ..PREV_ENV_PATH
using ..Types, ..TOML
using ..Types: VersionTypes
using Base.BinaryPlatforms
import ..stderr_f, ..stdout_f
using ..Artifacts: artifact_paths
using ..MiniProgressBars
import ..Resolve: ResolverError

include("generate.jl")

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
        a.is_tracking_repo == b.is_tracking_repo &&
        a.is_tracking_registry == b.is_tracking_registry &&
        a.git_revision == b.git_revision && a.git_source == b.git_source &&
        a.source == b.source && a.dependencies == b.dependencies
end

function package_info(env::EnvCache, pkg::PackageSpec)::PackageInfo
    entry = manifest_info(env.manifest, pkg.uuid)
    if entry === nothing
        pkgerror("expected package $(err_rep(pkg)) to exist in the manifest",
                 " (use `resolve` to populate the manifest)")
    end
    package_info(env, pkg, entry)
end

function package_info(env::EnvCache, pkg::PackageSpec, entry::PackageEntry)::PackageInfo
    git_source = pkg.repo.source === nothing ? nothing :
        isurl(pkg.repo.source::String) ? pkg.repo.source::String :
        Operations.project_rel_path(env, pkg.repo.source::String)
    info = PackageInfo(
        name                 = pkg.name,
        version              = pkg.version != VersionSpec() ? pkg.version : nothing,
        tree_hash            = pkg.tree_hash === nothing ? nothing : string(pkg.tree_hash), # TODO or should it just be a SHA?
        is_direct_dep        = pkg.uuid in values(env.project.deps),
        is_pinned            = pkg.pinned,
        is_tracking_path     = pkg.path !== nothing,
        is_tracking_repo     = pkg.repo.rev !== nothing || pkg.repo.source !== nothing,
        is_tracking_registry = Operations.is_tracking_registry(pkg),
        git_revision         = pkg.repo.rev,
        git_source           = git_source,
        source               = Operations.project_rel_path(env, Operations.source_path(env.manifest_file, pkg)),
        dependencies         = copy(entry.deps), #TODO is copy needed?
    )
    return info
end

dependencies() = dependencies(EnvCache())
function dependencies(env::EnvCache)
    pkgs = Operations.load_all_deps(env)
    return Dict(pkg.uuid::UUID => package_info(env, pkg) for pkg in pkgs)
end
function dependencies(fn::Function, uuid::UUID)
    dep = get(dependencies(), uuid, nothing)
    if dep === nothing
        pkgerror("dependency with UUID `$uuid` does not exist")
    end
    fn(dep)
end


Base.@kwdef struct ProjectInfo
    name::Union{Nothing,String}
    uuid::Union{Nothing,UUID}
    version::Union{Nothing,VersionNumber}
    ispackage::Bool
    dependencies::Dict{String,UUID}
    path::String
end

project() = project(EnvCache())
function project(env::EnvCache)::ProjectInfo
    pkg = env.pkg
    return ProjectInfo(
        name         = pkg === nothing ? nothing : pkg.name,
        uuid         = pkg === nothing ? nothing : pkg.uuid,
        version      = pkg === nothing ? nothing : pkg.version::VersionNumber,
        ispackage    = pkg !== nothing,
        dependencies = env.project.deps,
        path         = env.project_file
    )
end

function check_package_name(x::AbstractString, mode::Union{Nothing,String,Symbol}=nothing)
    if !Base.isidentifier(x)
        message = sprint() do iostr
            print(iostr, "`$x` is not a valid package name")
            if endswith(lowercase(x), ".jl")
                print(iostr, ". Perhaps you meant `$(chop(x; tail=3))`")
            end
            if mode !== nothing && any(occursin.(['\\','/'], x)) # maybe a url or a path
                print(iostr, "\nThe argument appears to be a URL or path, perhaps you meant ",
                    "`Pkg.$mode(url=\"...\")` or `Pkg.$mode(path=\"...\")`.")
            end
        end
        pkgerror(message)
    end
    return
end
check_package_name(::Nothing, ::Any) = nothing

function require_not_empty(pkgs, f::Symbol)
    isempty(pkgs) && pkgerror("$f requires at least one package")
end

# Provide some convenience calls
for f in (:develop, :add, :rm, :up, :pin, :free, :test, :build, :status, :why, :precompile)
    @eval begin
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...)          = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        function $f(pkgs::Vector{PackageSpec}; io::IO=$(f === :status ? :stdout_f : :stderr_f)(), kwargs...)
            $(f != :precompile) && Registry.download_default_registries(io)
            ctx = Context()
            # Save initial environment for undo/redo functionality
            if $(f != :precompile) && !saved_initial_snapshot[]
                add_snapshot_to_undo(ctx.env)
                saved_initial_snapshot[] = true
            end
            kwargs = merge((;kwargs...), (:io => io,))
            pkgs = deepcopy(pkgs) # don't mutate input
            foreach(handle_package_input!, pkgs)
            ret = $f(ctx, pkgs; kwargs...)
            $(f in (:add, :up, :pin, :free, :build)) && Pkg._auto_precompile(ctx)
            $(f in (:up, :pin, :free, :rm)) && Pkg._auto_gc(ctx)
            return ret
        end
        $f(ctx::Context; kwargs...) = $f(ctx, PackageSpec[]; kwargs...)
        function $f(; name::Union{Nothing,AbstractString}=nothing, uuid::Union{Nothing,String,UUID}=nothing,
                      version::Union{VersionNumber, String, VersionSpec, Nothing}=nothing,
                      url=nothing, rev=nothing, path=nothing, mode=PKGMODE_PROJECT, subdir=nothing, kwargs...)
            pkg = PackageSpec(; name, uuid, version, url, rev, path, subdir)
            if $f === status || $f === rm || $f === up
                kwargs = merge((;kwargs...), (:mode => mode,))
            end
            # Handle $f() case
            if all(isnothing, [name,uuid,version,url,rev,path,subdir])
                $f(PackageSpec[]; kwargs...)
            else
                $f(pkg; kwargs...)
            end
        end
        function $f(pkgs::Vector{<:NamedTuple}; kwargs...)
            $f([PackageSpec(;pkg...) for pkg in pkgs]; kwargs...)
        end
    end
end

function develop(ctx::Context, pkgs::Vector{PackageSpec}; shared::Bool=true,
                 preserve::PreserveLevel=Operations.default_preserve(), platform::AbstractPlatform=HostPlatform(), kwargs...)
    require_not_empty(pkgs, :develop)
    Context!(ctx; kwargs...)

    for pkg in pkgs
        check_package_name(pkg.name, "develop")
        if pkg.name == "julia" # if julia is passed as a package the solver gets tricked
            pkgerror("`julia` is not a valid package name")
        end
        if pkg.name === nothing && pkg.uuid === nothing && pkg.repo.source === nothing
            pkgerror("name, UUID, URL, or filesystem path specification required when calling `develop`")
        end
        if pkg.repo.rev !== nothing
            pkgerror("rev argument not supported by `develop`; consider using `add` instead")
        end
        if pkg.version != VersionSpec()
            pkgerror("version specification invalid when calling `develop`:",
                     " `$(pkg.version)` specified for package $(err_rep(pkg))")
        end
        # not strictly necessary to check these fields early, but it is more efficient
        if pkg.name !== nothing && (length(findall(x -> x.name == pkg.name, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same name: $(err_rep(pkg))")
        end
        if pkg.uuid !== nothing && (length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    new_git = handle_repos_develop!(ctx, pkgs, shared)

    for pkg in pkgs
        if Types.collides_with_project(ctx.env, pkg)
            pkgerror("package $(err_rep(pkg)) has the same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    Operations.develop(ctx, pkgs, new_git; preserve=preserve, platform=platform)
    return
end

function add(ctx::Context, pkgs::Vector{PackageSpec}; preserve::PreserveLevel=Operations.default_preserve(),
             platform::AbstractPlatform=HostPlatform(), kwargs...)
    require_not_empty(pkgs, :add)
    Context!(ctx; kwargs...)

    for pkg in pkgs
        check_package_name(pkg.name, "add")
        if pkg.name == "julia" # if julia is passed as a package the solver gets tricked
            pkgerror("`julia` is not a valid package name")
        end
        if pkg.name === nothing && pkg.uuid === nothing && pkg.repo.source === nothing
            pkgerror("name, UUID, URL, or filesystem path specification required when calling `add`")
        end
        if pkg.repo.source !== nothing || pkg.repo.rev !== nothing
            if pkg.version != VersionSpec()
                pkgerror("version specification invalid when tracking a repository:",
                         " `$(pkg.version)` specified for package $(err_rep(pkg))")
            end
        end
        # not strictly necessary to check these fields early, but it is more efficient
        if pkg.name !== nothing && (length(findall(x -> x.name == pkg.name, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same name: $(err_rep(pkg))")
        end
        if pkg.uuid !== nothing && (length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1)
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    repo_pkgs = [pkg for pkg in pkgs if (pkg.repo.source !== nothing || pkg.repo.rev !== nothing)]
    new_git = handle_repos_add!(ctx, repo_pkgs)
    # repo + unpinned -> name, uuid, repo.rev, repo.source, tree_hash
    # repo + pinned -> name, uuid, tree_hash

    Operations.update_registries(ctx; force=false, update_cooldown=Day(1))

    project_deps_resolve!(ctx.env, pkgs)
    registry_resolve!(ctx.registries, pkgs)
    stdlib_resolve!(pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs, registry=true)

    for pkg in pkgs
        if Types.collides_with_project(ctx.env, pkg)
            pkgerror("package $(err_rep(pkg)) has same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    Operations.add(ctx, pkgs, new_git; preserve, platform)
    return
end

function rm(ctx::Context, pkgs::Vector{PackageSpec}; mode=PKGMODE_PROJECT, all_pkgs::Bool=false, kwargs...)
    Context!(ctx; kwargs...)
    if all_pkgs
        !isempty(pkgs) && pkgerror("cannot specify packages when operating on all packages")
        append_all_pkgs!(pkgs, ctx, mode)
    else
        require_not_empty(pkgs, :rm)
    end

    for pkg in pkgs
        if pkg.name === nothing && pkg.uuid === nothing
            pkgerror("name or UUID specification required when calling `rm`")
        end
        if !(pkg.version == VersionSpec() && pkg.pinned == false &&
             pkg.tree_hash === nothing && pkg.repo.source === nothing &&
             pkg.repo.rev === nothing && pkg.path === nothing)
            pkgerror("packages may only be specified by name or UUID when calling `rm`")
        end
    end

    mode == PKGMODE_PROJECT && project_deps_resolve!(ctx.env, pkgs)
    mode == PKGMODE_MANIFEST && manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)

    Operations.rm(ctx, pkgs; mode)

    return
end


function append_all_pkgs!(pkgs, ctx, mode)
    if mode == PKGMODE_PROJECT || mode == PKGMODE_COMBINED
        for (name::String, uuid::UUID) in ctx.env.project.deps
            push!(pkgs, PackageSpec(name=name, uuid=uuid))
        end
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        for (uuid, entry) in ctx.env.manifest
            push!(pkgs, PackageSpec(name=entry.name, uuid=uuid))
        end
    end
    return
end

function up(ctx::Context, pkgs::Vector{PackageSpec};
            level::UpgradeLevel=UPLEVEL_MAJOR, mode::PackageMode=PKGMODE_PROJECT,
            preserve::Union{Nothing,PreserveLevel}= isempty(pkgs) ? nothing : PRESERVE_ALL,
            update_registry::Bool=true,
            skip_writing_project::Bool=false,
            kwargs...)
    Context!(ctx; kwargs...)
    if Operations.is_fully_pinned(ctx)
        printpkgstyle(ctx.io, :Update, "All dependencies are pinned - nothing to update.", color = Base.info_color())
        return
    end
    if update_registry
        Registry.download_default_registries(ctx.io)
        Operations.update_registries(ctx; force=true)
    end
    Operations.prune_manifest(ctx.env)
    if isempty(pkgs)
        append_all_pkgs!(pkgs, ctx, mode)
    else
        mode == PKGMODE_PROJECT && project_deps_resolve!(ctx.env, pkgs)
        mode == PKGMODE_MANIFEST && manifest_resolve!(ctx.env.manifest, pkgs)
        project_deps_resolve!(ctx.env, pkgs)
        manifest_resolve!(ctx.env.manifest, pkgs)
        ensure_resolved(ctx, ctx.env.manifest, pkgs)
    end
    Operations.up(ctx, pkgs, level; skip_writing_project, preserve)
    return
end

resolve(; io::IO=stderr_f(), kwargs...) = resolve(Context(;io); kwargs...)
function resolve(ctx::Context; skip_writing_project::Bool=false, kwargs...)
    up(ctx; level=UPLEVEL_FIXED, mode=PKGMODE_MANIFEST, update_registry=false, skip_writing_project, kwargs...)
    return nothing
end

function pin(ctx::Context, pkgs::Vector{PackageSpec}; all_pkgs::Bool=false, kwargs...)
    Context!(ctx; kwargs...)
    if all_pkgs
        !isempty(pkgs) && pkgerror("cannot specify packages when operating on all packages")
        append_all_pkgs!(pkgs, ctx, PKGMODE_MANIFEST)
    else
        require_not_empty(pkgs, :pin)
    end

    for pkg in pkgs
        if pkg.name === nothing && pkg.uuid === nothing
            pkgerror("name or UUID specification required when calling `pin`")
        end
        if pkg.repo.source !== nothing
            pkgerror("repository specification invalid when calling `pin`:",
                     " `$(pkg.repo.source)` specified for package $(err_rep(pkg))")
        end
        if pkg.repo.rev !== nothing
            pkgerror("git revision specification invalid when calling `pin`:",
                     " `$(pkg.repo.rev)` specified for package $(err_rep(pkg))")
        end
        version = pkg.version
        if version isa VersionSpec
            if version.ranges[1].lower != version.ranges[1].upper # TODO test this
                pkgerror("pinning a package requires a single version, not a versionrange")
            end
        end
    end

    project_deps_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)
    Operations.pin(ctx, pkgs)
    return
end

function free(ctx::Context, pkgs::Vector{PackageSpec}; all_pkgs::Bool=false, kwargs...)
    Context!(ctx; kwargs...)
    if all_pkgs
        !isempty(pkgs) && pkgerror("cannot specify packages when operating on all packages")
        append_all_pkgs!(pkgs, ctx, PKGMODE_MANIFEST)
    else
        require_not_empty(pkgs, :free)
    end

    for pkg in pkgs
        if pkg.name === nothing && pkg.uuid === nothing
            pkgerror("name or UUID specification required when calling `free`")
        end
        if !(pkg.version == VersionSpec() && pkg.pinned == false &&
             pkg.tree_hash === nothing && pkg.repo.source === nothing &&
             pkg.repo.rev === nothing && pkg.path === nothing)
            pkgerror("packages may only be specified by name or UUID when calling `free`")
        end
    end

    manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)

    Operations.free(ctx, pkgs; err_if_free = !all_pkgs)
    return
end

function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, test_fn=nothing,
              julia_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              test_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              force_latest_compatible_version::Bool=false,
              allow_earlier_backwards_compatible_versions::Bool=true,
              allow_reresolve::Bool=true,
              kwargs...)
    julia_args = Cmd(julia_args)
    test_args = Cmd(test_args)
    Context!(ctx; kwargs...)

    if isempty(pkgs)
        ctx.env.pkg === nothing && pkgerror("trying to test unnamed project") #TODO Allow this?
        push!(pkgs, ctx.env.pkg)
    else
        project_resolve!(ctx.env, pkgs)
        project_deps_resolve!(ctx.env, pkgs)
        manifest_resolve!(ctx.env.manifest, pkgs)
        ensure_resolved(ctx, ctx.env.manifest, pkgs)
    end
    Operations.test(
        ctx,
        pkgs;
        coverage,
        test_fn,
        julia_args,
        test_args,
        force_latest_compatible_version,
        allow_earlier_backwards_compatible_versions,
        allow_reresolve,
    )
    return
end

is_manifest_current(ctx::Context = Context()) = Operations.is_manifest_current(ctx.env)

const UsageDict = Dict{String,DateTime}
const UsageByDepotDict = Dict{String,UsageDict}

"""
    gc(ctx::Context=Context(); collect_delay::Period=Day(7), verbose=false, kwargs...)

Garbage-collect package and artifact installations by sweeping over all known
`Manifest.toml` and `Artifacts.toml` files, noting those that have been deleted, and then
finding artifacts and packages that are thereafter not used by any other projects,
marking them as "orphaned".  This method will only remove orphaned objects (package
versions, artifacts, and scratch spaces) that have been continually un-used for a period
of `collect_delay`; which defaults to seven days.

Garbage collection is only applied to the "user depot", e.g. the first entry in the
depot path. If you want to run `gc` on all depots set `force=true` (this might require
admin privileges depending on the setup).

Use verbose mode (`verbose=true`) for detailed output.
"""
function gc(ctx::Context=Context(); collect_delay::Period=Day(7), verbose=false, force=false, kwargs...)
    Context!(ctx; kwargs...)
    env = ctx.env

    # Only look at user-depot unless force=true
    gc_depots = force ? depots() : [depots1()]

    # First, we load in our `manifest_usage.toml` files which will tell us when our
    # "index files" (`Manifest.toml`, `Artifacts.toml`) were last used.  We will combine
    # this knowledge across depots, condensing it all down to a single entry per extant
    # index file, to manage index file growth with would otherwise continue unbounded. We
    # keep the lists of index files separated by depot so that we can write back condensed
    # versions that are only ever subsets of what we read out of them in the first place.

    # Collect last known usage dates of manifest and artifacts toml files, split by depot
    manifest_usage_by_depot = UsageByDepotDict()
    artifact_usage_by_depot = UsageByDepotDict()

    # Collect both last known usage dates, as well as parent projects for each scratch space
    scratch_usage_by_depot = UsageByDepotDict()
    scratch_parents_by_depot = Dict{String, Dict{String, Set{String}}}()

    # Load manifest files from all depots
    for depot in gc_depots
        # When a manifest/artifact.toml is installed/used, we log it within the
        # `manifest_usage.toml` files within `write_env_usage()` and `bind_artifact!()`
        function reduce_usage!(f::Function, usage_filepath)
            if !isfile(usage_filepath)
                return
            end

            for (filename, infos) in parse_toml(usage_filepath)
                f.(Ref(filename), infos)
            end
        end

        # Extract usage data from this depot, (taking only the latest state for each
        # tracked manifest/artifact.toml), then merge the usage values from each file
        # into the overall list across depots to create a single, coherent view across
        # all depots.
        usage = UsageDict()
        let usage=usage
            reduce_usage!(joinpath(logdir(depot), "manifest_usage.toml")) do filename, info
                # For Manifest usage, store only the last DateTime for each filename found
                usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"])::DateTime)
            end
        end
        manifest_usage_by_depot[depot] = usage

        usage = UsageDict()
        let usage=usage
            reduce_usage!(joinpath(logdir(depot), "artifact_usage.toml")) do filename, info
                # For Artifact usage, store only the last DateTime for each filename found
                usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"])::DateTime)
            end
        end
        artifact_usage_by_depot[depot] = usage

        # track last-used
        usage = UsageDict()
        parents = Dict{String, Set{String}}()
        let usage=usage
            reduce_usage!(joinpath(logdir(depot), "scratch_usage.toml")) do filename, info
                # For Artifact usage, store only the last DateTime for each filename found
                usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"])::DateTime)
                if !haskey(parents, filename)
                    parents[filename] = Set{String}()
                end
                for parent in info["parent_projects"]
                    push!(parents[filename], parent)
                end
            end
        end
        scratch_usage_by_depot[depot] = usage
        scratch_parents_by_depot[depot] = parents
    end

    # Next, figure out which files are still existent
    all_manifest_tomls = unique(f for (_, files) in manifest_usage_by_depot for f in keys(files))
    all_artifact_tomls = unique(f for (_, files) in artifact_usage_by_depot for f in keys(files))
    all_scratch_dirs = unique(f for (_, dirs) in scratch_usage_by_depot for f in keys(dirs))
    all_scratch_parents = Set{String}()
    for (depot, parents) in scratch_parents_by_depot
        for parent in values(parents)
            union!(all_scratch_parents, parent)
        end
    end

    all_manifest_tomls = Set(filter(Pkg.isfile_nothrow, all_manifest_tomls))
    all_artifact_tomls = Set(filter(Pkg.isfile_nothrow, all_artifact_tomls))
    all_scratch_dirs = Set(filter(Pkg.isdir_nothrow, all_scratch_dirs))
    all_scratch_parents = Set(filter(Pkg.isfile_nothrow, all_scratch_parents))

    # Immediately write these back as condensed toml files
    function write_condensed_toml(f::Function, usage_by_depot, fname)
        for (depot, usage) in usage_by_depot
            # Run through user-provided filter/condenser
            usage = f(depot, usage)

            # Write out the TOML file for this depot
            usage_path = joinpath(logdir(depot), fname)
            if !(isempty(usage)::Bool) || isfile(usage_path)
                let usage=usage
                    open(usage_path, "w") do io
                        TOML.print(io, usage, sorted=true)
                    end
                end
            end
        end
    end

    # Write condensed Manifest usage
    let all_manifest_tomls=all_manifest_tomls
        write_condensed_toml(manifest_usage_by_depot, "manifest_usage.toml") do depot, usage
            # Keep only manifest usage markers that are still existent
            let usage=usage
                filter!(((k,v),) -> k in all_manifest_tomls, usage)

                # Expand it back into a dict-of-dicts
                return Dict(k => [Dict("time" => v)] for (k, v) in usage)
            end
        end
    end

    # Write condensed Artifact usage
    let all_artifact_tomls=all_artifact_tomls
        write_condensed_toml(artifact_usage_by_depot, "artifact_usage.toml") do depot, usage
            let usage = usage
                filter!(((k,v),) -> k in all_artifact_tomls, usage)
                return Dict(k => [Dict("time" => v)] for (k, v) in usage)
            end
        end
    end

    # Write condensed scratch space usage
    let all_scratch_parents=all_scratch_parents, all_scratch_dirs=all_scratch_dirs
        write_condensed_toml(scratch_usage_by_depot, "scratch_usage.toml") do depot, usage
            # Keep only scratch directories that still exist
            filter!(((k,v),) -> k in all_scratch_dirs, usage)

            # Expand it back into a dict-of-dicts
            expanded_usage = Dict{String,Vector{Dict}}()
            for (k, v) in usage
                # Drop scratch spaces whose parents are all non-existent
                parents = scratch_parents_by_depot[depot][k]
                filter!(p -> p in all_scratch_parents, parents)
                if isempty(parents)
                    continue
                end

                expanded_usage[k] = [Dict(
                    "time" => v,
                    "parent_projects" => collect(parents),
                )]
            end
            return expanded_usage
        end
    end

    function process_manifest_pkgs(path)
        # Read the manifest in
        manifest = try
            read_manifest(path)
        catch e
            @warn "Reading manifest file at $path failed with error" exception = e
            return nothing
        end

        # Collect the locations of every package referred to in this manifest
        pkg_dir(uuid, entry) = Operations.find_installed(entry.name, uuid, entry.tree_hash)
        return [pkg_dir(u, e) for (u, e) in manifest if e.tree_hash !== nothing]
    end

    # TODO: Merge with function above to not read manifest twice?
    function process_manifest_repos(path)
        # Read the manifest in
        manifest = try
            read_manifest(path)
        catch e
            # Do not warn here, assume that `process_manifest_pkgs` has already warned
            return nothing
        end

        # Collect the locations of every repo referred to in this manifest
        return [Types.add_repo_cache_path(e.repo.source) for (u, e) in manifest if e.repo.source !== nothing]
    end

    function process_artifacts_toml(path, pkgs_to_delete)
        # Not only do we need to check if this file doesn't exist, we also need to check
        # to see if it this artifact is contained within a package that is going to go
        # away.  This places an implicit ordering between marking packages and marking
        # artifacts; the package marking must be done first so that we can ensure that
        # all artifacts that are solely bound within such packages also get reaped.
        if any(startswith(path, package_dir) for package_dir in pkgs_to_delete)
            return nothing
        end

        artifact_dict = try
            parse_toml(path)
        catch e
            @warn "Reading artifacts file at $path failed with error" exception = e
            return nothing
        end

        artifact_path_list = String[]
        for name in keys(artifact_dict)
            getpaths(meta) = artifact_paths(SHA1(hex2bytes(meta["git-tree-sha1"])))
            if isa(artifact_dict[name], Vector)
                for platform_meta in artifact_dict[name]
                    append!(artifact_path_list, getpaths(platform_meta))
                end
            else
                append!(artifact_path_list, getpaths(artifact_dict[name]))
            end
        end
        return artifact_path_list
    end

    function process_scratchspace(path, pkgs_to_delete)
        # Find all parents of this path
        parents = String[]

        # It is slightly awkward that we need to reach out to our `*_by_depot`
        # datastructures here; that's because unlike Artifacts and Manifests we're not
        # parsing a TOML file to find paths within it here, we're actually doing the
        # inverse, finding files that point to this directory.
        for (depot, parent_map) in scratch_parents_by_depot
            if haskey(parent_map, path)
                append!(parents, parent_map[path])
            end
        end

        # Look to see if all parents are packages that will be removed, if so, filter
        # this scratchspace out by returning `nothing`
        if all(any(startswith(p, dir) for dir in pkgs_to_delete) for p in parents)
            return nothing
        end
        return [path]
    end

    # Mark packages/artifacts as active or not by calling the appropriate user function
    function mark(process_func::Function, index_files, ctx::Context; do_print=true, verbose=false, file_str=nothing)
        marked_paths = String[]
        active_index_files = Set{String}()
        for index_file in index_files
            # Check to see if it's still alive
            paths = process_func(index_file)
            if paths !== nothing
                # Mark found paths, and record the index_file for printing
                push!(active_index_files, index_file)
                append!(marked_paths, paths)
            end
        end

        if do_print
            @assert file_str !== nothing
            n = length(active_index_files)
            printpkgstyle(ctx.io, :Active, "$(file_str): $(n) found")
            if verbose
                foreach(active_index_files) do f
                    println(ctx.io, "        $(pathrepr(f))")
                end
            end
        end
        # Return the list of marked paths
        return Set(marked_paths)
    end

    gc_time = now()
    function merge_orphanages!(new_orphanage, paths, deletion_list, old_orphanage = UsageDict())
        for path in paths
            free_time = something(
                get(old_orphanage, path, nothing),
                gc_time,
            )

            # No matter what, store the free time in the new orphanage. This allows
            # something terrible to go wrong while trying to delete the artifact/
            # package and it will still try to be deleted next time.  The only time
            # something is removed from an orphanage is when it didn't exist before
            # we even started the `gc` run.
            new_orphanage[path] = free_time

            # If this path was orphaned long enough ago, add it to the deletion list.
            # Otherwise, we continue to propagate its orphaning date but don't delete
            # it.  It will get cleaned up at some future `gc`, or it will be used
            # again during a future `gc` in which case it will not persist within the
            # orphanage list.
            if gc_time - free_time >= collect_delay
                push!(deletion_list, path)
            end
        end
    end


    # Scan manifests, parse them, read in all UUIDs listed and mark those as active
    # printpkgstyle(ctx.io, :Active, "manifests:")
    packages_to_keep = mark(process_manifest_pkgs, all_manifest_tomls, ctx,
        verbose=verbose, file_str="manifest files")

    # Do an initial scan of our depots to get a preliminary `packages_to_delete`.
    packages_to_delete = String[]
    for depot in gc_depots
        depot_orphaned_packages = String[]
        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                !isdir(joinpath(packagedir, name)) && continue

                for slug in readdir(joinpath(packagedir, name))
                    pkg_dir = joinpath(packagedir, name, slug)
                    !isdir(pkg_dir) && continue

                    if !(pkg_dir in packages_to_keep)
                        push!(depot_orphaned_packages, pkg_dir)
                    end
                end
            end
        end
        merge_orphanages!(UsageDict(), depot_orphaned_packages, packages_to_delete)
    end


    # Next, do the same for artifacts.  Note that we MUST do this after calculating
    # `packages_to_delete`, as `process_artifacts_toml()` uses it internally to discount
    # `Artifacts.toml` files that will be deleted by the future culling operation.
    # printpkgstyle(ctx.io, :Active, "artifacts:")
    artifacts_to_keep = let packages_to_delete=packages_to_delete
        mark(x -> process_artifacts_toml(x, packages_to_delete),
             all_artifact_tomls, ctx; verbose=verbose, file_str="artifact files")
    end
    repos_to_keep = mark(process_manifest_repos, all_manifest_tomls, ctx; do_print=false)
    # printpkgstyle(ctx.io, :Active, "scratchspaces:")
    spaces_to_keep = let packages_to_delete=packages_to_delete
        mark(x -> process_scratchspace(x, packages_to_delete),
             all_scratch_dirs, ctx; verbose=verbose, file_str="scratchspaces")
    end

    # Collect all orphaned paths (packages, artifacts and repos that are not reachable).  These
    # are implicitly defined in that we walk all packages/artifacts installed, then if
    # they were not marked in the above steps, we reap them.
    packages_to_delete = String[]
    artifacts_to_delete = String[]
    repos_to_delete = String[]
    spaces_to_delete = String[]

    for depot in gc_depots
        # We track orphaned objects on a per-depot basis, writing out our `orphaned.toml`
        # tracking file immediately, only pushing onto the overall `*_to_delete` lists if
        # the package has been orphaned for at least a period of `collect_delay`
        depot_orphaned_packages = String[]
        depot_orphaned_artifacts = String[]
        depot_orphaned_repos = String[]
        depot_orphaned_scratchspaces = String[]

        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                !isdir(joinpath(packagedir, name)) && continue

                for slug in readdir(joinpath(packagedir, name))
                    pkg_dir = joinpath(packagedir, name, slug)
                    !isdir(pkg_dir) && continue

                    if !(pkg_dir in packages_to_keep)
                        push!(depot_orphaned_packages, pkg_dir)
                    end
                end
            end
        end

        reposdir = abspath(depot, "clones")
        if isdir(reposdir)
            for repo in readdir(reposdir)
                repo_dir = joinpath(reposdir, repo)
                !isdir(repo_dir) && continue
                if !(repo_dir in repos_to_keep)
                    push!(depot_orphaned_repos, repo_dir)
                end
            end
        end

        artifactsdir = abspath(depot, "artifacts")
        if isdir(artifactsdir)
            for hash in readdir(artifactsdir)
                artifact_path = joinpath(artifactsdir, hash)
                !isdir(artifact_path) && continue

                if !(artifact_path in artifacts_to_keep)
                    push!(depot_orphaned_artifacts, artifact_path)
                end
            end
        end

        scratchdir = abspath(depot, "scratchspaces")
        if isdir(scratchdir)
            for uuid in readdir(scratchdir)
                uuid_dir = joinpath(scratchdir, uuid)
                !isdir(uuid_dir) && continue
                for space in readdir(uuid_dir)
                    space_dir_or_file = joinpath(uuid_dir, space)
                    if isdir(space_dir_or_file)
                        if !(space_dir_or_file in spaces_to_keep)
                            push!(depot_orphaned_scratchspaces, space_dir_or_file)
                        end
                    elseif uuid == Operations.PkgUUID && isfile(space_dir_or_file)
                        # special cleanup for the precompile cache files that Pkg saves
                        if any(prefix->startswith(basename(space_dir_or_file), prefix), ("suspend_cache_", "pending_cache_"))
                            if mtime(space_dir_or_file) < (time() - (24*60*60))
                                push!(depot_orphaned_scratchspaces, space_dir_or_file)
                            end
                        end
                    end
                end
            end
        end

        # Read in this depot's `orphaned.toml` file:
        orphanage_file = joinpath(logdir(depot), "orphaned.toml")
        new_orphanage = UsageDict()
        old_orphanage = try
            TOML.parse(String(read(orphanage_file)))
        catch
            UsageDict()
        end

        # Update the package and artifact lists of things to delete, and
        # create the `new_orphanage` list for this depot.
        merge_orphanages!(new_orphanage, depot_orphaned_packages, packages_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_artifacts, artifacts_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_repos, repos_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_scratchspaces, spaces_to_delete, old_orphanage)

        # Write out the `new_orphanage` for this depot
        mkpath(dirname(orphanage_file))
        open(orphanage_file, "w") do io
            TOML.print(io, new_orphanage, sorted=true)
        end
    end

    # Next, we calculate the space savings we're about to gain!
    pretty_byte_str = (size) -> begin
        bytes, mb = Base.prettyprint_getunits(size, length(Base._mem_units), Int64(1024))
        return @sprintf("%.3f %s", bytes, Base._mem_units[mb])
    end

    function recursive_dir_size(path)
        size = 0
        try
            for (root, dirs, files) in walkdir(path)
                for file in files
                    path = joinpath(root, file)
                    try
                        size += lstat(path).size
                    catch ex
                        @error("Failed to calculate size of $path", exception=ex)
                    end
                end
            end
        catch ex
            @error("Failed to calculate size of $path", exception=ex)
        end
        return size
    end

    # Delete paths for unreachable package versions and artifacts, and computing size saved
    function delete_path(path)
        path_size = if isfile(path)
            try
                lstat(path).size
            catch ex
                @error("Failed to calculate size of $path", exception=ex)
                0
            end
        else
            recursive_dir_size(path)
        end
        try
            Base.Filesystem.prepare_for_deletion(path)
            Base.rm(path; recursive=true, force=true)
        catch e
            @warn("Failed to delete $path", exception=e)
            return 0
        end
        if verbose
            printpkgstyle(ctx.io, :Deleted, pathrepr(path) * " (" *
                pretty_byte_str(path_size) * ")")
        end
        return path_size
    end

    package_space_freed = 0
    repo_space_freed = 0
    artifact_space_freed = 0
    scratch_space_freed = 0
    for path in packages_to_delete
        package_space_freed += delete_path(path)
    end
    for path in repos_to_delete
        repo_space_freed += delete_path(path)
    end
    for path in artifacts_to_delete
        artifact_space_freed += delete_path(path)
    end
    for path in spaces_to_delete
        scratch_space_freed += delete_path(path)
    end

    # Prune package paths that are now empty
    for depot in gc_depots
        packagedir = abspath(depot, "packages")
        !isdir(packagedir) && continue

        for name in readdir(packagedir)
            name_path = joinpath(packagedir, name)
            !isdir(name_path) && continue
            !isempty(readdir(name_path)) && continue

            Base.rm(name_path)
        end
    end

    # Prune scratch space UUID folders that are now empty
    for depot in gc_depots
        scratch_dir = abspath(depot, "scratchspaces")
        !isdir(scratch_dir) && continue

        for uuid in readdir(scratch_dir)
            uuid_dir = joinpath(scratch_dir, uuid)
            !isdir(uuid_dir) && continue
            if isempty(readdir(uuid_dir))
                Base.rm(uuid_dir)
            end
        end
    end

    ndel_pkg = length(packages_to_delete)
    ndel_repo = length(repos_to_delete)
    ndel_art = length(artifacts_to_delete)
    ndel_space = length(spaces_to_delete)

    function print_deleted(ndel, freed, name)
        if ndel <= 0
            return
        end

        s = ndel == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(freed)
        printpkgstyle(ctx.io, :Deleted, "$(ndel) $(name)$(s) ($bytes_saved_string)")
    end
    print_deleted(ndel_pkg, package_space_freed, "package installation")
    print_deleted(ndel_repo, repo_space_freed, "repo")
    print_deleted(ndel_art, artifact_space_freed, "artifact installation")
    print_deleted(ndel_space, scratch_space_freed, "scratchspace")

    if ndel_pkg == 0 && ndel_art == 0 && ndel_repo == 0 && ndel_space == 0
        printpkgstyle(ctx.io, :Deleted, "no artifacts, repos, packages or scratchspaces")
    end

    return
end

function build(ctx::Context, pkgs::Vector{PackageSpec}; verbose=false, kwargs...)
    Context!(ctx; kwargs...)

    if isempty(pkgs)
        if ctx.env.pkg !== nothing
            push!(pkgs, ctx.env.pkg)
        else
            for (uuid, entry) in ctx.env.manifest
                push!(pkgs, PackageSpec(entry.name, uuid))
            end
        end
    end
    project_resolve!(ctx.env, pkgs)
    manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)
    Operations.build(ctx, Set{UUID}(pkg.uuid for pkg in pkgs), verbose)
end

function get_or_make_pkgspec(pkgspecs::Vector{PackageSpec}, ctx::Context, uuid)
    i = findfirst(ps -> ps.uuid == uuid, pkgspecs)
    if !isnothing(i)
        return pkgspecs[i]
    elseif !isnothing(ctx.env.pkg) && uuid == ctx.env.pkg.uuid
        # uuid is of the active Project
        return ctx.env.pkg
    elseif haskey(ctx.env.manifest, uuid)
        pkgent = ctx.env.manifest[uuid]
        # If we have an unusual situation such as an un-versioned package (like an stdlib that
        # is being overridden) its `version` may be `nothing`.
        pkgver = something(pkgent.version, VersionSpec())
        return PackageSpec(uuid = uuid, name = pkgent.name, version = pkgver, tree_hash = pkgent.tree_hash)
    else
        # this branch should never be hit, so if it is throw a regular error with a stacktrace
        error("UUID $uuid not found. It does not match the Project uuid nor any dependency")
    end
end

function full_name(ext_to_parent::Dict{Base.PkgId, String}, pkg::Base.PkgId)
    if haskey(ext_to_parent, pkg)
        return string(ext_to_parent[pkg], " → ", pkg.name)
    else
        return pkg.name
    end
end

function excluded_circular_deps_explanation(io::IOContext{<:IO}, ext_to_parent::Dict{Base.PkgId, String}, circular_deps, cycles)
    outer_deps = copy(circular_deps)
    cycles_names = ""
    for cycle in cycles
        filter!(!in(cycle), outer_deps)
        cycle_str = ""
        for (i, pkg) in enumerate(cycle)
            j = max(0, i - 1)
            if length(cycle) == 1
                line = " ─ "
            elseif i == 1
                line = " ┌ "
            elseif i < length(cycle)
                line = " │ " * " " ^j
            else
                line = " └" * "─" ^j * " "
            end
            hascolor = get(io, :color, false)::Bool
            line = _color_string(line, :light_black, hascolor) * full_name(ext_to_parent, pkg) * "\n"
            cycle_str *= line
        end
        cycles_names *= cycle_str
    end
    plural1 = length(cycles) > 1 ? "these cycles" : "this cycle"
    plural2 = length(cycles) > 1 ? "cycles" : "cycle"
    msg = """Circular dependency detected.
    Precompilation will be skipped for dependencies in $plural1:
    $cycles_names"""
    if !isempty(outer_deps)
        msg *= "Precompilation will also be skipped for the following, which depend on the above $plural2:\n"
        msg *= join(("  " * full_name(ext_to_parent, pkg) for pkg in outer_deps), "\n")
    end
    return msg
end

function precompile(ctx::Context, pkgs::Vector{PackageSpec}; internal_call::Bool=false,
                    strict::Bool=false, warn_loaded = true, already_instantiated = false, timing::Bool = false,
                    _from_loading::Bool=false, kwargs...)
    Context!(ctx; kwargs...)
    already_instantiated || instantiate(ctx; allow_autoprecomp=false, kwargs...)
    time_start = time_ns()

    # Windows sometimes hits a ReadOnlyMemoryError, so we halve the default number of tasks. Issue #2323
    # TODO: Investigate why this happens in windows and restore the full task limit
    default_num_tasks = Sys.iswindows() ? div(Sys.CPU_THREADS::Int, 2) + 1 : Sys.CPU_THREADS::Int + 1
    default_num_tasks = min(default_num_tasks, 16) # limit for better stability on shared resource systems

    num_tasks = parse(Int, get(ENV, "JULIA_NUM_PRECOMPILE_TASKS", string(default_num_tasks)))
    parallel_limiter = Base.Semaphore(num_tasks)
    io = IOContext(ctx.io)
    fancyprint = can_fancyprint(io) && !timing

    hascolor = get(io, :color, false)::Bool
    color_string(cstr::String, col::Union{Int64, Symbol}) = _color_string(cstr, col, hascolor)

    recall_precompile_state() # recall suspended and force-queued packages
    !internal_call && precomp_unsuspend!() # when manually called, unsuspend all packages that were suspended due to precomp errors

    direct_deps = [
        Base.PkgId(uuid, name)
        for (name, uuid) in ctx.env.project.deps if !Base.in_sysimage(Base.PkgId(uuid, name))
    ]
    stale_cache = Dict{StaleCacheKey, Bool}()
    exts = Dict{Base.PkgId, String}() # ext -> parent
    # make a flat map of each dep and its direct deps
    depsmap = Dict{Base.PkgId, Vector{Base.PkgId}}()
    pkg_specs = PackageSpec[]
    pkg_exts_map = Dict{Base.PkgId, Vector{Base.PkgId}}()
    for dep in ctx.env.manifest
        pkg = Base.PkgId(first(dep), last(dep).name)
        Base.in_sysimage(pkg) && continue
        deps = [Base.PkgId(last(x), first(x)) for x in last(dep).deps]
        depsmap[pkg] = filter!(!Base.in_sysimage, deps)
        # add any extensions
        weakdeps = last(dep).weakdeps
        pkg_exts = Dict{Base.PkgId, Vector{Base.PkgId}}()
        for (ext_name, extdep_names) in last(dep).exts
            ext_deps = Base.PkgId[]
            push!(ext_deps, pkg) # depends on parent package
            all_extdeps_available = true
            extdep_names = extdep_names isa String ? String[extdep_names] : extdep_names
            for extdep_name in extdep_names
                extdep_uuid = weakdeps[extdep_name]
                if extdep_uuid in keys(ctx.env.manifest.deps) || Base.in_sysimage(Base.PkgId(extdep_uuid, extdep_name))
                    push!(ext_deps, Base.PkgId(extdep_uuid, extdep_name))
                else
                    all_extdeps_available = false
                    break
                end
            end
            all_extdeps_available || continue
            ext_uuid = Base.uuid5(pkg.uuid, ext_name)
            ext = Base.PkgId(ext_uuid, ext_name)
            push!(pkg_specs, PackageSpec(uuid = ext_uuid, name = ext_name)) # create this here as the name cannot be looked up easily later via the uuid
            filter!(!Base.in_sysimage, ext_deps)
            depsmap[ext] = ext_deps
            exts[ext] = pkg.name
            pkg_exts[ext] = ext_deps
        end
        if !isempty(pkg_exts)
            pkg_exts_map[pkg] = collect(keys(pkg_exts))
        end
    end

    # A package/extension effectively depends on another extension if it (transitively)
    # has all the dependencies of that other extension
    function expand_indirect_dependencies(direct_deps)
        function visit!(visited, node, all_deps)
            if node in visited
                return
            end
            push!(visited, node)
            for dep in get(Set{Base.PkgId}, direct_deps, node)
                if !(dep in all_deps)
                    push!(all_deps, dep)
                    visit!(visited, dep, all_deps)
                end
            end
        end

        indirect_deps = Dict{Base.PkgId, Set{Base.PkgId}}()
        for package in keys(direct_deps)
            # Initialize a set to keep track of all dependencies for 'package'
            all_deps = Set{Base.PkgId}()
            visited = Set{Base.PkgId}()
            visit!(visited, package, all_deps)
            # Update indirect_deps with the complete set of dependencies for 'package'
            indirect_deps[package] = all_deps
        end
        return indirect_deps
    end

    indirect_deps = expand_indirect_dependencies(depsmap)

    # this loop must be run after the full depsmap has been populated
    ext_loadable_by = Dict{Base.PkgId,Set{Base.PkgId}}()
    for ext in keys(exts)
        ext_loadable_by[ext] = Set{Base.PkgId}()
        for pkg in keys(depsmap)
            pkg === ext && continue
            is_trigger = in(pkg, depsmap[ext])
            has_triggers = issubset(depsmap[ext], indirect_deps[pkg])
            # In contrast to 1.11+, on 1.10 both "pkg → ext" and "ext → ext" dependency edges
            # are implied based on transitive dependencies.
            #
            # This condition is inconsistent for "ext → ext" edges, leading to dependency
            # cycles on 1.10, but this behavior is intentionally preserved for now to avoid
            # breaking packages that depend on this (bad) implicit behavior.
            #
            # See https://github.com/JuliaLang/julia/issues/56204#issuecomment-2442652997
            # for the improved behavior this was replaced with in 1.11
            if has_triggers && !is_trigger
                push!(ext_loadable_by[ext], pkg)
            end
        end
    end
    for (ext, loadable_by) in ext_loadable_by
        for pkg in loadable_by
            if !any(in(loadable_by), depsmap[pkg])
                # add an edge if the extension is loadable by pkg, and was not loadable in any
                # of the pkg's dependencies
                push!(depsmap[pkg], ext)
            end
        end
    end

    # if the active environment is a package, add that
    ctx_env_pkg = ctx.env.pkg
    if ctx_env_pkg !== nothing && isfile(joinpath(dirname(ctx.env.project_file), "src", "$(ctx_env_pkg.name).jl"))
        project_pkgid = Base.PkgId(ctx_env_pkg.uuid, ctx_env_pkg.name)
        depsmap[project_pkgid] = [
            Base.PkgId(last(x), first(x))
            for x in ctx.env.project.deps if !Base.in_sysimage(Base.PkgId(last(x), first(x)))
        ]
        push!(direct_deps, Base.PkgId(ctx_env_pkg.uuid, ctx_env_pkg.name))
    else
        project_pkgid = nothing
    end

    # return early if no deps
    if isempty(depsmap)
        if isempty(pkgs)
            return
        elseif _from_loading
            # if called from loading precompilation it may be a package from another environment stack so
            # don't error and allow serial precompilation to try
            # TODO: actually handle packages from other envs in the stack
            return
        else
            pkgerror("No direct dependencies outside of the sysimage found matching $(repr([p.name for p in pkgs]))")
        end
    end

    # initialize signalling
    started = Dict{Base.PkgId,Bool}()
    was_processed = Dict{Base.PkgId,Base.Event}()
    was_recompiled = Dict{Base.PkgId,Bool}()
    for pkgid in keys(depsmap)
        started[pkgid] = false
        was_processed[pkgid] = Base.Event()
        was_recompiled[pkgid] = false
        push!(pkg_specs, get_or_make_pkgspec(pkg_specs, ctx, pkgid.uuid))
    end

    # remove packages that are suspended because they errored before
    # note that when `Pkg.precompile` is manually called, all suspended packages are unsuspended
    precomp_prune_suspended!(pkg_specs)

    # find and guard against circular deps
    cycles = Vector{Base.PkgId}[]
    # For every scanned package, true if pkg found to be in a cycle
    # or depends on packages in a cycle and false otherwise.
    could_be_cycle = Dict{Base.PkgId, Bool}()
    # temporary stack for the SCC-like algorithm below
    stack = Base.PkgId[]
    function scan_pkg!(pkg, dmap)
        if haskey(could_be_cycle, pkg)
            return could_be_cycle[pkg]
        else
            return scan_deps!(pkg, dmap)
        end
    end
    function scan_deps!(pkg, dmap)
        push!(stack, pkg)
        cycle = nothing
        for dep in dmap[pkg]
            if dep in stack
                # Created fresh cycle
                cycle′ = stack[findlast(==(dep), stack):end]
                if cycle === nothing || length(cycle′) < length(cycle)
                    cycle = cycle′ # try to report smallest cycle possible
                end
            elseif scan_pkg!(dep, dmap)
                # Reaches an existing cycle
                could_be_cycle[pkg] = true
                pop!(stack)
                return true
            end
        end
        pop!(stack)
        if cycle !== nothing
            push!(cycles, cycle)
            could_be_cycle[pkg] = true
            return true
        end
        could_be_cycle[pkg] = false
        return false
    end
    # set of packages that depend on a cycle (either because they are
    # a part of a cycle themselves or because they transitively depend
    # on a package in some cycle)
    circular_deps = Base.PkgId[]
    for pkg in keys(depsmap)
        @assert isempty(stack)
        if scan_pkg!(pkg, depsmap)
            push!(circular_deps, pkg)
            notify(was_processed[pkg])
        end
    end
    if !isempty(circular_deps)
        @warn excluded_circular_deps_explanation(io, exts, circular_deps, cycles)
    end

    # if a list of packages is given, restrict to dependencies of given packages
    if !isempty(pkgs)
        pkgs_names = [p.name for p in pkgs]
        function collect_all_deps(depsmap, dep, alldeps=Set{Base.PkgId}())
            for _dep in depsmap[dep]
                if !(_dep in alldeps)
                    push!(alldeps, _dep)
                    collect_all_deps(depsmap, _dep, alldeps)
                end
            end
            return alldeps
        end
        keep = Set{Base.PkgId}()
        for dep in depsmap
            dep_pkgid = first(dep)
            if dep_pkgid.name in pkgs_names
                push!(keep, dep_pkgid)
                collect_all_deps(depsmap, dep_pkgid, keep)
            end
        end
        for ext in keys(exts)
            if issubset(collect_all_deps(depsmap, ext), keep) # if all extension deps are kept
                push!(keep, ext)
            end
        end
        filter!(d->in(first(d), keep), depsmap)
        if isempty(depsmap)
            if _from_loading
                # if called from loading precompilation it may be a package from another environment stack so
                # don't error and allow serial precompilation to try
                # TODO: actually handle packages from other envs in the stack
                return
            else
                pkgerror("No direct dependencies outside of the sysimage found matching $(repr(pkgs_names))")
            end
        end
        target = join(pkgs_names, ", ")
    else
        target = "project..."
    end

    pkg_queue = Base.PkgId[]
    failed_deps = Dict{Base.PkgId, String}()
    skipped_deps = Base.PkgId[]
    precomperr_deps = Base.PkgId[] # packages that may succeed after a restart (i.e. loaded packages with no cache file)

    print_lock = ctx.io isa Base.LibuvStream ? ctx.io.lock::ReentrantLock : ReentrantLock()
    first_started = Base.Event()
    printloop_should_exit::Bool = !fancyprint # exit print loop immediately if not fancy printing
    interrupted_or_done = Base.Event()

    ansi_moveup(n::Int) = string("\e[", n, "A")
    ansi_movecol1 = "\e[1G"
    ansi_cleartoend = "\e[0J"
    ansi_cleartoendofline = "\e[0K"
    ansi_enablecursor = "\e[?25h"
    ansi_disablecursor = "\e[?25l"
    n_done::Int = 0
    n_already_precomp::Int = 0
    n_loaded::Int = 0
    interrupted = false

    function handle_interrupt(err, in_printloop = false)
        notify(interrupted_or_done)
        in_printloop || wait(t_print) # wait to let the print loop cease first
        if err isa InterruptException
            lock(print_lock) do
                println(io, " Interrupted: Exiting precompilation...")
            end
            interrupted = true
            return true
        else
            return false
        end
    end

    std_outputs = Dict{Base.PkgId,String}()
    taskwaiting = Set{Base.PkgId}()
    pkgspidlocked = Dict{Base.PkgId,String}()
    pkg_liveprinted = nothing

    function monitor_std(pkg, pipe; single_requested_pkg=false)
        try
            liveprinting = false
            while !eof(pipe)
                str = readline(pipe, keep=true)
                if single_requested_pkg && (liveprinting || !isempty(str))
                    lock(print_lock) do
                        if !liveprinting
                            printpkgstyle(io, :Info, "Given $(pkg.name) was explicitly requested, output will be shown live $ansi_cleartoendofline",
                                color = Base.info_color())
                            liveprinting = true
                            pkg_liveprinted = pkg
                        end
                        print(io, ansi_cleartoendofline, str)
                    end
                end
                std_outputs[pkg] = string(get(std_outputs, pkg, ""), str)
                if !in(pkg, taskwaiting) && occursin("waiting for IO to finish", str)
                    !fancyprint && lock(print_lock) do
                        println(io, pkg.name, color_string(" Waiting for background task / IO / timer.", Base.warn_color()))
                    end
                    push!(taskwaiting, pkg)
                end
                if !fancyprint && in(pkg, taskwaiting)
                    lock(print_lock) do
                        print(io, str)
                    end
                end
            end
        catch err
            err isa InterruptException || rethrow()
        end
    end

    ## fancy print loop
    t_print = @async begin
        try
            wait(first_started)
            (isempty(pkg_queue) || interrupted_or_done.set) && return
            fancyprint && lock(print_lock) do
                printpkgstyle(io, :Precompiling, target)
                print(io, ansi_disablecursor)
            end
            t = Timer(0; interval=1/10)
            anim_chars = ["◐","◓","◑","◒"]
            i = 1
            last_length = 0
            bar = MiniProgressBar(; indent=2, header = "Progress", color = Base.info_color(), percentage=false, always_reprint=true)
            n_total = length(depsmap)
            bar.max = n_total - n_already_precomp
            final_loop = false
            n_print_rows = 0
            while !printloop_should_exit
                lock(print_lock) do
                    term_size = Base.displaysize(ctx.io)::Tuple{Int,Int}
                    num_deps_show = max(term_size[1] - 3, 2) # show at least 2 deps
                    pkg_queue_show = if !interrupted_or_done.set && length(pkg_queue) > num_deps_show
                        last(pkg_queue, num_deps_show)
                    else
                        pkg_queue
                    end
                    str_ = sprint() do iostr
                        if i > 1
                            print(iostr, ansi_cleartoend)
                        end
                        bar.current = n_done - n_already_precomp
                        bar.max = n_total - n_already_precomp
                        # when sizing to the terminal width subtract a little to give some tolerance to resizing the
                        # window between print cycles
                        termwidth = displaysize(io)[2] - 4
                        if !final_loop
                            str = sprint(io -> show_progress(io, bar; termwidth, carriagereturn=false); context=io)
                            print(iostr, Base._truncate_at_width_or_chars(true, str, termwidth), "\n")
                        end
                        for dep in pkg_queue_show
                            loaded = warn_loaded && haskey(Base.loaded_modules, dep)
                            _name = full_name(exts, dep)
                            name = dep in direct_deps ? _name : string(color_string(_name, :light_black))
                            line = if dep in precomperr_deps
                                string(color_string("  ? ", Base.warn_color()), name)
                            elseif haskey(failed_deps, dep)
                                string(color_string("  ✗ ", Base.error_color()), name)
                            elseif was_recompiled[dep]
                                !loaded && interrupted_or_done.set && continue
                                loaded || @async begin # keep successful deps visible for short period
                                    sleep(1);
                                    filter!(!isequal(dep), pkg_queue)
                                end
                                string(color_string("  ✓ ", loaded ? Base.warn_color() : :green), name)
                            elseif started[dep]
                                # Offset each spinner animation using the first character in the package name as the seed.
                                # If not offset, on larger terminal fonts it looks odd that they all sync-up
                                anim_char = anim_chars[(i + Int(dep.name[1])) % length(anim_chars) + 1]
                                anim_char_colored = dep in direct_deps ? anim_char : color_string(anim_char, :light_black)
                                waiting = if haskey(pkgspidlocked, dep)
                                    who_has_lock = pkgspidlocked[dep]
                                    color_string(" Being precompiled by $(who_has_lock)", Base.info_color())
                                elseif dep in taskwaiting
                                    color_string(" Waiting for background task / IO / timer. Interrupt to inspect", Base.warn_color())
                                else
                                    ""
                                end
                                string("  ", anim_char_colored, " ", name, waiting)
                            else
                                string("    ", name)
                            end
                            println(iostr, Base._truncate_at_width_or_chars(true, line, termwidth))
                        end
                    end
                    last_length = length(pkg_queue_show)
                    n_print_rows = count("\n", str_)
                    print(io, str_)
                    printloop_should_exit = interrupted_or_done.set && final_loop
                    final_loop = interrupted_or_done.set # ensures one more loop to tidy last task after finish
                    i += 1
                    printloop_should_exit || print(io, ansi_moveup(n_print_rows), ansi_movecol1)
                end
                wait(t)
            end
        catch err
            handle_interrupt(err, true) || rethrow()
        finally
            fancyprint && print(io, ansi_enablecursor)
        end
    end
    tasks = Task[]
    if !_from_loading
        Base.LOADING_CACHE[] = Base.LoadingCache()
    end
    ## precompilation loop
    for (pkg, deps) in depsmap
        cachepaths = Base.find_all_in_cache_path(pkg)
        sourcepath = Base.locate_package(pkg)
        if sourcepath === nothing
            failed_deps[pkg] = "Error: Missing source file for $(pkg)"
            notify(was_processed[pkg])
            continue
        end
        # Heuristic for when precompilation is disabled
        if occursin(r"\b__precompile__\(\s*false\s*\)", read(sourcepath, String))
            notify(was_processed[pkg])
            continue
        end

        single_requested_pkg = if length(pkgs) == 1
            only(pkgs).name == pkg.name
        elseif project_pkgid isa Base.PkgId
            pkg == project_pkgid # if a package project is being precompiled, consider the package requested
        else
            false
        end

        task = @async begin
            try
                loaded = haskey(Base.loaded_modules, pkg)
                for dep in deps # wait for deps to finish
                    wait(was_processed[dep])
                end

                pkgspec = get_or_make_pkgspec(pkg_specs, ctx, pkg.uuid)
                suspended = precomp_suspended(pkgspec)
                queued = precomp_queued(pkgspec)

                circular = pkg in circular_deps
                is_stale = true
                if !circular && (queued || (!suspended && (is_stale = !Base.isprecompiled(pkg; ignore_loaded=true, stale_cache, cachepaths, sourcepath))))
                    Base.acquire(parallel_limiter)
                    is_direct_dep = pkg in direct_deps

                    # std monitoring
                    std_pipe = Base.link_pipe!(Pipe(); reader_supports_async=true, writer_supports_async=true)
                    t_monitor = @async monitor_std(pkg, std_pipe; single_requested_pkg)

                    _name = full_name(exts, pkg)
                    name = is_direct_dep ? _name : string(color_string(_name, :light_black))
                    !fancyprint && lock(print_lock) do
                        isempty(pkg_queue) && printpkgstyle(io, :Precompiling, target)
                    end
                    push!(pkg_queue, pkg)
                    started[pkg] = true
                    fancyprint && notify(first_started)
                    if interrupted_or_done.set
                        notify(was_processed[pkg])
                        Base.release(parallel_limiter)
                        return
                    end
                    try
                        # allows processes to wait if another process is precompiling a given package to
                        # a functionally identical package cache (except for preferences, which may differ)
                        t = @elapsed ret = maybe_cachefile_lock(io, print_lock, fancyprint, pkg, pkgspidlocked, hascolor) do
                            Logging.with_logger(Logging.NullLogger()) do
                                # The false here means we ignore loaded modules, so precompile for a fresh session
                                Base.compilecache(pkg, sourcepath, std_pipe, std_pipe, false)
                            end
                        end
                        t_str = timing ? string(lpad(round(t * 1e3, digits = 1), 9), " ms") : ""
                        if ret isa Base.PrecompilableError
                            push!(precomperr_deps, pkg)
                            precomp_queue!(get_or_make_pkgspec(pkg_specs, ctx, pkg.uuid))
                            !fancyprint && lock(print_lock) do
                                println(io, t_str, color_string("  ? ", Base.warn_color()), name)
                            end
                        else
                            queued && precomp_dequeue!(get_or_make_pkgspec(pkg_specs, ctx, pkg.uuid))
                            !fancyprint && lock(print_lock) do
                                println(io, t_str, color_string("  ✓ ", loaded ? Base.warn_color() : :green), name)
                            end
                            was_recompiled[pkg] = true
                        end
                        loaded && (n_loaded += 1)
                    catch err
                        close(std_pipe.in) # close pipe to end the std output monitor
                        wait(t_monitor)
                        if err isa ErrorException || (err isa ArgumentError && startswith(err.msg, "Invalid header in cache file"))
                            failed_deps[pkg] = (strict || is_direct_dep) ? string(sprint(showerror, err), "\n", strip(get(std_outputs, pkg, ""))) : ""
                            delete!(std_outputs, pkg) # so it's not shown as warnings, given error report
                            !fancyprint && lock(print_lock) do
                                println(io, timing ? " "^9 : "", color_string("  ✗ ", Base.error_color()), name)
                            end
                            queued && precomp_dequeue!(get_or_make_pkgspec(pkg_specs, ctx, pkg.uuid))
                            precomp_suspend!(get_or_make_pkgspec(pkg_specs, ctx, pkg.uuid))
                        else
                            rethrow()
                        end
                    finally
                        isopen(std_pipe.in) && close(std_pipe.in) # close pipe to end the std output monitor
                        wait(t_monitor)
                        Base.release(parallel_limiter)
                    end
                else
                    is_stale || (n_already_precomp += 1)
                    suspended && push!(skipped_deps, pkg)
                end
                n_done += 1
                notify(was_processed[pkg])
            catch err_outer
                handle_interrupt(err_outer) || rethrow()
                notify(was_processed[pkg])
            finally
                filter!(!istaskdone, tasks)
                length(tasks) == 1 && notify(interrupted_or_done)
            end
        end
        Base.errormonitor(task) # interrupts are handled separately so ok to watch for other errors like this
        push!(tasks, task)
    end
    isempty(tasks) && notify(interrupted_or_done)
    try
        wait(interrupted_or_done)
    catch err
        handle_interrupt(err) || rethrow()
    finally
        Base.LOADING_CACHE[] = nothing
    end
    notify(first_started) # in cases of no-op or !fancyprint
    save_precompile_state() # save lists to scratch space
    fancyprint && wait(t_print)
    quick_exit = !all(istaskdone, tasks) || interrupted # if some not finished internal error is likely
    seconds_elapsed = round(Int, (time_ns() - time_start) / 1e9)
    ndeps = count(values(was_recompiled))
    if ndeps > 0 || !isempty(failed_deps) || (quick_exit && !isempty(std_outputs))
        str = sprint() do iostr
            if !quick_exit
                plural = ndeps == 1 ? "y" : "ies"
                print(iostr, "  $(ndeps) dependenc$(plural) successfully precompiled in $(seconds_elapsed) seconds")
                if n_already_precomp > 0 || !isempty(circular_deps) || !isempty(skipped_deps)
                    n_already_precomp > 0 && (print(iostr, ". $n_already_precomp already precompiled"))
                    !isempty(circular_deps) && (print(iostr, ". $(length(circular_deps)) skipped due to circular dependency"))
                    !isempty(skipped_deps) && (print(iostr, ". $(length(skipped_deps)) skipped during auto due to previous errors"))
                    print(iostr, ".")
                end
                if n_loaded > 0
                    plural1 = n_loaded == 1 ? "y" : "ies"
                    plural2 = n_loaded == 1 ? "a different version is" : "different versions are"
                    plural3 = n_loaded == 1 ? "" : "s"
                    print(iostr, "\n  ",
                        color_string(string(n_loaded), Base.warn_color()),
                        " dependenc$(plural1) precompiled but $(plural2) currently loaded. Restart julia to access the new version$(plural3)"
                    )
                end
                if !isempty(precomperr_deps)
                    pluralpc = length(precomperr_deps) == 1 ? "y" : "ies"
                    print(iostr, "\n  ",
                        color_string(string(length(precomperr_deps)), Base.warn_color()),
                        " dependenc$(pluralpc) failed but may be precompilable after restarting julia"
                    )
                end
            end
            # show any stderr output, even if Pkg.precompile has been interrupted (quick_exit=true), given user may be
            # interrupting a hanging precompile job with stderr output. julia#48371
            filter!(kv -> !isempty(strip(last(kv))), std_outputs) # remove empty output
            if !isempty(std_outputs)
                plural1 = length(std_outputs) == 1 ? "y" : "ies"
                plural2 = length(std_outputs) == 1 ? "" : "s"
                print(iostr, "\n  ", color_string("$(length(std_outputs))", Base.warn_color()), " dependenc$(plural1) had output during precompilation:")
                for (pkgid, err) in std_outputs
                    err = if pkgid == pkg_liveprinted
                        "[Output was shown above]"
                    else
                        join(split(strip(err), "\n"), color_string("\n│  ", Base.warn_color()))
                    end
                    name = haskey(exts, pkgid) ? string(exts[pkgid], " → ", pkgid.name) : pkgid.name
                    print(iostr, color_string("\n┌ ", Base.warn_color()), name, color_string("\n│  ", Base.warn_color()), err, color_string("\n└  ", Base.warn_color()))
                end
            end
        end
        let str=str
            lock(print_lock) do
                println(io, str)
            end
        end
        quick_exit && return
        err_str = ""
        n_direct_errs = 0
        for (dep, err) in failed_deps
            if strict || (dep in direct_deps)
                err_str = string(err_str, "\n$dep\n\n$err", (n_direct_errs > 0 ? "\n" : ""))
                n_direct_errs += 1
            end
        end
        if err_str != ""
            pluralde = n_direct_errs == 1 ? "y" : "ies"
            direct = strict ? "" : "direct "
            err_msg = "The following $n_direct_errs $(direct)dependenc$(pluralde) failed to precompile:\n$(err_str[1:end-1])"
            if internal_call # aka. auto-precompilation
                if isinteractive() && !get(ENV, "CI", false)
                    plural1 = length(failed_deps) == 1 ? "y" : "ies"
                    println(io, "  ", color_string("$(length(failed_deps))", Base.error_color()), " dependenc$(plural1) errored.")
                    println(io, "  For a report of the errors see `julia> err`. To retry use `pkg> precompile`")
                    setglobal!(Base.MainInclude, :err, PkgPrecompileError(err_msg))
                else
                    # auto-precompilation shouldn't throw but if the user can't easily access the
                    # error messages, just show them
                    print(io, "\n", err_msg)
                end
            else
                println(io)
                pkgerror(err_msg)
            end
        end
    end
    nothing
end

function _color_string(cstr::String, col::Union{Int64, Symbol}, hascolor)
    if hascolor
        enable_ansi  = get(Base.text_colors, col, Base.text_colors[:default])
        disable_ansi = get(Base.disable_text_style, col, Base.text_colors[:default])
        return string(enable_ansi, cstr, disable_ansi)
    else
        return cstr
    end
end

function maybe_cachefile_lock(f, io::IO, print_lock::ReentrantLock, fancyprint::Bool, pkg::Base.PkgId, pkgspidlocked::Dict{Base.PkgId,String}, hascolor)
    stale_age = Base.compilecache_pidlock_stale_age
    pidfile = Base.compilecache_pidfile_path(pkg)
    cachefile = FileWatching.trymkpidlock(f, pidfile; stale_age)
    if cachefile === false
        pid, hostname, age = FileWatching.Pidfile.parse_pidfile(pidfile)
        pkgspidlocked[pkg] = if isempty(hostname) || hostname == gethostname()
            if pid == getpid()
                "an async task in this process (pidfile: $pidfile)"
            else
                "another process (pid: $pid, pidfile: $pidfile)"
            end
        else
            "another machine (hostname: $hostname, pid: $pid, pidfile: $pidfile)"
        end
        !fancyprint && lock(print_lock) do
            println(io, "    ", pkg.name, _color_string(" Being precompiled by $(pkgspidlocked[pkg])", Base.info_color(), hascolor))
        end
        # wait until the lock is available
        FileWatching.mkpidlock(pidfile; stale_age) do
            # double-check in case the other process crashed or the lock expired
            if Base.isprecompiled(pkg; ignore_loaded=true) # don't use caches for this as the env state will have changed
                return nothing # returning nothing indicates a process waited for another
            else
                delete!(pkgspidlocked, pkg)
                return f() # precompile
            end
        end
    end
    return cachefile
end

const pkgs_precompile_suspended = PackageSpec[] # packages that shouldn't be retried during autoprecomp
const pkgs_precompile_pending = PackageSpec[] # packages that need to be retried after restart
function save_precompile_state()
    path = Operations.pkg_scratchpath()
    for (prefix, store) in (("suspend_cache_", pkgs_precompile_suspended), ("pending_cache_", pkgs_precompile_pending))
        fpath = joinpath(path, string(prefix, hash(string(Base.active_project(), Base.VERSION))))
        if isempty(store)
            Base.rm(fpath, force=true)
        else
            mkpath(path); Base.rm(fpath, force=true)
            open(fpath, "w") do io
                serialize(io, store)
            end
        end
    end
    return nothing
end
function recall_precompile_state()
    for (prefix, store) in (("suspend_cache_", pkgs_precompile_suspended), ("pending_cache_", pkgs_precompile_pending))
        fpath = joinpath(Operations.pkg_scratchpath(), string(prefix, hash(string(Base.active_project(), Base.VERSION))))
        if isfile(fpath)
            open(fpath) do io
                try
                    pkgspecs = deserialize(io)::Vector{PackageSpec}
                    append!(empty!(store), pkgspecs)
                catch
                    empty!(store)
                end
            end
            Base.rm(fpath, force=true)
        else
            empty!(store)
        end
    end
    return nothing
end
function precomp_suspend!(pkg::PackageSpec)
    precomp_suspended(pkg) || push!(pkgs_precompile_suspended, pkg)
    return
end
precomp_unsuspend!() = empty!(pkgs_precompile_suspended)
precomp_suspended(pkg::PackageSpec) = pkg in pkgs_precompile_suspended
function precomp_prune_suspended!(pkgs::Vector{PackageSpec})
    filter!(in(pkgs), pkgs_precompile_suspended)
    unique!(pkgs_precompile_suspended)
    return
end

function precomp_queue!(pkg::PackageSpec)
    precomp_suspended(pkg) || push!(pkgs_precompile_pending, pkg)
    return
end
precomp_dequeue!(pkg::PackageSpec) = filter!(!isequal(pkg), pkgs_precompile_pending)
precomp_queued(pkg::PackageSpec) = pkg in pkgs_precompile_pending

function tree_hash(repo::LibGit2.GitRepo, tree_hash::String)
    try
        return LibGit2.GitObject(repo, tree_hash)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    return nothing
end

instantiate(; kwargs...) = instantiate(Context(); kwargs...)
function instantiate(ctx::Context; manifest::Union{Bool, Nothing}=nothing,
                     update_registry::Bool=true, verbose::Bool=false,
                     platform::AbstractPlatform=HostPlatform(), allow_build::Bool=true, allow_autoprecomp::Bool=true, kwargs...)
    Context!(ctx; kwargs...)
    if Registry.download_default_registries(ctx.io)
        copy!(ctx.registries, Registry.reachable_registries())
    end
    if !isfile(ctx.env.project_file) && isfile(ctx.env.manifest_file)
        _manifest = Pkg.Types.read_manifest(ctx.env.manifest_file)
        Types.check_warn_manifest_julia_version_compat(_manifest, ctx.env.manifest_file)
        deps = Dict{String,String}()
        for (uuid, pkg) in _manifest
            if pkg.name in keys(deps)
                # TODO, query what package to put in Project when in interactive mode?
                pkgerror("cannot instantiate a manifest without project file when the manifest has multiple packages with the same name ($(pkg.name))")
            end
            deps[pkg.name] = string(uuid)
        end
        Types.write_project(Dict("deps" => deps), ctx.env.project_file)
        return instantiate(Context(); manifest=manifest, update_registry=update_registry, allow_autoprecomp=allow_autoprecomp, verbose=verbose, platform=platform, kwargs...)
    end
    if (!isfile(ctx.env.manifest_file) && manifest === nothing) || manifest == false
        # given no manifest exists, only allow invoking a registry update if there are project deps
        allow_registry_update = isfile(ctx.env.project_file) && !isempty(ctx.env.project.deps)
        up(ctx; update_registry = update_registry && allow_registry_update)
        allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)
        return
    end
    if !isfile(ctx.env.manifest_file) && manifest == true
        pkgerror("expected manifest file at `$(ctx.env.manifest_file)` but it does not exist")
    end
    Types.check_warn_manifest_julia_version_compat(ctx.env.manifest, ctx.env.manifest_file)

    if Operations.is_manifest_current(ctx.env) === false
        @warn """The project dependencies or compat requirements have changed since the manifest was last resolved.
        It is recommended to `Pkg.resolve()` or consider `Pkg.update()` if necessary."""
    end

    Operations.prune_manifest(ctx.env)
    for (name, uuid) in ctx.env.project.deps
        get(ctx.env.manifest, uuid, nothing) === nothing || continue
        pkgerror("`$name` is a direct dependency, but does not appear in the manifest.",
                 " If you intend `$name` to be a direct dependency, run `Pkg.resolve()` to populate the manifest.",
                 " Otherwise, remove `$name` with `Pkg.rm(\"$name\")`.",
                 " Finally, run `Pkg.instantiate()` again.")
    end
    # check if all source code and artifacts are downloaded to exit early
    if Operations.is_instantiated(ctx.env; platform)
        allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)
        return
    end

    pkgs = Operations.load_all_deps(ctx.env)
    try
        # First try without updating the registry
        Operations.check_registered(ctx.registries, pkgs)
    catch e
        if !(e isa PkgError) || update_registry == false
            rethrow(e)
        end
        Operations.update_registries(ctx; force=false)
        Operations.check_registered(ctx.registries, pkgs)
    end
    new_git = UUID[]
    # Handling packages tracking repos
    for pkg in pkgs
        repo_source = pkg.repo.source
        repo_source !== nothing || continue
        sourcepath = Operations.source_path(ctx.env.manifest_file, pkg, ctx.julia_version)
        isdir(sourcepath) && continue
        ## Download repo at tree hash
        # determine canonical form of repo source
        if !isurl(repo_source)
            repo_source = normpath(joinpath(dirname(ctx.env.project_file), repo_source))
        end
        if !isurl(repo_source) && !isdir(repo_source)
            pkgerror("Did not find path `$(repo_source)` for $(err_rep(pkg))")
        end
        repo_path = Types.add_repo_cache_path(repo_source)
        let repo_source=repo_source
            LibGit2.with(GitTools.ensure_clone(ctx.io, repo_path, repo_source; isbare=true)) do repo
                # We only update the clone if the tree hash can't be found
                tree_hash_object = tree_hash(repo, string(pkg.tree_hash))
                if tree_hash_object === nothing
                    GitTools.fetch(ctx.io, repo, repo_source; refspecs=Types.refspecs)
                    tree_hash_object = tree_hash(repo, string(pkg.tree_hash))
                end
                if tree_hash_object === nothing
                    pkgerror("Did not find tree_hash $(pkg.tree_hash) for $(err_rep(pkg))")
                end
                mkpath(sourcepath)
                GitTools.checkout_tree_to_path(repo, tree_hash_object, sourcepath)
                push!(new_git, pkg.uuid)
            end
        end
    end

    # Install all packages
    new_apply = Operations.download_source(ctx)
    # Install all artifacts
    Operations.download_artifacts(ctx.env; platform, verbose, io=ctx.io)
    # Run build scripts
    allow_build && Operations.build_versions(ctx, union(new_apply, new_git); verbose=verbose)

    allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)
end


@deprecate status(mode::PackageMode) status(mode=mode)

function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool=false, mode=PKGMODE_PROJECT, outdated::Bool=false, compat::Bool=false, extensions::Bool=false, io::IO=stdout_f())
    if compat
        diff && pkgerror("Compat status has no `diff` mode")
        outdated && pkgerror("Compat status has no `outdated` mode")
        extensions && pkgerror("Compat status has no `extensions` mode")
        Operations.print_compat(ctx, pkgs; io)
    else
        Operations.status(ctx.env, ctx.registries, pkgs; mode, git_diff=diff, io, outdated, extensions)
    end
    return nothing
end


function activate(;temp=false, shared=false, prev=false, io::IO=stderr_f())
    shared && pkgerror("Must give a name for a shared environment")
    temp && return activate(mktempdir(); io=io)
    if prev
        if isempty(PREV_ENV_PATH[])
            pkgerror("No previously active environment found")
        else
            return activate(PREV_ENV_PATH[]; io=io)
        end
    end
    if !isnothing(Base.active_project())
        PREV_ENV_PATH[] = Base.active_project()
    end
    Base.ACTIVE_PROJECT[] = nothing
    p = Base.active_project()
    p === nothing || printpkgstyle(io, :Activating, "project at $(pathrepr(dirname(p)))")
    add_snapshot_to_undo()
    return nothing
end
function _activate_dep(dep_name::AbstractString)
    Base.active_project() === nothing && return
    ctx = nothing
    try
        ctx = Context()
    catch err
        err isa PkgError || rethrow()
        return
    end
    uuid = get(ctx.env.project.deps, dep_name, nothing)
    if uuid !== nothing
        entry = manifest_info(ctx.env.manifest, uuid)
        if entry.path !== nothing
            return joinpath(dirname(ctx.env.manifest_file), entry.path::String)
        end
    end
end
function activate(path::AbstractString; shared::Bool=false, temp::Bool=false, io::IO=stderr_f())
    temp && pkgerror("Can not give `path` argument when creating a temporary environment")
    if !shared
        # `pkg> activate path`/`Pkg.activate(path)` does the following
        # 1. if path exists, activate that
        # 2. if path exists in deps, and the dep is deved, activate that path (`devpath` above)
        # 3. activate the non-existing directory (e.g. as in `pkg> activate .` for initing a new env)
        if Pkg.isdir_nothrow(path)
            fullpath = abspath(path)
        else
            fullpath = _activate_dep(path)
            if fullpath === nothing
                fullpath = abspath(path)
            end
        end
    else
        # initialize `fullpath` in case of empty `Pkg.depots()`
        fullpath = ""
        # loop over all depots to check if the shared environment already exists
        for depot in Pkg.depots()
            fullpath = joinpath(Pkg.envdir(depot), path)
            isdir(fullpath) && break
        end
        # this disallows names such as "Foo/bar", ".", "..", etc
        if basename(abspath(fullpath)) != path
            pkgerror("not a valid name for a shared environment: $(path)")
        end
        # unless the shared environment already exists, place it in the first depots
        if !isdir(fullpath)
            fullpath = joinpath(Pkg.envdir(Pkg.depots1()), path)
        end
    end
    if !isnothing(Base.active_project())
        PREV_ENV_PATH[] = Base.active_project()
    end
    Base.ACTIVE_PROJECT[] = Base.load_path_expand(fullpath)
    p = Base.active_project()
    if p !== nothing
        n = ispath(p) ? "" : "new "
        printpkgstyle(io, :Activating, "$(n)project at $(pathrepr(dirname(p)))")
    end
    add_snapshot_to_undo()
    return nothing
end
function activate(f::Function, new_project::AbstractString)
    old = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = new_project
    try
        f()
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

function compat(ctx::Context; io = nothing)
    io = something(io, ctx.io)
    can_fancyprint(io) || pkgerror("Pkg.compat cannot be run interactively in this terminal")
    printpkgstyle(io, :Compat, pathrepr(ctx.env.project_file))
    longest_dep_len = max(5, length.(collect(keys(ctx.env.project.deps)))...)
    opt_strs = String[]
    opt_pkgs = String[]
    compat_str = Operations.get_compat_str(ctx.env.project, "julia")
    push!(opt_strs, Operations.compat_line(io, "julia", nothing, compat_str, longest_dep_len, indent = ""))
    push!(opt_pkgs, "julia")
    for (dep, uuid) in sort(collect(ctx.env.project.deps); by = x->x.first)
        compat_str = Operations.get_compat_str(ctx.env.project, dep)
        push!(opt_strs, Operations.compat_line(io, dep, uuid, compat_str, longest_dep_len, indent = ""))
        push!(opt_pkgs, dep)
    end
    menu = TerminalMenus.RadioMenu(opt_strs, pagesize=length(opt_strs))
    choice = try
        TerminalMenus.request("  Select an entry to edit:", menu)
    catch err
        if err isa InterruptException # if ^C is entered
            println(io)
            return false
        end
        rethrow()
    end
    choice == -1 && return false
    dep = opt_pkgs[choice]
    current_compat_str = something(Operations.get_compat_str(ctx.env.project, dep), "")
    resp = try
        prompt = "  Edit compat entry for $(dep):"
        print(io, prompt)
        buffer = current_compat_str
        cursor = length(buffer)
        start_pos = length(prompt) + 2
        move_start = "\e[$(start_pos)G"
        clear_to_end = "\e[0J"
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), stdin.handle, true)
        while true
            print(io, move_start, clear_to_end, buffer, "\e[$(start_pos + cursor)G")
            inp = TerminalMenus._readkey(stdin)
            if inp == '\r' # Carriage return
                println(io)
                break
            elseif inp == '\x03' # cltr-C
                println(io)
                return
            elseif inp == TerminalMenus.ARROW_RIGHT
                cursor = min(length(buffer), cursor + 1)
            elseif inp == TerminalMenus.ARROW_LEFT
                cursor = max(0, cursor - 1)
            elseif inp == TerminalMenus.HOME_KEY
                cursor = (0)
            elseif inp == TerminalMenus.END_KEY
                cursor = length(buffer)
            elseif inp == TerminalMenus.DEL_KEY
                if cursor == 0
                    buffer = buffer[2:end]
                elseif cursor < length(buffer)
                    buffer = buffer[1:cursor] * buffer[(cursor + 2):end]
                end
            elseif inp isa TerminalMenus.Key
                # ignore all other escaped (multi-byte) keys
            elseif inp == '\x7f' # backspace
                if cursor == 1
                    buffer = buffer[2:end]
                elseif cursor == length(buffer)
                    buffer = buffer[1:end - 1]
                elseif cursor > 0
                    buffer = buffer[1:(cursor-1)] * buffer[(cursor + 1):end]
                else
                    continue
                end
                cursor -= 1
            else
                if cursor == 0
                    buffer = inp * buffer
                elseif cursor == length(buffer)
                    buffer = buffer * inp
                else
                    buffer = buffer[1:cursor] * inp * buffer[(cursor + 1):end]
                end
                cursor += 1
            end
        end
        buffer
    finally
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), stdin.handle, false)
    end
    new_entry = strip(resp)
    compat(ctx, dep, string(new_entry))
    return
end
function compat(ctx::Context, pkg::String, compat_str::Union{Nothing,String}; io = nothing, kwargs...)
    io = something(io, ctx.io)
    pkg = pkg == "Julia" ? "julia" : pkg
    isnothing(compat_str) || (compat_str = string(strip(compat_str, '"')))
    if haskey(ctx.env.project.deps, pkg) || pkg == "julia"
        success = Operations.set_compat(ctx.env.project, pkg, isnothing(compat_str) ? nothing : isempty(compat_str) ? nothing : compat_str)
        success === false && pkgerror("invalid compat version specifier \"$(compat_str)\"")
        write_env(ctx.env)
        if isnothing(compat_str) || isempty(compat_str)
            printpkgstyle(io, :Compat, "entry removed for $(pkg)")
        else
            printpkgstyle(io, :Compat, "entry set:\n  $(pkg) = $(repr(compat_str))")
        end
        printpkgstyle(io, :Resolve, "checking for compliance with the new compat rules...")
        try
            resolve(ctx)
        catch e
            if e isa ResolverError
                printpkgstyle(io, :Error, string(e.msg), color = Base.warn_color())
                printpkgstyle(io, :Suggestion, "Call `update` to attempt to meet the compatibility requirements.", color = Base.info_color())
            else
                rethrow()
            end
        end
        return
    else
        pkgerror("No package named $pkg in current Project")
    end
end
compat(pkg::String; kwargs...) = compat(pkg, nothing; kwargs...)
compat(pkg::String, compat_str::Union{Nothing,String}; kwargs...) = compat(Context(), pkg, compat_str; kwargs...)
compat(;kwargs...) = compat(Context(); kwargs...)

#######
# why #
#######

function why(ctx::Context, pkgs::Vector{PackageSpec}; io::IO, kwargs...)
    require_not_empty(pkgs, :why)

    manifest_resolve!(ctx.env.manifest, pkgs)
    project_deps_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)

    # Store all packages that has a dependency on us (all dependees)
    incoming = Dict{UUID, Set{UUID}}()
    for (uuid, dep_pkgs) in ctx.env.manifest
        for (dep, dep_uuid) in dep_pkgs.deps
            haskey(incoming, dep_uuid) || (incoming[dep_uuid] = Set{UUID}())
            push!(incoming[dep_uuid], uuid)
        end
    end

    function find_paths!(final_paths, current, path = UUID[])
        push!(path, current)
        current in values(ctx.env.project.deps) && push!(final_paths, path) # record once we've traversed to a project dep
        haskey(incoming, current) || return # but only return if we've reached a leaf that nothing depends on
        for p in incoming[current]
            if p in path
                # detected dependency cycle and none of the dependencies in the cycle
                # are in the project could happen when manually modifying
                # the project and running this function function before a
                # resolve
                continue
            end
            find_paths!(final_paths, p, copy(path))
        end
    end

    first = true
    for pkg in pkgs
        !first && println(io)
        first = false
        final_paths = Set{Vector{UUID}}()
        find_paths!(final_paths, pkg.uuid)
        foreach(reverse!, final_paths)
        final_paths_names = map(x -> [ctx.env.manifest[uuid].name for uuid in x], collect(final_paths))
        sort!(final_paths_names, by = x -> (x, length(x)))
        delimiter = sprint((io, args) -> printstyled(io, args...; color=:light_green), "→", context=io)
        for path in final_paths_names
            println(io, "  ", join(path, " $delimiter "))
        end
    end
end


########
# Undo #
########

struct UndoSnapshot
    date::DateTime
    project::Types.Project
    manifest::Types.Manifest
end
mutable struct UndoState
    idx::Int
    entries::Vector{UndoSnapshot}
end
UndoState() = UndoState(0, UndoSnapshot[])
const undo_entries = Dict{String, UndoState}()
const max_undo_limit = 50
const saved_initial_snapshot = Ref(false)

function add_snapshot_to_undo(env=nothing)
    # only attempt to take a snapshot if there is
    # an active project to be found
    if env === nothing
        if Base.active_project() === nothing
            return
        else
            env = EnvCache()
        end
    end
    state = get!(undo_entries, env.project_file) do
        UndoState()
    end
    # Is the current state the same as the previous one, do nothing
    if !isempty(state.entries) && env.project == env.original_project && env.manifest.deps == env.original_manifest.deps
        return
    end
    snapshot = UndoSnapshot(now(), env.project, env.manifest)
    deleteat!(state.entries, 1:(state.idx-1))
    pushfirst!(state.entries, snapshot)
    state.idx = 1

    resize!(state.entries, min(length(state.entries), max_undo_limit))
end

undo(ctx = Context()) = redo_undo(ctx, :undo,  1)
redo(ctx = Context()) = redo_undo(ctx, :redo, -1)
function redo_undo(ctx, mode::Symbol, direction::Int)
    @assert direction == 1 || direction == -1
    state = get(undo_entries, ctx.env.project_file, nothing)
    state === nothing && pkgerror("no undo state for current project")
    state.idx == (mode === :redo ? 1 : length(state.entries)) && pkgerror("$mode: no more states left")

    state.idx += direction
    snapshot = state.entries[state.idx]
    ctx.env.manifest, ctx.env.project = snapshot.manifest, snapshot.project
    write_env(ctx.env; update_undo=false)
    Operations.show_update(ctx.env, ctx.registries; io=ctx.io)
end


function setprotocol!(;
    domain::AbstractString="github.com",
    protocol::Union{Nothing, AbstractString}=nothing
)
    GitTools.setprotocol!(domain=domain, protocol=protocol)
    return nothing
end

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

function handle_package_input!(pkg::PackageSpec)
    if pkg.path !== nothing && pkg.url !== nothing
        pkgerror("`path` and `url` are conflicting specifications")
    end
    pkg.repo = Types.GitRepo(rev = pkg.rev, source = pkg.url !== nothing ? pkg.url : pkg.path,
                         subdir = pkg.subdir)
    pkg.path = nothing
    pkg.tree_hash = nothing
    if pkg.version === nothing
        pkg.version = VersionSpec()
    end
    if !(pkg.version isa VersionNumber)
        pkg.version = VersionSpec(pkg.version)
    end
    pkg.uuid = pkg.uuid isa String ? UUID(pkg.uuid) : pkg.uuid
end

function upgrade_manifest(man_path::String)
    dir = mktempdir()
    cp(man_path, joinpath(dir, "Manifest.toml"))
    Pkg.activate(dir) do
        Pkg.upgrade_manifest()
    end
    mv(joinpath(dir, "Manifest.toml"), man_path, force = true)
end
function upgrade_manifest(ctx::Context = Context())
    before_format = ctx.env.manifest.manifest_format
    if before_format == v"2.0"
        pkgerror("Format of manifest file at `$(ctx.env.manifest_file)` already up to date: manifest_format == $(before_format)")
    elseif before_format != v"1.0"
        pkgerror("Format of manifest file at `$(ctx.env.manifest_file)` version is unrecognized: manifest_format == $(before_format)")
    end
    ctx.env.manifest.manifest_format = v"2.0"
    Types.write_manifest(ctx.env)
    printpkgstyle(ctx.io, :Updated, "Format of manifest file at `$(ctx.env.manifest_file)` updated from v$(before_format.major).$(before_format.minor) to v2.0")
    return nothing
end

end # module
