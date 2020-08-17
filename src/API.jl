# This file is a part of Julia. License is MIT: https://julialang.org/license

module API

using UUIDs
using Printf
import Random
using Dates
import LibGit2

import ..depots, ..depots1, ..logdir, ..devdir
import ..Operations, ..GitTools, ..Pkg, ..UPDATED_REGISTRY_THIS_SESSION
using ..Types, ..TOML
using ..Types: VersionTypes
using ..BinaryPlatforms
using ..Artifacts: artifact_paths

include("generate.jl")

dependencies() = dependencies(Context())
function dependencies(ctx::Context)::Dict{UUID, PackageInfo}
    pkgs = Operations.load_all_deps(ctx)
    return Dict(pkg.uuid => Operations.package_info(ctx, pkg) for pkg in pkgs)
end
function dependencies(fn::Function, uuid::UUID)
    dep = get(dependencies(), uuid, nothing)
    if dep === nothing
        pkgerror("depenendency with UUID `$uuid` does not exist")
    end
    fn(dep)
end

project() = project(Context())
function project(ctx::Context)::ProjectInfo
    return ProjectInfo(
        name         = ctx.env.pkg === nothing ? nothing : ctx.env.pkg.name,
        uuid         = ctx.env.pkg === nothing ? nothing : ctx.env.pkg.uuid,
        version      = ctx.env.pkg === nothing ? nothing : ctx.env.pkg.version,
        ispackage    = ctx.env.pkg !== nothing,
        dependencies = ctx.env.project.deps,
        path         = ctx.env.project_file
    )
end

function check_package_name(x::AbstractString, mode=nothing)
    if !Base.isidentifier(x)
        message = "`$x` is not a valid package name"
        if mode !== nothing && any(occursin.(['\\','/'], x)) # maybe a url or a path
            message *= "\nThe argument appears to be a URL or path, perhaps you meant " *
                "`Pkg.$mode(url=\"...\")` or `Pkg.$mode(path=\"...\")`."
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
for f in (:develop, :add, :rm, :up, :pin, :free, :test, :build, :status)
    @eval begin
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...)          = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        $f(pkgs::Vector{PackageSpec}; kwargs...)               = $f(Context(), pkgs; kwargs...)
        $f(ctx::Context; kwargs...) = $f(ctx, PackageSpec[]; kwargs...)
        function $f(; name::Union{Nothing,AbstractString}=nothing, uuid::Union{Nothing,String,UUID}=nothing,
                      version::Union{VersionNumber, String, VersionSpec, Nothing}=nothing,
                      url=nothing, rev=nothing, path=nothing, mode=PKGMODE_PROJECT, subdir=nothing, kwargs...)
            pkg = Package(name=name, uuid=uuid, version=version, url=url, rev=rev, path=path, mode=mode, subdir=subdir)
            # Pkg.status takes a mode argument as well which is a bit ambiguous with the
            # mode argument to the PackageSpec but probably not a problem in practice
            if $f === status
                kwargs = merge((;kwargs...), (:mode => mode,))
            end
            # Handle $f() case
            if pkg == Package()
                $f(PackageSpec[]; kwargs...)
            else
                $f(pkg; kwargs...)
            end
        end
        function $f(pkgs::Vector{<:NamedTuple}; kwargs...)
            $f([Package(;pkg...) for pkg in pkgs]; kwargs...)
        end
    end
end

function develop(ctx::Context, pkgs::Vector{PackageSpec}; shared::Bool=true,
                 preserve::PreserveLevel=PRESERVE_TIERED, platform::Platform=platform_key_abi(), kwargs...)
    require_not_empty(pkgs, :develop)
    foreach(pkg -> check_package_name(pkg.name, :develop), pkgs)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        if pkg.name == "julia" # if julia is passed as a package the solver gets tricked
            pkgerror("`julia` is not a valid package name")
        end
        pkg.name === nothing || check_package_name(pkg.name, "develop")
        if pkg.name === nothing && pkg.uuid === nothing && pkg.repo.source === nothing
            pkgerror("name, UUID, URL, or filesystem path specification required when calling `develop`")
        end
        if pkg.repo.rev !== nothing
            pkgerror("git revision specification invalid when calling `develop`:",
                     " `$(pkg.repo.rev)` specified for package $(err_rep(pkg))")
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
        if Types.collides_with_project(ctx, pkg)
            pkgerror("package $(err_rep(pkg)) has the same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    Operations.develop(ctx, pkgs, new_git; preserve=preserve, platform=platform)
    return
end

function add(ctx::Context, pkgs::Vector{PackageSpec}; preserve::PreserveLevel=PRESERVE_TIERED,
             platform::Platform=platform_key_abi(), kwargs...)
    require_not_empty(pkgs, :add)
    foreach(pkg -> check_package_name(pkg.name, :add), pkgs)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        if pkg.name == "julia" # if julia is passed as a package the solver gets tricked
            pkgerror("`julia` is not a valid package name")
        end
        if pkg.name === nothing && pkg.uuid === nothing && pkg.repo.source === nothing
            pkgerror("name, UUID, URL, or filesystem path specification required when calling `add`")
        end
        pkg.name === nothing || check_package_name(pkg.name, "add")
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

    Types.update_registries(ctx)

    project_deps_resolve!(ctx, pkgs)
    registry_resolve!(ctx, pkgs)
    stdlib_resolve!(pkgs)
    ensure_resolved(ctx, pkgs, registry=true)

    for pkg in pkgs
        if Types.collides_with_project(ctx, pkg)
            pkgerror("package $(err_rep(pkg)) has same name or UUID as the active project")
        end
        if length(findall(x -> x.uuid == pkg.uuid, pkgs)) > 1
            pkgerror("it is invalid to specify multiple packages with the same UUID: $(err_rep(pkg))")
        end
    end

    Operations.add(ctx, pkgs, new_git; preserve=preserve, platform=platform)
    return
end

function rm(ctx::Context, pkgs::Vector{PackageSpec}; mode=PKGMODE_PROJECT, kwargs...)
    require_not_empty(pkgs, :rm)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    foreach(pkg -> pkg.mode = mode, pkgs)

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

    Context!(ctx; kwargs...)

    project_deps_resolve!(ctx, pkgs)
    manifest_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)

    Operations.rm(ctx, pkgs)
    return
end

function up(ctx::Context, pkgs::Vector{PackageSpec};
            level::UpgradeLevel=UPLEVEL_MAJOR, mode::PackageMode=PKGMODE_PROJECT,
            update_registry::Bool=true, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    foreach(pkg -> pkg.mode = mode, pkgs)

    Context!(ctx; kwargs...)
    if update_registry
        Types.clone_default_registries(ctx)
        Types.update_registries(ctx; force=true)
    end
    Operations.prune_manifest(ctx)
    if isempty(pkgs)
        if mode == PKGMODE_PROJECT
            for (name::String, uuid::UUID) in ctx.env.project.deps
                push!(pkgs, PackageSpec(name=name, uuid=uuid))
            end
        elseif mode == PKGMODE_MANIFEST
            for (uuid, entry) in ctx.env.manifest
                push!(pkgs, PackageSpec(name=entry.name, uuid=uuid))
            end
        end
    else
        project_deps_resolve!(ctx, pkgs)
        manifest_resolve!(ctx, pkgs)
        ensure_resolved(ctx, pkgs)
    end
    Operations.up(ctx, pkgs, level)
    return
end

resolve(; kwargs...) = resolve(Context(); kwargs...)
function resolve(ctx::Context; kwargs...)
    up(ctx; level=UPLEVEL_FIXED, mode=PKGMODE_MANIFEST, update_registry=false, kwargs...)
    return nothing
end

function pin(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)
    require_not_empty(pkgs, :pin)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

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
        if pkg.version.ranges[1].lower != pkg.version.ranges[1].upper # TODO test this
            pkgerror("pinning a package requires a single version, not a versionrange")
        end
    end

    foreach(pkg -> pkg.mode = PKGMODE_PROJECT, pkgs)
    project_deps_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)
    Operations.pin(ctx, pkgs)
    return
end

function free(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)
    require_not_empty(pkgs, :free)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

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

    foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    manifest_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)

    find_registered!(ctx, UUID[pkg.uuid for pkg in pkgs])
    Operations.free(ctx, pkgs)
    return
end

function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, test_fn=nothing,
              julia_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              test_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              kwargs...)
    julia_args = Cmd(julia_args)
    test_args = Cmd(test_args)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)
    if isempty(pkgs)
        ctx.env.pkg === nothing && pkgerror("trying to test unnamed project") #TODO Allow this?
        push!(pkgs, ctx.env.pkg)
    else
        project_resolve!(ctx, pkgs)
        project_deps_resolve!(ctx, pkgs)
        manifest_resolve!(ctx, pkgs)
        ensure_resolved(ctx, pkgs)
    end
    Operations.test(ctx, pkgs; coverage=coverage, test_fn=test_fn, julia_args=julia_args, test_args=test_args)
    return
end

"""
    gc(ctx::Context=Context(); collect_delay::Period=Day(7), kwargs...)

Garbage-collect package and artifact installations by sweeping over all known
`Manifest.toml` and `Artifacts.toml` files, noting those that have been deleted, and then
finding artifacts and packages that are thereafter not used by any other projects.  This
method will only remove package versions and artifacts that have been continually un-used
for a period of `collect_delay`; which defaults to seven days.
"""
function gc(ctx::Context=Context(); collect_delay::Period=Day(7), kwargs...)
    Context!(ctx; kwargs...)
    env = ctx.env

    # First, we load in our `manifest_usage.toml` files which will tell us when our
    # "index files" (`Manifest.toml`, `Artifacts.toml`) were last used.  We will combine
    # this knowledge across depots, condensing it all down to a single entry per extant
    # index file, to manage index file growth with would otherwise continue unbounded. We
    # keep the lists of index files separated by depot so that we can write back condensed
    # versions that are only ever subsets of what we read out of them in the first place.

    # Collect last known usage dates of manifest and artifacts toml files, split by depot
    manifest_usage_by_depot = Dict{String, Dict{String, DateTime}}()
    artifact_usage_by_depot = Dict{String, Dict{String, DateTime}}()

    # Load manifest files from all depots
    for depot in depots()
        # When a manifest/artifact.toml is installed/used, we log it within the
        # `manifest_usage.toml` files within `write_env_usage()` and `bind_artifact!()`
        function collect_usage!(usage_data::Dict, usage_filepath)
            if !isfile(usage_filepath)
                return usage_data
            end

            for (filename, infos) in TOML.parse(String(read(usage_filepath)))
                # If this file was already listed in this index, update it with the later
                # information
                for info in infos
                    usage_data[filename] = max(
                        get(usage_data, filename, DateTime(0)),
                        DateTime(info["time"]),
                    )
                end
            end
            return usage_data
        end

        # Extract usage data from this depot, (taking only the latest state for each
        # tracked manifest/artifact.toml), then merge the usage values from each file
        # into the overall list across depots to create a single, coherent view across
        # all depots.
        manifest_usage_by_depot[depot] = Dict{String, DateTime}()
        artifact_usage_by_depot[depot] = Dict{String, DateTime}()
        collect_usage!(
            manifest_usage_by_depot[depot],
            joinpath(logdir(depot), "manifest_usage.toml"),
        )
        collect_usage!(
            artifact_usage_by_depot[depot],
            joinpath(logdir(depot), "artifact_usage.toml"),
        )
    end

    # Next, figure out which files are still extant
    all_index_files = vcat(
        unique(f for (_, files) in manifest_usage_by_depot for f in keys(files)),
        unique(f for (_, files) in artifact_usage_by_depot for f in keys(files)),
    )
    all_index_files = Set(filter(Pkg.isfile_nothrow, all_index_files))

    # Immediately write this back as condensed manifest_usage.toml files
    function write_condensed_usage(usage_by_depot, fname)
        for (depot, usage) in usage_by_depot
            # Keep only the keys of the files that are still extant
            usage = filter(p -> p[1] in all_index_files, usage)

            # Expand it back into a dict of arrays-of-dicts
            usage = Dict(k => [Dict("time" => v)] for (k, v) in usage)

            # Write it out to disk within this depot
            usage_path = joinpath(logdir(depot), fname)
            if !isempty(usage) || isfile(usage_path)
                open(usage_path, "w") do io
                    TOML.print(io, usage, sorted=true)
                end
            end
        end
    end
    write_condensed_usage(manifest_usage_by_depot, "manifest_usage.toml")
    write_condensed_usage(artifact_usage_by_depot, "artifact_usage.toml")

    # Next, we will process the manifest.toml and artifacts.toml files separately,
    # extracting from them the paths of the packages and artifacts that they reference.
    all_manifest_files = filter(f -> endswith(f, "Manifest.toml"), all_index_files)
    all_artifacts_files = filter(f -> !endswith(f, "Manifest.toml"), all_index_files)

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

    function process_artifacts_toml(path, packages_to_delete)
        # Not only do we need to check if this file doesn't exist, we also need to check
        # to see if it this artifact is contained within a package that is going to go
        # away.  This places an inherent ordering between marking packages and marking
        # artifacts; the package marking must be done first so that we can ensure that
        # all artifacts that are solely bound within such packages also get reaped.
        if any(startswith(path, package_dir) for package_dir in packages_to_delete)
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
            if isa(artifact_dict[name], Array)
                for platform_meta in artifact_dict[name]
                    append!(artifact_path_list, getpaths(platform_meta))
                end
            else
                append!(artifact_path_list, getpaths(artifact_dict[name]))
            end
        end
        return artifact_path_list
    end

    # Mark packages/artifacts as active or not by calling the appropriate
    function mark(process_func::Function, index_files; do_print=true)
        marked_paths = String[]
        for index_file in index_files
            # Check to see if it's still alive
            paths = process_func(index_file)
            if paths !== nothing
                # Print the path of this beautiful, extant file to the user
                do_print && println("        $(Types.pathrepr(index_file))")
                append!(marked_paths, paths)
            end
        end

        # Return the list of marked paths
        return Set(marked_paths)
    end

    gc_time = now()
    function merge_orphanages!(new_orphanage, paths, deletion_list, old_orphanage = Dict())
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
    printpkgstyle(ctx, :Active, "manifests:")
    packages_to_keep = mark(process_manifest_pkgs, all_manifest_files)

    # Do an initial scan of our depots to get a preliminary `packages_to_delete`.
    packages_to_delete = String[]
    for depot in depots()
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
        merge_orphanages!(Dict(), depot_orphaned_packages, packages_to_delete)
    end


    # Next, do the same for artifacts.  Note that we MUST do this after calculating
    # `packages_to_delete`, as `process_artifacts_toml()` uses it internally to discount
    # `Artifacts.toml` files that will be deleted by the future culling operation.
    printpkgstyle(ctx, :Active, "artifacts:")
    artifacts_to_keep = mark(x -> process_artifacts_toml(x, packages_to_delete), all_artifacts_files)
    repos_to_keep = mark(process_manifest_repos, all_manifest_files; do_print=false)

    # Collect all orphaned paths (packages, artifacts and repos that are not reachable).  These
    # are implicitly defined in that we walk all packages/artifacts installed, then if
    # they were not marked in the above steps, we reap them.
    packages_to_delete = String[]
    artifacts_to_delete = String[]
    repos_to_delete = String[]

    for depot in depots()
        # We track orphaned objects on a per-depot basis, writing out our `orphaned.toml`
        # tracking file immediately, only pushing onto the overall `*_to_delete` lists if
        # the package has been orphaned for at least a period of `collect_delay`
        depot_orphaned_packages = String[]
        depot_orphaned_artifacts = String[]
        depot_orphaned_repos = String[]

        # ??: This code block is identical to one a bit above
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

        # Read in this depot's `orphaned.toml` file:
        orphanage_file = joinpath(logdir(depot), "orphaned.toml")
        new_orphanage = Dict{String, DateTime}()
        old_orphanage = try
            TOML.parse(String(read(orphanage_file)))
        catch
            Dict{String, DateTime}()
        end

        # Update the package and artifact lists of things to delete, and
        # create the `new_orphanage` list for this depot.
        merge_orphanages!(new_orphanage, depot_orphaned_packages, packages_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_artifacts, artifacts_to_delete, old_orphanage)
        merge_orphanages!(new_orphanage, depot_orphaned_repos, repos_to_delete, old_orphanage)

        # Write out the `new_orphanage` for this depot
        if !isempty(new_orphanage) || isfile(orphanage_file)
            mkpath(dirname(orphanage_file))
            open(orphanage_file, "w") do io
                TOML.print(io, new_orphanage, sorted=true)
            end
        end
    end

    # Next, we calculate the space savings we're about to gain!
    pretty_byte_str = (size) -> begin
        bytes, mb = Base.prettyprint_getunits(size, length(Base._mem_units), Int64(1024))
        return @sprintf("%.3f %s", bytes, Base._mem_units[mb])
    end

    function recursive_dir_size(path)
        size = 0
        for (root, dirs, files) in walkdir(path)
            for file in files
                path = joinpath(root, file)
                try
                    size += lstat(path).size
                catch
                    @warn "Failed to calculate size of $path"
                end
            end
        end
        return size
    end

    # Delete paths for unreachable package versions and artifacts, and computing size saved
    function delete_path(path)
        path_size = recursive_dir_size(path)
        try
            Base.rm(path; recursive=true)
        catch
            @warn "Failed to delete $path"
        end
        printpkgstyle(ctx, :Deleted, Types.pathrepr(path) * " (" * pretty_byte_str(path_size) * ")")
        return path_size
    end

    package_space_freed = 0
    repo_space_freed = 0
    artifact_space_freed = 0
    for path in packages_to_delete
        package_space_freed += delete_path(path)
    end
    for path in repos_to_delete
        repo_space_freed += delete_path(path)
    end
    for path in artifacts_to_delete
        artifact_space_freed += delete_path(path)
    end

    # Prune package paths that are now empty
    for depot in depots()
        packagedir = abspath(depot, "packages")
        !isdir(packagedir) && continue

        for name in readdir(packagedir)
            name_path = joinpath(packagedir, name)
            !isdir(name_path) && continue
            !isempty(readdir(name_path)) && continue

            Base.rm(name_path)
        end
    end

    ndel_pkg = length(packages_to_delete)
    ndel_repos = length(repos_to_delete)
    ndel_art = length(artifacts_to_delete)

    if ndel_pkg > 0
        s = ndel_pkg == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(package_space_freed)
        printpkgstyle(ctx, :Deleted, "$(ndel_pkg) package installation$(s) ($bytes_saved_string)")
    end
    if ndel_repos > 0
        s = ndel_repos == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(repo_space_freed)
        printpkgstyle(ctx, :Deleted, "$(ndel_repos) repo$(s) ($bytes_saved_string)")
    end
    if ndel_art > 0
        s = ndel_art == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(artifact_space_freed)
        printpkgstyle(ctx, :Deleted, "$(ndel_art) artifact installation$(s) ($bytes_saved_string)")
    end
    if ndel_pkg == 0 & ndel_art == 0 && ndel_repos == 0
        printpkgstyle(ctx, :Deleted, "no artifacts, repos or packages")
    end

    return
end

function build(ctx::Context, pkgs::Vector{PackageSpec}; verbose=false, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
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
    project_resolve!(ctx, pkgs)
    foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    manifest_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)
    Operations.build(ctx, pkgs, verbose)
end

precompile() = precompile(Context())
function precompile(ctx::Context)
    printpkgstyle(ctx, :Precompiling, "project...")

    pkgids = [Base.PkgId(uuid, name) for (name, uuid) in ctx.env.project.deps if !is_stdlib(uuid)]
    if ctx.env.pkg !== nothing && isfile( joinpath( dirname(ctx.env.project_file), "src", ctx.env.pkg.name * ".jl") )
        push!(pkgids, Base.PkgId(ctx.env.pkg.uuid, ctx.env.pkg.name))
    end

    # TODO: since we are a complete list, but not topologically sorted, handling of recursion will be completely at random
    for pkg in pkgids
        paths = Base.find_all_in_cache_path(pkg)
        sourcepath = Base.locate_package(pkg)
        sourcepath === nothing && continue
        # Heuristic for when precompilation is disabled
        occursin(r"\b__precompile__\(\s*false\s*\)", read(sourcepath, String)) && continue
        stale = true
        for path_to_try in paths::Vector{String}
            staledeps = Base.stale_cachefile(sourcepath, path_to_try)
            staledeps === true && continue
            # TODO: else, this returns a list of packages that may be loaded to make this valid (the topological list)
            stale = false
            break
        end
        if stale
            try
                Base.compilecache(pkg, sourcepath)
            catch
            end
        end
    end
    nothing
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
function instantiate(ctx::Context; manifest::Union{Bool, Nothing}=nothing,
                     update_registry::Bool=true, verbose::Bool=false,
                     platform::Platform=platform_key_abi(), kwargs...)
    Context!(ctx; kwargs...)
    if !isfile(ctx.env.project_file) && isfile(ctx.env.manifest_file)
        _manifest = Pkg.Types.read_manifest(ctx.env.manifest_file)
        deps = Dict()
        for (uuid, pkg) in _manifest
            if pkg.name in keys(deps)
                # TODO, query what package to put in Project when in interactive mode?
                pkgerror("cannot instantiate a manifest without project file when the manifest has multiple packages with the same name ($(pkg.name))")
            end
            deps[pkg.name] = string(uuid)
        end
        Types.write_project(Dict("deps" => deps), ctx.env.project_file)
        return instantiate(Context(); manifest=manifest, update_registry=update_registry, verbose=verbose, kwargs...)
    end
    if (!isfile(ctx.env.manifest_file) && manifest === nothing) || manifest == false
        up(ctx; update_registry=update_registry)
        return
    end
    if !isfile(ctx.env.manifest_file) && manifest == true
        pkgerror("expected manifest file at `$(ctx.env.manifest_file)` but it does not exist")
    end
    Operations.prune_manifest(ctx)
    for (name, uuid) in ctx.env.project.deps
        get(ctx.env.manifest, uuid, nothing) === nothing || continue
        pkgerror("`$name` is a direct dependency, but does not appear in the manifest.",
                 " If you intend `$name` to be a direct dependency, run `Pkg.resolve()` to populate the manifest.",
                 " Otherwise, remove `$name` with `Pkg.rm(\"$name\")`.",
                 " Finally, run `Pkg.instantiate()` again.")
    end
    # TODO: seems to be a bug in is_instantiated on the line below so we have to download
    # artifacts here even though we do the same at the end of this function
    Operations.download_artifacts(ctx, [dirname(ctx.env.manifest_file)]; platform=platform, verbose=verbose)
    # check if all source code and artifacts are downloaded to exit early
    Operations.is_instantiated(ctx) && return

    pkgs = Operations.load_all_deps(ctx)
    try
        # First try without updating the registry
        Operations.check_registered(ctx, pkgs)
    catch e
        if !(e isa PkgError) || update_registries == false
            rethrow(e)
        end
        Types.update_registries(ctx)
        Operations.check_registered(ctx, pkgs)
    end
    new_git = UUID[]
    # Handling packages tracking repos
    for pkg in pkgs
        pkg.repo.source !== nothing || continue
        sourcepath = Operations.source_path(ctx, pkg)
        isdir(sourcepath) && continue
        ## Download repo at tree hash
        # determine canonical form of repo source
        if isurl(pkg.repo.source)
            repo_source = pkg.repo.source
        else
            repo_source = normpath(joinpath(dirname(ctx.env.project_file), pkg.repo.source))
        end
        if !isurl(repo_source) && !isdir(repo_source)
            pkgerror("Did not find path `$(repo_source)` for $(err_rep(pkg))")
        end
        repo_path = Types.add_repo_cache_path(repo_source)
        LibGit2.with(GitTools.ensure_clone(ctx, repo_path, pkg.repo.source; isbare=true)) do repo
            # We only update the clone if the tree hash can't be found
            tree_hash_object = tree_hash(repo, string(pkg.tree_hash))
            if tree_hash_object === nothing
                GitTools.fetch(ctx, repo, pkg.repo.source; refspecs=Types.refspecs)
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

    # Install all packages
    new_apply = Operations.download_source(ctx, pkgs)
    # Install all artifacts
    Operations.download_artifacts(ctx, pkgs; platform=platform, verbose=verbose)
    # Run build scripts
    Operations.build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git); verbose=verbose)
end


@deprecate status(mode::PackageMode) status(mode=mode)

function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool=false, mode=PKGMODE_PROJECT,
                io::IO=stdout, kwargs...)
    Context!(ctx; io=io, kwargs...)
    Operations.status(ctx, pkgs, mode=mode, git_diff=diff)
    return nothing
end


function activate(;temp=false,shared=false)
    shared && pkgerror("Must give a name for a shared environment")
    temp && return activate(mktempdir())
    Base.ACTIVE_PROJECT[] = nothing
    p = Base.active_project()
    p === nothing || printpkgstyle(Context(), :Activating, "environment at $(pathrepr(p))")
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
        entry = manifest_info(ctx, uuid)
        if entry.path !== nothing
            return joinpath(dirname(ctx.env.project_file), entry.path)
        end
    end
end
function activate(path::AbstractString; shared::Bool=false, temp::Bool=false)
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
    Base.ACTIVE_PROJECT[] = Base.load_path_expand(fullpath)
    p = Base.active_project()
    if p !== nothing
        n = ispath(p) ? "" : "new "
        printpkgstyle(Context(), :Activating, "$(n)environment at $(pathrepr(p))")
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
UndoState() = UndoState(0, UndoState[])
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
    if !isempty(state.entries) && env.project == env.original_project && env.manifest == env.original_manifest
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
    Operations.show_update(ctx)
end


function setprotocol!(;
    domain::AbstractString="github.com",
    protocol::Union{Nothing, AbstractString}=nothing
)
    GitTools.setprotocol!(domain=domain, protocol=protocol)
    return nothing
end

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

# API constructor
function Package(;name::Union{Nothing,AbstractString} = nothing,
                 uuid::Union{Nothing,String,UUID} = nothing,
                 version::Union{VersionNumber, String, VersionSpec, Nothing} = nothing,
                 url = nothing, rev = nothing, path=nothing, mode::PackageMode = PKGMODE_PROJECT,
                 subdir = nothing)
    if path !== nothing && url !== nothing
        pkgerror("`path` and `url` are conflicting specifications")
    end
    repo = Types.GitRepo(rev = rev, source = url !== nothing ? url : path, subdir = subdir)
    version = version === nothing ? VersionSpec() : VersionSpec(version)
    uuid = uuid isa String ? UUID(uuid) : uuid
    PackageSpec(;name=name, uuid=uuid, version=version, mode=mode, path=nothing,
                repo=repo, tree_hash=nothing)
end
Package(name::AbstractString) = PackageSpec(name)
Package(name::AbstractString, uuid::UUID) = PackageSpec(name, uuid)
Package(name::AbstractString, uuid::UUID, version::VersionTypes) = PackageSpec(name, uuid, version)

end # module
