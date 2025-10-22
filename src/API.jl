# This file is a part of Julia. License is MIT: https://julialang.org/license

module API

using UUIDs
using Printf
import Random
using Dates
import LibGit2
import Logging
import FileWatching

import Base: StaleCacheKey

import ..depots, ..depots1, ..logdir, ..devdir, ..printpkgstyle, .._autoprecompilation_enabled_scoped
import ..Operations, ..GitTools, ..Pkg, ..Registry
import ..can_fancyprint, ..pathrepr, ..isurl, ..PREV_ENV_PATH, ..atomic_toml_write
using ..Types, ..TOML
using ..Types: VersionTypes
using Base.BinaryPlatforms
import ..stderr_f, ..stdout_f
using ..Artifacts: artifact_paths
using ..MiniProgressBars
import ..Resolve: ResolverError, ResolverTimeoutError

include("generate.jl")

Base.@kwdef struct PackageInfo
    name::String
    version::Union{Nothing, VersionNumber}
    tree_hash::Union{Nothing, String}
    is_direct_dep::Bool
    is_pinned::Bool
    is_tracking_path::Bool
    is_tracking_repo::Bool
    is_tracking_registry::Bool
    git_revision::Union{Nothing, String}
    git_source::Union{Nothing, String}
    source::String
    dependencies::Dict{String, UUID}
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
        pkgerror(
            "expected package $(err_rep(pkg)) to exist in the manifest",
            " (use `resolve` to populate the manifest)"
        )
    end
    return package_info(env, pkg, entry)
end

function package_info(env::EnvCache, pkg::PackageSpec, entry::PackageEntry)::PackageInfo
    git_source = pkg.repo.source === nothing ? nothing :
        isurl(pkg.repo.source::String) ? pkg.repo.source::String :
        Operations.project_rel_path(env, pkg.repo.source::String)
    _source_path = Operations.source_path(env.manifest_file, pkg)
    if _source_path === nothing
        @debug "Manifest file $(env.manifest_file) contents:\n$(read(env.manifest_file, String))"
        pkgerror("could not find source path for package $(err_rep(pkg)) based on $(env.manifest_file)")
    end
    info = PackageInfo(
        name = pkg.name,
        version = pkg.version != VersionSpec() ? pkg.version : nothing,
        tree_hash = pkg.tree_hash === nothing ? nothing : string(pkg.tree_hash), # TODO or should it just be a SHA?
        is_direct_dep = pkg.uuid in values(env.project.deps),
        is_pinned = pkg.pinned,
        is_tracking_path = pkg.path !== nothing,
        is_tracking_repo = pkg.repo.rev !== nothing || pkg.repo.source !== nothing,
        is_tracking_registry = Operations.is_tracking_registry(pkg),
        git_revision = pkg.repo.rev,
        git_source = git_source,
        source = Operations.project_rel_path(env, _source_path),
        dependencies = copy(entry.deps), #TODO is copy needed?
    )
    return info
end

dependencies() = dependencies(EnvCache())
function dependencies(env::EnvCache)
    pkgs = Operations.load_all_deps_loadable(env)
    return Dict(pkg.uuid::UUID => package_info(env, pkg) for pkg in pkgs)
end
function dependencies(fn::Function, uuid::UUID)
    dep = get(dependencies(), uuid, nothing)
    if dep === nothing
        pkgerror("dependency with UUID `$uuid` does not exist")
    end
    return fn(dep)
end


Base.@kwdef struct ProjectInfo
    name::Union{Nothing, String}
    uuid::Union{Nothing, UUID}
    version::Union{Nothing, VersionNumber}
    ispackage::Bool
    dependencies::Dict{String, UUID}
    sources::Dict{String, Dict{String, String}}
    path::String
end

project() = project(EnvCache())
function project(env::EnvCache)::ProjectInfo
    pkg = env.pkg
    return ProjectInfo(
        name = pkg === nothing ? nothing : pkg.name,
        uuid = pkg === nothing ? nothing : pkg.uuid,
        version = pkg === nothing ? nothing : pkg.version::VersionNumber,
        ispackage = pkg !== nothing,
        dependencies = env.project.deps,
        sources = env.project.sources,
        path = env.project_file
    )
end

function check_package_name(x::AbstractString, mode::Union{Nothing, String, Symbol} = nothing)
    if !Base.isidentifier(x)
        message = sprint() do iostr
            print(iostr, "`$x` is not a valid package name")
            if endswith(lowercase(x), ".jl")
                print(iostr, ". Perhaps you meant `$(chop(x; tail = 3))`")
            end
            if mode !== nothing && any(occursin.(['\\', '/'], x)) # maybe a url or a path
                print(
                    iostr, "\nThe argument appears to be a URL or path, perhaps you meant ",
                    "`Pkg.$mode(url=\"...\")` or `Pkg.$mode(path=\"...\")`."
                )
            end
        end
        pkgerror(message)
    end
    return
end
check_package_name(::Nothing, ::Any) = nothing

function require_not_empty(pkgs, f::Symbol)
    return isempty(pkgs) && pkgerror("$f requires at least one package")
end

function check_readonly(ctx::Context)
    return ctx.env.project.readonly && pkgerror("Cannot modify a readonly environment. The project at $(ctx.env.project_file) is marked as readonly.")
end

# Provide some convenience calls
for f in (:develop, :add, :rm, :up, :pin, :free, :test, :build, :status, :why, :precompile)
    @eval begin
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...) = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        function $f(pkgs::Vector{PackageSpec}; io::IO = $(f === :status ? :stdout_f : :stderr_f)(), kwargs...)
            $(f != :precompile) && Registry.download_default_registries(io)
            ctx = Context()
            # Save initial environment for undo/redo functionality
            if $(f != :precompile) && !saved_initial_snapshot[]
                add_snapshot_to_undo(ctx.env)
                saved_initial_snapshot[] = true
            end
            kwargs = merge((; kwargs...), (:io => io,))
            pkgs = deepcopy(pkgs) # don't mutate input
            foreach(handle_package_input!, pkgs)
            ret = $f(ctx, pkgs; kwargs...)
            $(f in (:up, :pin, :free, :build)) && Pkg._auto_precompile(ctx)
            $(f in (:up, :pin, :free, :rm)) && Pkg._auto_gc(ctx)
            return ret
        end
        $f(ctx::Context; kwargs...) = $f(ctx, PackageSpec[]; kwargs...)
        function $f(;
                name::Union{Nothing, AbstractString} = nothing, uuid::Union{Nothing, String, UUID} = nothing,
                version::Union{VersionNumber, String, VersionSpec, Nothing} = nothing,
                url = nothing, rev = nothing, path = nothing, mode = PKGMODE_PROJECT, subdir = nothing, kwargs...
            )
            pkg = PackageSpec(; name, uuid, version, url, rev, path, subdir)
            if $f === status || $f === rm || $f === up
                kwargs = merge((; kwargs...), (:mode => mode,))
            end
            # Handle $f() case
            return if all(isnothing, [name, uuid, version, url, rev, path, subdir])
                $f(PackageSpec[]; kwargs...)
            else
                $f(pkg; kwargs...)
            end
        end
        function $f(pkgs::Vector{<:NamedTuple}; kwargs...)
            return $f([PackageSpec(; pkg...) for pkg in pkgs]; kwargs...)
        end
    end
end

function update_source_if_set(env, pkg)
    project = env.project
    source = get(project.sources, pkg.name, nothing)
    if source !== nothing
        if pkg.repo == GitRepo()
            delete!(project.sources, pkg.name)
        else
            # This should probably not modify the dicts directly...
            if pkg.repo.source !== nothing
                source["url"] = pkg.repo.source
                delete!(source, "path")
            end
            if pkg.repo.rev !== nothing
                source["rev"] = pkg.repo.rev
                delete!(source, "path")
            end
            if pkg.repo.subdir !== nothing
                source["subdir"] = pkg.repo.subdir
            end
            if pkg.path !== nothing
                source["path"] = pkg.path
                delete!(source, "url")
                delete!(source, "rev")
            end
        end
        if pkg.subdir !== nothing
            source["subdir"] = pkg.subdir
        end
        path, repo = get_path_repo(project, env.project_file, env.manifest_file, pkg.name)
        if path !== nothing
            pkg.path = path
        end
        if repo.source !== nothing
            pkg.repo.source = repo.source
        end
        if repo.rev !== nothing
            pkg.repo.rev = repo.rev
        end
        if repo.subdir !== nothing
            pkg.repo.subdir = repo.subdir
        end
    end

    # Packages in manifest should have their paths set to the path in the manifest
    for (path, wproj) in env.workspace
        if wproj.uuid == pkg.uuid
            pkg.path = Types.relative_project_path(env.manifest_file, dirname(path))
            break
        end
    end
    return
end

function develop(
        ctx::Context, pkgs::Vector{PackageSpec}; shared::Bool = true,
        preserve::PreserveLevel = Operations.default_preserve(), platform::AbstractPlatform = HostPlatform(), kwargs...
    )
    require_not_empty(pkgs, :develop)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)
    check_readonly(ctx)

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
            pkgerror(
                "version specification invalid when calling `develop`:",
                " `$(pkg.version)` specified for package $(err_rep(pkg))"
            )
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

    Operations.update_registries(ctx; force = false, update_cooldown = Day(1))

    for pkg in pkgs
        if Types.collides_with_project(ctx.env, pkg)
            pkgerror("package $(err_rep(pkg)) has the same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
        update_source_if_set(ctx.env, pkg)
    end

    Operations.develop(ctx, pkgs, new_git; preserve = preserve, platform = platform)
    return
end

function add(
        ctx::Context, pkgs::Vector{PackageSpec}; preserve::PreserveLevel = Operations.default_preserve(),
        platform::AbstractPlatform = HostPlatform(), target::Symbol = :deps, allow_autoprecomp::Bool = true, kwargs...
    )
    require_not_empty(pkgs, :add)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)
    check_readonly(ctx)

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
                pkgerror(
                    "version specification invalid when tracking a repository:",
                    " `$(pkg.version)` specified for package $(err_rep(pkg))"
                )
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

    repo_pkgs = PackageSpec[pkg for pkg in pkgs if (pkg.repo.source !== nothing || pkg.repo.rev !== nothing)]
    new_git = handle_repos_add!(ctx, repo_pkgs)
    # repo + unpinned -> name, uuid, repo.rev, repo.source, tree_hash
    # repo + pinned -> name, uuid, tree_hash

    Operations.update_registries(ctx; force = false, update_cooldown = Day(1))

    project_deps_resolve!(ctx.env, pkgs)
    registry_resolve!(ctx.registries, pkgs)
    stdlib_resolve!(pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs, registry = true)

    for pkg in pkgs
        if Types.collides_with_project(ctx.env, pkg)
            pkgerror("package $(err_rep(pkg)) has same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
        update_source_if_set(ctx.env, pkg)
    end

    Operations.add(ctx, pkgs, new_git; allow_autoprecomp, preserve, platform, target)
    return
end

function rm(ctx::Context, pkgs::Vector{PackageSpec}; mode = PKGMODE_PROJECT, all_pkgs::Bool = false, kwargs...)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)
    check_readonly(ctx)
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
        if !(
                pkg.version == VersionSpec() && pkg.pinned == false &&
                    pkg.tree_hash === nothing && pkg.repo.source === nothing &&
                    pkg.repo.rev === nothing && pkg.path === nothing
            )
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
            path, repo = get_path_repo(ctx.env.project, ctx.env.project_file, ctx.env.manifest_file, name)
            push!(pkgs, PackageSpec(name = name, uuid = uuid, path = path, repo = repo))
        end
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        for (uuid, entry) in ctx.env.manifest
            path, repo = get_path_repo(ctx.env.project, ctx.env.project_file, ctx.env.manifest_file, entry.name)
            push!(pkgs, PackageSpec(name = entry.name, uuid = uuid, path = path, repo = repo))
        end
    end
    return
end

function up(
        ctx::Context, pkgs::Vector{PackageSpec};
        level::UpgradeLevel = UPLEVEL_MAJOR, mode::PackageMode = PKGMODE_PROJECT,
        preserve::Union{Nothing, PreserveLevel} = isempty(pkgs) ? nothing : PRESERVE_ALL,
        update_registry::Bool = true,
        skip_writing_project::Bool = false,
        kwargs...
    )
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)
    check_readonly(ctx)
    if Operations.is_fully_pinned(ctx)
        printpkgstyle(ctx.io, :Update, "All dependencies are pinned - nothing to update.", color = Base.info_color())
        return
    end
    if update_registry
        Registry.download_default_registries(ctx.io)
        Operations.update_registries(ctx; force = true)
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
    for pkg in pkgs
        update_source_if_set(ctx.env, pkg)
    end
    Operations.up(ctx, pkgs, level; skip_writing_project, preserve)
    return
end

resolve(; io::IO = stderr_f(), kwargs...) = resolve(Context(; io); kwargs...)
function resolve(ctx::Context; skip_writing_project::Bool = false, kwargs...)
    up(ctx; level = UPLEVEL_FIXED, mode = PKGMODE_MANIFEST, update_registry = false, skip_writing_project, kwargs...)
    return nothing
end

function pin(ctx::Context, pkgs::Vector{PackageSpec}; all_pkgs::Bool = false, kwargs...)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)
    check_readonly(ctx)
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
            pkgerror(
                "repository specification invalid when calling `pin`:",
                " `$(pkg.repo.source)` specified for package $(err_rep(pkg))"
            )
        end
        if pkg.repo.rev !== nothing
            pkgerror(
                "git revision specification invalid when calling `pin`:",
                " `$(pkg.repo.rev)` specified for package $(err_rep(pkg))"
            )
        end
        version = pkg.version
        if version isa VersionSpec
            if version.ranges[1].lower != version.ranges[1].upper # TODO test this
                pkgerror("pinning a package requires a single version, not a versionrange")
            end
        end
        update_source_if_set(ctx.env, pkg)
    end

    project_deps_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)
    Operations.pin(ctx, pkgs)
    return
end

function free(ctx::Context, pkgs::Vector{PackageSpec}; all_pkgs::Bool = false, kwargs...)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)
    check_readonly(ctx)
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
        if !(
                pkg.version == VersionSpec() && pkg.pinned == false &&
                    pkg.tree_hash === nothing && pkg.repo.source === nothing &&
                    pkg.repo.rev === nothing && pkg.path === nothing
            )
            pkgerror("packages may only be specified by name or UUID when calling `free`")
        end
    end

    manifest_resolve!(ctx.env.manifest, pkgs)
    ensure_resolved(ctx, ctx.env.manifest, pkgs)

    Operations.free(ctx, pkgs; err_if_free = !all_pkgs)
    return
end

function test(
        ctx::Context, pkgs::Vector{PackageSpec};
        coverage = false, test_fn = nothing,
        julia_args::Union{Cmd, AbstractVector{<:AbstractString}} = ``,
        test_args::Union{Cmd, AbstractVector{<:AbstractString}} = ``,
        force_latest_compatible_version::Bool = false,
        allow_earlier_backwards_compatible_versions::Bool = true,
        allow_reresolve::Bool = true,
        kwargs...
    )
    julia_args = Cmd(julia_args)
    test_args = Cmd(test_args)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)

    if isempty(pkgs)
        ctx.env.pkg === nothing && pkgerror("The Project.toml of the package being tested must have a name and a UUID entry") #TODO Allow this?
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

is_manifest_current(ctx::Context) = Operations.is_manifest_current(ctx.env)
function is_manifest_current(path::AbstractString)
    project_file = projectfile_path(path, strict = true)
    if project_file === nothing
        pkgerror("could not find project file at `$path`")
    end
    env = EnvCache(project_file)
    return Operations.is_manifest_current(env)
end

const UsageDict = Dict{String, DateTime}
const UsageByDepotDict = Dict{String, UsageDict}

"""
    gc(ctx::Context=Context(); verbose=false, force=false, kwargs...)

Garbage-collect package and artifact installations by sweeping over all known
`Manifest.toml` and `Artifacts.toml` files, noting those that have been deleted, and then
finding artifacts and packages that are thereafter not used by any other projects.
Unused packages, artifacts, repos, and scratch spaces are immediately deleted.

Garbage collection is only applied to the "user depot", e.g. the first entry in the
depot path. If you want to run `gc` on all depots set `force=true` (this might require
admin privileges depending on the setup).

Use verbose mode (`verbose=true`) for detailed output.
"""
function gc(ctx::Context = Context(); collect_delay::Union{Period, Nothing} = nothing, verbose = false, force = false, kwargs...)
    Context!(ctx; kwargs...)
    if collect_delay !== nothing
        @warn "The `collect_delay` parameter is no longer used. Packages are now deleted immediately when they become unreachable."
    end
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
            return
        end

        # Extract usage data from this depot, (taking only the latest state for each
        # tracked manifest/artifact.toml), then merge the usage values from each file
        # into the overall list across depots to create a single, coherent view across
        # all depots.
        usage = UsageDict()
        let usage = usage
            reduce_usage!(joinpath(logdir(depot), "manifest_usage.toml")) do filename, info
                # For Manifest usage, store only the last DateTime for each filename found
                usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"])::DateTime)
            end
        end
        manifest_usage_by_depot[depot] = usage

        usage = UsageDict()
        let usage = usage
            reduce_usage!(joinpath(logdir(depot), "artifact_usage.toml")) do filename, info
                # For Artifact usage, store only the last DateTime for each filename found
                usage[filename] = max(get(usage, filename, DateTime(0)), DateTime(info["time"])::DateTime)
            end
        end
        artifact_usage_by_depot[depot] = usage

        # track last-used
        usage = UsageDict()
        parents = Dict{String, Set{String}}()
        let usage = usage
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
                let usage = usage
                    atomic_toml_write(usage_path, usage, sorted = true)
                end
            end
        end
        return
    end

    # Write condensed Manifest usage
    let all_manifest_tomls = all_manifest_tomls
        write_condensed_toml(manifest_usage_by_depot, "manifest_usage.toml") do depot, usage
            # Keep only manifest usage markers that are still existent
            let usage = usage
                filter!(((k, v),) -> k in all_manifest_tomls, usage)

                # Expand it back into a dict-of-dicts
                return Dict(k => [Dict("time" => v)] for (k, v) in usage)
            end
        end
    end

    # Write condensed Artifact usage
    let all_artifact_tomls = all_artifact_tomls
        write_condensed_toml(artifact_usage_by_depot, "artifact_usage.toml") do depot, usage
            let usage = usage
                filter!(((k, v),) -> k in all_artifact_tomls, usage)
                return Dict(k => [Dict("time" => v)] for (k, v) in usage)
            end
        end
    end

    # Write condensed scratch space usage
    let all_scratch_parents = all_scratch_parents, all_scratch_dirs = all_scratch_dirs
        write_condensed_toml(scratch_usage_by_depot, "scratch_usage.toml") do depot, usage
            # Keep only scratch directories that still exist
            filter!(((k, v),) -> k in all_scratch_dirs, usage)

            # Expand it back into a dict-of-dicts
            expanded_usage = Dict{String, Vector{Dict}}()
            for (k, v) in usage
                # Drop scratch spaces whose parents are all non-existent
                parents = scratch_parents_by_depot[depot][k]
                filter!(p -> p in all_scratch_parents, parents)
                if isempty(parents)
                    continue
                end

                expanded_usage[k] = [
                    Dict(
                        "time" => v,
                        "parent_projects" => collect(parents),
                    ),
                ]
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
    function mark(process_func::Function, index_files, ctx::Context; do_print = true, verbose = false, file_str = nothing)
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


    # Scan manifests, parse them, read in all UUIDs listed and mark those as active
    # printpkgstyle(ctx.io, :Active, "manifests:")
    packages_to_keep = mark(
        process_manifest_pkgs, all_manifest_tomls, ctx,
        verbose = verbose, file_str = "manifest files"
    )


    # Next, do the same for artifacts.
    # printpkgstyle(ctx.io, :Active, "artifacts:")
    artifacts_to_keep = mark(
        x -> process_artifacts_toml(x, String[]),
        all_artifact_tomls, ctx; verbose = verbose, file_str = "artifact files"
    )
    repos_to_keep = mark(process_manifest_repos, all_manifest_tomls, ctx; do_print = false)
    # printpkgstyle(ctx.io, :Active, "scratchspaces:")
    spaces_to_keep = mark(
        x -> process_scratchspace(x, String[]),
        all_scratch_dirs, ctx; verbose = verbose, file_str = "scratchspaces"
    )

    # Collect all unreachable paths (packages, artifacts and repos that are not reachable)
    # and immediately delete them.
    packages_to_delete = String[]
    artifacts_to_delete = String[]
    repos_to_delete = String[]
    spaces_to_delete = String[]

    for depot in gc_depots

        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                !isdir(joinpath(packagedir, name)) && continue

                for slug in readdir(joinpath(packagedir, name))
                    pkg_dir = joinpath(packagedir, name, slug)
                    !isdir(pkg_dir) && continue

                    if !(pkg_dir in packages_to_keep)
                        push!(packages_to_delete, pkg_dir)
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
                    push!(repos_to_delete, repo_dir)
                end
            end
        end

        artifactsdir = abspath(depot, "artifacts")
        if isdir(artifactsdir)
            for hash in readdir(artifactsdir)
                artifact_path = joinpath(artifactsdir, hash)
                !isdir(artifact_path) && continue

                if !(artifact_path in artifacts_to_keep)
                    push!(artifacts_to_delete, artifact_path)
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
                            push!(spaces_to_delete, space_dir_or_file)
                        end
                    elseif uuid == Operations.PkgUUID && isfile(space_dir_or_file)
                        # special cleanup for the precompile cache files that Pkg saves
                        if any(prefix -> startswith(basename(space_dir_or_file), prefix), ("suspend_cache_", "pending_cache_"))
                            if mtime(space_dir_or_file) < (time() - (24 * 60 * 60))
                                push!(spaces_to_delete, space_dir_or_file)
                            end
                        end
                    end
                end
            end
        end

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
                        @error("Failed to calculate size of $path", exception = ex)
                    end
                end
            end
        catch ex
            @error("Failed to calculate size of $path", exception = ex)
        end
        return size
    end

    # Delete paths for unreachable package versions and artifacts, and computing size saved
    function delete_path(path)
        path_size = if isfile(path)
            try
                lstat(path).size
            catch ex
                @error("Failed to calculate size of $path", exception = ex)
                0
            end
        else
            recursive_dir_size(path)
        end
        try
            Base.Filesystem.prepare_for_deletion(path)
            Base.rm(path; recursive = true, force = true)
        catch e
            @warn("Failed to delete $path", exception = e)
            return 0
        end
        if verbose
            printpkgstyle(
                ctx.io, :Deleted, pathrepr(path) * " (" *
                    Base.format_bytes(path_size) * ")"
            )
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

    # Delete anything that could not be rm-ed and was specially recorded in the delayed delete reference folder.
    # Do this silently because it's out of scope for Pkg.gc() but it's helpful to use this opportunity to do it.
    if isdefined(Base.Filesystem, :delayed_delete_ref)
        delayed_delete_ref_path = Base.Filesystem.delayed_delete_ref()
        if isdir(delayed_delete_ref_path)
            delayed_delete_dirs = Set{String}()
            for f in readdir(delayed_delete_ref_path; join = true)
                try
                    p = readline(f)
                    push!(delayed_delete_dirs, dirname(p))
                    Base.Filesystem.prepare_for_deletion(p)
                    Base.rm(p; recursive = true, force = true, allow_delayed_delete = false)
                    Base.rm(f)
                catch e
                    @debug "Failed to delete $p" exception = e
                end
            end
            for dir in delayed_delete_dirs
                if basename(dir) == "julia_delayed_deletes" && isempty(readdir(dir))
                    Base.Filesystem.prepare_for_deletion(dir)
                    Base.rm(dir; recursive = true)
                end
            end
            if isempty(readdir(delayed_delete_ref_path))
                Base.Filesystem.prepare_for_deletion(delayed_delete_ref_path)
                Base.rm(delayed_delete_ref_path; recursive = true)
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
        bytes_saved_string = Base.format_bytes(freed)
        return printpkgstyle(ctx.io, :Deleted, "$(ndel) $(name)$(s) ($bytes_saved_string)")
    end
    print_deleted(ndel_pkg, package_space_freed, "package installation")
    print_deleted(ndel_repo, repo_space_freed, "repo")
    print_deleted(ndel_art, artifact_space_freed, "artifact installation")
    print_deleted(ndel_space, scratch_space_freed, "scratchspace")

    if ndel_pkg == 0 && ndel_art == 0 && ndel_repo == 0 && ndel_space == 0
        printpkgstyle(ctx.io, :Deleted, "no artifacts, repos, packages or scratchspaces")
    end

    # Run git gc on registries if git is available
    if Sys.which("git") !== nothing
        for depot in gc_depots
            reg_dir = joinpath(depot, "registries")
            isdir(reg_dir) || continue

            for reg_name in readdir(reg_dir)
                reg_path = joinpath(reg_dir, reg_name)
                isdir(reg_path) || continue
                git_dir = joinpath(reg_path, ".git")
                isdir(git_dir) || continue

                try
                    if verbose
                        printpkgstyle(ctx.io, :GC, "running git gc on registry $(reg_name)")
                    end
                    # Run git gc quietly, don't error if it fails
                    run(`git -C $reg_path gc --quiet`)
                catch e
                    # Silently ignore errors from git gc
                    if verbose
                        @warn "git gc failed for registry $(reg_name)" exception = e
                    end
                end
            end
        end
    end

    return
end

function build(ctx::Context, pkgs::Vector{PackageSpec}; verbose = false, allow_reresolve::Bool = true, kwargs...)
    Context!(ctx; kwargs...)
    Operations.ensure_manifest_registries!(ctx)

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
    return Operations.build(ctx, Set{UUID}(pkg.uuid for pkg in pkgs), verbose; allow_reresolve)
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

function precompile(
        ctx::Context, pkgs::Vector{PackageSpec}; internal_call::Bool = false,
        strict::Bool = false, warn_loaded = true, already_instantiated = false, timing::Bool = false,
        _from_loading::Bool = false, configs::Union{Base.Precompilation.Config, Vector{Base.Precompilation.Config}} = (`` => Base.CacheFlags()),
        workspace::Bool = false, kwargs...
    )
    Context!(ctx; kwargs...)
    if !already_instantiated
        instantiate(ctx; allow_autoprecomp = false, kwargs...)
        @debug "precompile: instantiated"
    end

    # TODO: Maybe this should be done in Base?

    if !isfile(ctx.env.project_file)
        return
    end

    io = ctx.io
    if io isa IOContext{IO} && !isa(io.io, Base.PipeEndpoint)
        # precompile does quite a bit of output and using the IOContext{IO} can cause
        # some slowdowns, the important part here is to not specialize the whole
        # precompile function on the io.
        # But don't unwrap the IOContext if it is a PipeEndpoint, as that would
        # cause the output to lose color.
        io = io.io
    end

    return activate(dirname(ctx.env.project_file)) do
        pkgs_name = String[pkg.name for pkg in pkgs]
        return Base.Precompilation.precompilepkgs(pkgs_name; internal_call, strict, warn_loaded, timing, _from_loading, configs, manifest = workspace, io)
    end
end

function precompile(f, args...; kwargs...)
    return Base.ScopedValues.@with _autoprecompilation_enabled_scoped => false begin
        f()
        Pkg.precompile(args...; kwargs...)
    end
end

function tree_hash(repo::LibGit2.GitRepo, tree_hash::String)
    try
        return LibGit2.GitObject(repo, tree_hash)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    return nothing
end

instantiate(; kwargs...) = instantiate(Context(); kwargs...)
function instantiate(
        ctx::Context; manifest::Union{Bool, Nothing} = nothing,
        update_registry::Bool = true, verbose::Bool = false,
        platform::AbstractPlatform = HostPlatform(), allow_build::Bool = true, allow_autoprecomp::Bool = true,
        workspace::Bool = false, julia_version_strict::Bool = false, kwargs...
    )
    Context!(ctx; kwargs...)
    if Registry.download_default_registries(ctx.io)
        copy!(ctx.registries, Registry.reachable_registries())
    end
    Operations.ensure_manifest_registries!(ctx)
    if !isfile(ctx.env.project_file) && isfile(ctx.env.manifest_file)
        _manifest = Pkg.Types.read_manifest(ctx.env.manifest_file)
        Types.check_manifest_julia_version_compat(_manifest, ctx.env.manifest_file; julia_version_strict)
        deps = Dict{String, String}()
        for (uuid, pkg) in _manifest
            if pkg.name in keys(deps)
                # TODO, query what package to put in Project when in interactive mode?
                pkgerror("cannot instantiate a manifest without project file when the manifest has multiple packages with the same name ($(pkg.name))")
            end
            deps[pkg.name] = string(uuid)
        end
        Types.write_project(Dict("deps" => deps), ctx.env.project_file)
        return instantiate(Context(); manifest = manifest, update_registry = update_registry, allow_autoprecomp = allow_autoprecomp, verbose = verbose, platform = platform, kwargs...)
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
    Types.check_manifest_julia_version_compat(ctx.env.manifest, ctx.env.manifest_file; julia_version_strict)

    if Operations.is_manifest_current(ctx.env) === false
        resolve_cmd = Pkg.in_repl_mode() ? "pkg> resolve" : "Pkg.resolve()"
        update_cmd = Pkg.in_repl_mode() ? "pkg> update" : "Pkg.update()"
        @warn """The project dependencies or compat requirements have changed since the manifest was last resolved.
        It is recommended to `$resolve_cmd` or consider `$update_cmd` if necessary."""
    end

    Operations.prune_manifest(ctx.env)
    for (name, uuid) in ctx.env.project.deps
        get(ctx.env.manifest, uuid, nothing) === nothing || continue
        resolve_cmd = Pkg.in_repl_mode() ? "pkg> resolve" : "Pkg.resolve()"
        rm_cmd = Pkg.in_repl_mode() ? "pkg> rm $name" : "Pkg.rm(\"$name\")"
        instantiate_cmd = Pkg.in_repl_mode() ? "pkg> instantiate" : "Pkg.instantiate()"
        pkgerror(
            "`$name` is a direct dependency, but does not appear in the manifest.",
            " If you intend `$name` to be a direct dependency, run `$resolve_cmd` to populate the manifest.",
            " Otherwise, remove `$name` with `$rm_cmd`.",
            " Finally, run `$instantiate_cmd` again."
        )
    end
    # check if all source code and artifacts are downloaded to exit early
    if Operations.is_instantiated(ctx.env, workspace; platform)
        allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)
        return
    end

    if workspace
        pkgs = Operations.load_all_deps(ctx.env)
    else
        pkgs = Operations.load_all_deps_loadable(ctx.env)
    end
    try
        # First try without updating the registry
        Operations.check_registered(ctx.registries, pkgs)
    catch e
        if !(e isa PkgError) || update_registry == false
            rethrow(e)
        end
        Operations.update_registries(ctx; force = false)
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
        let repo_source = repo_source
            LibGit2.with(GitTools.ensure_clone(ctx.io, repo_path, repo_source; isbare = true)) do repo
                # We only update the clone if the tree hash can't be found
                tree_hash_object = tree_hash(repo, string(pkg.tree_hash))
                if tree_hash_object === nothing
                    GitTools.fetch(ctx.io, repo, repo_source; refspecs = Types.refspecs)
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
    Operations.download_artifacts(ctx; platform, verbose)
    # Run build scripts
    allow_build && Operations.build_versions(ctx, union(new_apply, new_git); verbose = verbose)

    return allow_autoprecomp && Pkg._auto_precompile(ctx, already_instantiated = true)
end


@deprecate status(mode::PackageMode) status(mode = mode)

function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool = false, mode = PKGMODE_PROJECT, workspace::Bool = false, outdated::Bool = false, compat::Bool = false, extensions::Bool = false, io::IO = stdout_f())
    if compat
        diff && pkgerror("Compat status has no `diff` mode")
        outdated && pkgerror("Compat status has no `outdated` mode")
        extensions && pkgerror("Compat status has no `extensions` mode")
        Operations.print_compat(ctx, pkgs; io)
    else
        Operations.status(ctx.env, ctx.registries, pkgs; mode, git_diff = diff, io, outdated, extensions, workspace)
    end
    return nothing
end


function activate(; temp = false, shared = false, prev = false, io::IO = stderr_f())
    shared && pkgerror("Must give a name for a shared environment")
    temp && return activate(mktempdir(); io = io)
    if prev
        if isempty(PREV_ENV_PATH[])
            pkgerror("No previously active environment found")
        else
            return activate(PREV_ENV_PATH[]; io = io)
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
    return if uuid !== nothing
        entry = manifest_info(ctx.env.manifest, uuid)
        if entry.path !== nothing
            return joinpath(dirname(ctx.env.manifest_file), entry.path::String)
        end
    end
end
function activate(path::AbstractString; shared::Bool = false, temp::Bool = false, io::IO = stderr_f())
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
    return try
        f()
    finally
        Base.ACTIVE_PROJECT[] = old
    end
end

function _compat(ctx::Context, pkg::String, compat_str::Union{Nothing, String}; current::Bool = false, io = nothing, kwargs...)
    if current
        if compat_str !== nothing
            pkgerror("`current` is true, but `compat_str` is not nothing. This is not allowed.")
        end
        return set_current_compat(ctx, pkg; io = io)
    end
    io = something(io, ctx.io)
    pkg = pkg == "Julia" ? "julia" : pkg
    isnothing(compat_str) || (compat_str = string(strip(compat_str, '"')))
    existing_compat = Operations.get_compat_str(ctx.env.project, pkg)
    # Double check before deleting a compat entry issue/3567
    if isinteractive() && (isnothing(compat_str) || isempty(compat_str))
        if !isnothing(existing_compat)
            ans = Base.prompt(stdin, ctx.io, "No compat string was given. Delete existing compat entry `$pkg = $(repr(existing_compat))`? [y]/n", default = "y")
            if lowercase(ans) !== "y"
                return
            end
        end
    end
    if haskey(ctx.env.project.deps, pkg) || pkg == "julia"
        success = Operations.set_compat(ctx.env.project, pkg, isnothing(compat_str) ? nothing : isempty(compat_str) ? nothing : compat_str)
        success === false && pkgerror("invalid compat version specifier \"$(compat_str)\"")
        write_env(ctx.env)
        if isnothing(compat_str) || isempty(compat_str)
            printpkgstyle(io, :Compat, "entry removed:\n  $pkg = $(repr(existing_compat))")
        else
            printpkgstyle(io, :Compat, "entry set:\n  $(pkg) = $(repr(compat_str))")
        end
        printpkgstyle(io, :Resolve, "checking for compliance with the new compat rules...")
        try
            resolve(ctx)
        catch e
            if e isa ResolverError || e isa ResolverTimeoutError
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
function compat(ctx::Context = Context(); current::Bool = false, kwargs...)
    if current
        return set_current_compat(ctx; kwargs...)
    end
    return _compat(ctx; kwargs...)
end
compat(pkg::String, compat_str::Union{Nothing, String} = nothing; kwargs...) = _compat(Context(), pkg, compat_str; kwargs...)


function set_current_compat(ctx::Context, target_pkg::Union{Nothing, String} = nothing; io = nothing)
    io = something(io, ctx.io)
    updated_deps = String[]

    deps_to_process = if target_pkg !== nothing
        # Process only the specified package
        if haskey(ctx.env.project.deps, target_pkg)
            [(target_pkg, ctx.env.project.deps[target_pkg])]
        else
            pkgerror("Package $(target_pkg) not found in project dependencies")
        end
    else
        # Process all packages (existing behavior)
        collect(ctx.env.project.deps)
    end

    # Process regular package dependencies
    for (dep, uuid) in deps_to_process
        compat_str = Operations.get_compat_str(ctx.env.project, dep)
        if target_pkg !== nothing || isnothing(compat_str)
            entry = get(ctx.env.manifest, uuid, nothing)
            entry === nothing && continue
            v = entry.version
            v === nothing && continue
            pkgversion = string(Base.thispatch(v))
            Operations.set_compat(ctx.env.project, dep, pkgversion) ||
                pkgerror("invalid compat version specifier \"$(pkgversion)\"")
            push!(updated_deps, dep)
        end
    end

    # Also handle Julia compat entry when processing all packages (not when targeting a specific package)
    if target_pkg === nothing
        julia_compat_str = Operations.get_compat_str(ctx.env.project, "julia")
        if isnothing(julia_compat_str)
            # Set julia compat to current running version
            julia_version = string(Base.thispatch(VERSION))
            Operations.set_compat(ctx.env.project, "julia", julia_version) ||
                pkgerror("invalid compat version specifier \"$(julia_version)\"")
            push!(updated_deps, "julia")
        end
    end

    # Update messaging
    if isempty(updated_deps)
        if target_pkg !== nothing
            printpkgstyle(io, :Info, "$(target_pkg) already has a compat entry or is not in manifest. No changes made.", color = Base.info_color())
        else
            printpkgstyle(io, :Info, "no missing compat entries found. No changes made.", color = Base.info_color())
        end
    elseif length(updated_deps) == 1
        printpkgstyle(io, :Info, "new entry set for $(only(updated_deps)) based on its current version", color = Base.info_color())
    else
        printpkgstyle(io, :Info, "new entries set for $(join(updated_deps, ", ", " and ")) based on their current versions", color = Base.info_color())
    end

    write_env(ctx.env)
    return Operations.print_compat(ctx; io)
end
set_current_compat(; kwargs...) = set_current_compat(Context(); kwargs...)

#######
# why #
#######

function why(ctx::Context, pkgs::Vector{PackageSpec}; io::IO, workspace::Bool = false, kwargs...)
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

    project_deps = Set(values(ctx.env.project.deps))

    if workspace
        for (_, project) in ctx.env.workspace
            union!(project_deps, values(project.deps))
        end
    end

    function find_paths!(final_paths, current, path = UUID[])
        push!(path, current)
        current in project_deps && push!(final_paths, path) # record once we've traversed to a project dep
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
        return
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
        delimiter = sprint((io, args) -> printstyled(io, args...; color = :light_green), "→", context = io)
        for path in final_paths_names
            println(io, "  ", join(path, " $delimiter "))
        end
    end
    return
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

function add_snapshot_to_undo(env = nothing)
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
    deleteat!(state.entries, 1:(state.idx - 1))
    pushfirst!(state.entries, snapshot)
    state.idx = 1

    return resize!(state.entries, min(length(state.entries), max_undo_limit))
end

undo(ctx = Context()) = redo_undo(ctx, :undo, 1)
redo(ctx = Context()) = redo_undo(ctx, :redo, -1)
function redo_undo(ctx, mode::Symbol, direction::Int)
    @assert direction == 1 || direction == -1
    state = get(undo_entries, ctx.env.project_file, nothing)
    state === nothing && pkgerror("no undo state for current project")
    state.idx == (mode === :redo ? 1 : length(state.entries)) && pkgerror("$mode: no more states left")

    state.idx += direction
    snapshot = state.entries[state.idx]
    ctx.env.manifest, ctx.env.project = snapshot.manifest, snapshot.project
    write_env(ctx.env; update_undo = false)
    return Operations.show_update(ctx.env, ctx.registries; io = ctx.io)
end


function setprotocol!(;
        domain::AbstractString = "github.com",
        protocol::Union{Nothing, AbstractString} = nothing
    )
    GitTools.setprotocol!(domain = domain, protocol = protocol)
    return nothing
end

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

function handle_package_input!(pkg::PackageSpec)
    if pkg.path !== nothing && pkg.url !== nothing
        pkgerror("Conflicting `path` and `url` in PackageSpec")
    end
    if pkg.repo.source !== nothing || pkg.repo.rev !== nothing || pkg.repo.subdir !== nothing
        pkgerror("`repo` is a private field of PackageSpec and should not be set directly")
    end
    pkg.repo = Types.GitRepo(
        rev = pkg.rev, source = pkg.url !== nothing ? pkg.url : pkg.path,
        subdir = pkg.subdir
    )
    pkg.path = nothing
    pkg.tree_hash = nothing
    if pkg.version === nothing
        pkg.version = VersionSpec()
    end
    if !(pkg.version isa VersionNumber)
        pkg.version = VersionSpec(pkg.version)
    end
    return pkg.uuid = pkg.uuid isa String ? UUID(pkg.uuid) : pkg.uuid
end

function upgrade_manifest(man_path::String)
    dir = mktempdir()
    cp(man_path, joinpath(dir, "Manifest.toml"))
    Pkg.activate(dir) do
        Pkg.upgrade_manifest()
    end
    return mv(joinpath(dir, "Manifest.toml"), man_path, force = true)
end
function upgrade_manifest(ctx::Context = Context())
    before_format = ctx.env.manifest.manifest_format
    if before_format == v"2.1"
        pkgerror("Format of manifest file at `$(ctx.env.manifest_file)` already up to date: manifest_format == $(before_format)")
    elseif before_format != v"1.0" && before_format != v"2.0"
        pkgerror("Format of manifest file at `$(ctx.env.manifest_file)` version is unrecognized: manifest_format == $(before_format)")
    end
    ctx.env.manifest.manifest_format = v"2.1"
    Types.write_manifest(ctx.env)
    printpkgstyle(ctx.io, :Updated, "Format of manifest file at `$(ctx.env.manifest_file)` updated from v$(before_format.major).$(before_format.minor) to v2.1")
    return nothing
end

"""
    auto_gc(on::Bool)

Enable or disable automatic garbage collection of packages and artifacts.
Return the previous state.
"""
function auto_gc(on::Bool)
    pstate = _auto_gc_enabled[]
    _auto_gc_enabled[] = on

    return pstate
end

"""
    readonly()

Return whether the current environment is readonly.
"""
function readonly(ctx::Context = Context())
    return ctx.env.project.readonly
end

"""
    readonly(on::Bool)

Enable or disable readonly mode for the current environment.
Return the previous state.
"""
function readonly(on::Bool, ctx::Context = Context())
    previous_state = ctx.env.project.readonly
    ctx.env.project.readonly = on
    Types.write_env(ctx.env; skip_readonly_check = true)

    mode_str = on ? "enabled" : "disabled"
    printpkgstyle(ctx.io, :Updated, "Readonly mode $mode_str for project at $(ctx.env.project_file)")

    return previous_state
end

end # module
