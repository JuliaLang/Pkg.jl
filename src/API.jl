# This file is a part of Julia. License is MIT: https://julialang.org/license

module API

using UUIDs
using Printf
import Random
using Dates
import LibGit2

import ..depots, ..depots1, ..logdir, ..devdir
import ..Operations, ..Display, ..GitTools, ..Pkg, ..UPDATED_REGISTRY_THIS_SESSION
using ..Types, ..TOML
using Pkg.Types: VersionTypes
using ..BinaryPlatforms
using ..Artifacts: artifact_paths


preview_info() = printstyled("───── Preview mode ─────\n"; color=Base.info_color(), bold=true)

include("generate.jl")

function check_package_name(x::AbstractString, mode=nothing)
    if !(occursin(Pkg.REPLMode.name_re, x))
        message = "$x is not a valid packagename."
        if mode !== nothing && any(occursin.(['\\','/'], x)) # maybe a url or a path
            message *= "\nThe argument appears to be a URL or path, perhaps you meant " *
                "`Pkg.$mode(PackageSpec(url=\"...\"))` or `Pkg.$mode(PackageSpec(path=\"...\"))`."
        end
        pkgerror(message)
    end
    return PackageSpec(x)
end

develop(pkg::Union{AbstractString, PackageSpec}; kwargs...) = develop([pkg]; kwargs...)
develop(pkgs::Vector{<:AbstractString}; kwargs...) =
    develop([check_package_name(pkg, :develop) for pkg in pkgs]; kwargs...)
develop(pkgs::Vector{PackageSpec}; kwargs...)      = develop(Context(), pkgs; kwargs...)
function develop(ctx::Context, pkgs::Vector{PackageSpec}; shared::Bool=true,
                 strict::Bool=false, platform::Platform=platform_key_abi(), kwargs...)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        # if julia is passed as a package the solver gets tricked
        pkg.name != "julia" || pkgerror("Trying to develop julia as a package")
        pkg.repo.rev === nothing || pkgerror("git revision can not be given to `develop`")
        pkg.name !== nothing || pkg.uuid !== nothing || pkg.repo.url !== nothing ||
            pkgerror("A package must be specified by `name`, `uuid`, `url`, or `path`.")
        pkg.version == VersionSpec() ||
            pkgerror("Can not specify version when tracking a repo.")
    end

    ctx.preview && preview_info()

    new_git = handle_repos_develop!(ctx, pkgs, shared)

    any(pkg -> Types.collides_with_project(ctx, pkg), pkgs) &&
        pkgerror("Cannot `develop` package with the same name or uuid as the project")

    Operations.develop(ctx, pkgs, new_git; strict=strict, platform=platform)
    ctx.preview && preview_info()
    return
end

add(pkg::Union{AbstractString, PackageSpec}; kwargs...) = add([pkg]; kwargs...)
add(pkgs::Vector{<:AbstractString}; kwargs...) =
    add([check_package_name(pkg, :add) for pkg in pkgs]; kwargs...)
add(pkgs::Vector{PackageSpec}; kwargs...)      = add(Context(), pkgs; kwargs...)
function add(ctx::Context, pkgs::Vector{PackageSpec}; strict::Bool=false,
             platform::Platform=platform_key_abi(), kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    for pkg in pkgs
        # if julia is passed as a package the solver gets tricked; this catches the error early on
        pkg.name == "julia" && pkgerror("Trying to add julia as a package")
        pkg.name !== nothing || pkg.uuid !== nothing || pkg.repo.url !== nothing ||
            pkgerror("A package must be specified by `name`, `uuid`, `url`, or `path`.")
        if (pkg.repo.url !== nothing || pkg.repo.rev !== nothing)
            pkg.version == VersionSpec() ||
                pkgerror("Can not specify version when tracking a repo.")
        end
    end

    ctx.preview && preview_info()
    Types.update_registries(ctx)

    repo_pkgs = [pkg for pkg in pkgs if (pkg.repo.url !== nothing || pkg.repo.rev !== nothing)]
    new_git = handle_repos_add!(ctx, repo_pkgs)
    # repo + unpinned -> name, uuid, repo.rev, repo.url, tree_hash
    # repo + pinned -> name, uuid, tree_hash

    project_deps_resolve!(ctx, pkgs)
    registry_resolve!(ctx, pkgs)
    stdlib_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs, registry=true)

    any(pkg -> Types.collides_with_project(ctx, pkg), pkgs) &&
        pkgerror("Cannot add package with the same name or uuid as the project")

    Operations.add(ctx, pkgs, new_git; strict=strict, platform=platform)
    ctx.preview && preview_info()
    return
end

rm(pkg::Union{AbstractString, PackageSpec}; kwargs...) = rm([pkg]; kwargs...)
rm(pkgs::Vector{<:AbstractString}; kwargs...)          = rm([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
rm(pkgs::Vector{PackageSpec}; kwargs...)               = rm(Context(), pkgs; kwargs...)

function rm(ctx::Context, pkgs::Vector{PackageSpec}; mode=PKGMODE_PROJECT, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    foreach(pkg -> pkg.mode = mode, pkgs)

    for pkg in pkgs
        pkg.name !== nothing || pkg.uuid !== nothing ||
            pkgerror("Must specify package by either `name` or `uuid`.")
        if !(pkg.version == VersionSpec() && pkg.pinned == false &&
             pkg.tree_hash === nothing && pkg.repo.url === nothing &&
             pkg.repo.rev === nothing && pkg.path === nothing)
            pkgerror("Package may only be specified by either `name` or `uuid`")
        end
    end

    Context!(ctx; kwargs...)
    ctx.preview && preview_info()

    project_deps_resolve!(ctx, pkgs)
    manifest_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)

    Operations.rm(ctx, pkgs)
    ctx.preview && preview_info()
    return
end

up(ctx::Context; kwargs...)                            = up(ctx, PackageSpec[]; kwargs...)
up(; kwargs...)                                        = up(PackageSpec[]; kwargs...)
up(pkg::Union{AbstractString, PackageSpec}; kwargs...) = up([pkg]; kwargs...)
up(pkgs::Vector{<:AbstractString}; kwargs...)          = up([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
up(pkgs::Vector{PackageSpec}; kwargs...)               = up(Context(), pkgs; kwargs...)

function up(ctx::Context, pkgs::Vector{PackageSpec};
            level::UpgradeLevel=UPLEVEL_MAJOR, mode::PackageMode=PKGMODE_PROJECT,
            update_registry::Bool=true, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    foreach(pkg -> pkg.mode = mode, pkgs)

    Context!(ctx; kwargs...)
    ctx.preview && preview_info()
    if update_registry
        Types.clone_default_registries(ctx)
        Types.update_registries(ctx; force=true)
    end
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
    ctx.preview && preview_info()
    return
end

resolve(ctx::Context=Context()) =
    up(ctx, level=UPLEVEL_FIXED, mode=PKGMODE_MANIFEST, update_registry=false)

pin(pkg::Union{AbstractString, PackageSpec}; kwargs...) = pin([pkg]; kwargs...)
pin(pkgs::Vector{<:AbstractString}; kwargs...)          = pin([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
pin(pkgs::Vector{PackageSpec}; kwargs...)               = pin(Context(), pkgs; kwargs...)

function pin(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()

    for pkg in pkgs
        pkg.name !== nothing || pkg.uuid !== nothing ||
            pkgerror("Must specify package by either `name` or `uuid`.")
        pkg.repo.url === nothing || pkgerror("Can not specify `repo` url")
        pkg.repo.rev === nothing || pkgerror("Can not specify `repo` rev")
    end

    foreach(pkg -> pkg.mode = PKGMODE_PROJECT, pkgs)
    project_deps_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)
    Operations.pin(ctx, pkgs)
    return
end


free(pkg::Union{AbstractString, PackageSpec}; kwargs...) = free([pkg]; kwargs...)
free(pkgs::Vector{<:AbstractString}; kwargs...)          = free([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
free(pkgs::Vector{PackageSpec}; kwargs...)               = free(Context(), pkgs; kwargs...)

function free(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()

    for pkg in pkgs
        pkg.name !== nothing || pkg.uuid !== nothing ||
            pkgerror("Must specify package by either `name` or `uuid`.")
        if !(pkg.version == VersionSpec() && pkg.pinned == false &&
             pkg.tree_hash === nothing && pkg.repo.url === nothing &&
             pkg.repo.rev === nothing && pkg.path === nothing)
            pkgerror("Package may only be specified by either `name` or `uuid`")
        end
    end

    foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    manifest_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)

    find_registered!(ctx, UUID[pkg.uuid for pkg in pkgs])
    Operations.free(ctx, pkgs)
    return
end

test(;kwargs...)                                         = test(PackageSpec[]; kwargs...)
test(pkg::Union{AbstractString, PackageSpec}; kwargs...) = test([pkg]; kwargs...)
test(pkgs::Vector{<:AbstractString}; kwargs...)          = test([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
test(pkgs::Vector{PackageSpec}; kwargs...)               = test(Context(), pkgs; kwargs...)
function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, test_fn=nothing,
              julia_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              test_args::Union{Cmd, AbstractVector{<:AbstractString}}=``,
              kwargs...)
    julia_args = Cmd(julia_args)
    test_args = Cmd(test_args)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()
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

installed() = __installed(PKGMODE_PROJECT)
function __installed(mode::PackageMode=PKGMODE_MANIFEST)
    diffs = Display.status(Context(), PackageSpec[], mode=mode, use_as_api=true)
    version_status = Dict{String, Union{VersionNumber,Nothing}}()
    diffs == nothing && return version_status
    for entry in diffs
        version_status[entry.name] = entry.new.ver
    end
    return version_status
end

"""
    gc(ctx::Context=Context(); collect_delay::Period=Day(30), kwargs...)

Garbage-collect package and artifact installations by sweeping over all known
`Manifest.toml` and `Artifacts.toml` files, noting those that have been deleted, and then
finding artifacts and packages that are thereafter not used by any other projects.  This
method will only remove package versions and artifacts that have been continually un-used
for a period of `collect_delay`; which defaults to thirty days.
"""
function gc(ctx::Context=Context(); collect_delay::Period=Day(30), kwargs...)
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()
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
    all_index_files = Set(filter(isfile, all_index_files))

    # Immediately write this back as condensed manifest_usage.toml files
    if !ctx.preview
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
    end

    # Next, we will process the manifest.toml and artifacts.toml files separately,
    # extracting from them the paths of the packages and artifacts that they reference.
    all_manifest_files = filter(f -> endswith(f, "Manifest.toml"), all_index_files)
    all_artifacts_files = filter(f -> !endswith(f, "Manifest.toml"), all_index_files)

    function process_manifest(path)
        # Read the manifest in
        manifest = try
            read_manifest(path)
        catch e
            @warn "Reading manifest file at $path failed with error" exception = e
            return nothing
        end

        # Collect the locations of every package referred to in this manifest
        pkg_dir(uuid, entry) = Operations.find_installed(entry.name, uuid, entry.tree_hash)
        return [pkg_dir(u, e) for (u, e) in manifest if e.tree_hash != nothing]
    end

    function process_artifacts_toml(path)
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
    function mark(process_func::Function, index_files)
        marked_paths = String[]
        for index_file in index_files
            # Check to see if it's still alive
            paths = process_func(index_file)
            if paths != nothing
                # Print the path of this beautiful, extant file to the user
                println("        $(Types.pathrepr(index_file))")
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
    packages_to_keep = mark(process_manifest, all_manifest_files)

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
    artifacts_to_keep = mark(process_artifacts_toml, all_artifacts_files)

    # Collect all orphaned paths (packages and artifacts that are not reachable).  These
    # are implicitly defined in that we walk all packages/artifacts installed, then if
    # they were not marked in the above steps, we reap them.
    packages_to_delete = String[]
    artifacts_to_delete = String[]
    for depot in depots()
        # We track orphaned objects on a per-depot basis, writing out our `orphaned.toml`
        # tracking file immediately, only pushing onto the overall `*_to_delete` lists if
        # the package has been orphaned for at least a period of `collect_delay`
        depot_orphaned_packages = String[]
        depot_orphaned_artifacts = String[]

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

        # Write out the `new_orphanage` for this depot, if we're not in preview mode.
        if !ctx.preview && (!isempty(new_orphanage) || isfile(orphanage_file))
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
        if !ctx.preview
            try
                Base.rm(path; recursive=true)
            catch
                @warn "Failed to delete $path"
            end
        end
        printpkgstyle(ctx, :Deleted, Types.pathrepr(path) * " (" * pretty_byte_str(path_size) * ")")
        return path_size
    end

    package_space_freed = 0
    artifact_space_freed = 0
    for path in packages_to_delete
        package_space_freed += delete_path(path)
    end
    for path in artifacts_to_delete
        artifact_space_freed += delete_path(path)
    end

    # Prune package paths that are now empty
    if !ctx.preview
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
    end

    ndel_pkg = length(packages_to_delete)
    ndel_art = length(artifacts_to_delete)

    if ndel_pkg > 0
        s = ndel_pkg == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(package_space_freed)
        printpkgstyle(ctx, :Deleted, "$(ndel_pkg) package installation$(s) ($bytes_saved_string)")
    end
    if ndel_art > 0
        s = ndel_art == 1 ? "" : "s"
        bytes_saved_string = pretty_byte_str(artifact_space_freed)
        printpkgstyle(ctx, :Deleted, "$(ndel_art) artifact installation$(s) ($bytes_saved_string)")
    end
    if ndel_pkg == 0 && ndel_art == 0
        printpkgstyle(ctx, :Deleted, "no artifacts or packages")
    end

    if ctx.preview
        preview_info()
    end
    return
end

build(pkgs...; kwargs...) = build([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
build(pkg::Array{Union{}, 1}; kwargs...) = build(PackageSpec[]; kwargs...)
build(pkg::PackageSpec; kwargs...) = build([pkg]; kwargs...)
build(pkgs::Vector{PackageSpec}; kwargs...) = build(Context(), pkgs; kwargs...)
function build(ctx::Context, pkgs::Vector{PackageSpec}; verbose=false, kwargs...)
    pkgs = deepcopy(pkgs)  # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)

    ctx.preview && preview_info()
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

#####################################
# Backwards compatibility with Pkg2 #
#####################################
function clone(url::String, name::String = "")
    @warn "Pkg.clone is only kept for legacy CI script reasons, please use `add`" maxlog=1
    ctx = Context()
    if !isempty(name)
        ctx.old_pkg2_clone_name = name
    end
    develop(ctx, [Pkg.REPLMode.parse_package_identifier(url; add_or_develop=true)])
end

function dir(pkg::String, paths::AbstractString...)
    @warn "`Pkg.dir(pkgname, paths...)` is deprecated; instead, do `import $pkg; joinpath(dirname(pathof($pkg)), \"..\", paths...)`." maxlog=1
    pkgid = Base.identify_package(pkg)
    pkgid === nothing && return nothing
    path = Base.locate_package(pkgid)
    path === nothing && return nothing
    return abspath(path, "..", "..", paths...)
end

precompile() = precompile(Context())
function precompile(ctx::Context)
    printpkgstyle(ctx, :Precompiling, "project...")

    pkgids = [Base.PkgId(uuid, name) for (name, uuid) in ctx.env.project.deps if !(uuid in keys(ctx.stdlibs))]
    if ctx.env.pkg !== nothing && isfile( joinpath( dirname(ctx.env.project_file), "src", ctx.env.pkg.name * ".jl") )
        push!(pkgids, Base.PkgId(ctx.env.pkg.uuid, ctx.env.pkg.name))
    end

    # TODO: since we are a complete list, but not topologically sorted, handling of recursion will be completely at random
    for pkg in pkgids
        paths = Base.find_all_in_cache_path(pkg)
        sourcepath = Base.locate_package(pkg)
        sourcepath == nothing && continue
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
            printpkgstyle(ctx, :Precompiling, pkg.name)
            try
                Base.compilecache(pkg, sourcepath)
            catch
            end
        end
    end
    nothing
end

instantiate(; kwargs...) = instantiate(Context(); kwargs...)
function instantiate(ctx::Context; manifest::Union{Bool, Nothing}=nothing,
                     update_registry::Bool=true, verbose::Bool=false, kwargs...)
    Context!(ctx; kwargs...)
    if (!isfile(ctx.env.manifest_file) && manifest == nothing) || manifest == false
        up(ctx; update_registry=update_registry)
        return
    end
    if !isfile(ctx.env.manifest_file) && manifest == true
        pkgerror("manifest at $(ctx.env.manifest_file) does not exist")
    end
    Operations.prune_manifest(ctx)
    for (name, uuid) in ctx.env.project.deps
        get(ctx.env.manifest, uuid, nothing) === nothing || continue
        pkgerror("`$name` is a direct dependency, but does not appear in the manifest.",
                 " If you intend `$name` to be a direct dependency, run `Pkg.resolve()` to populate the manifest.",
                 " Otherwise, remove `$name` with `Pkg.rm(\"$name\")`.",
                 " Finally, run `Pkg.instantiate()` again.")
    end
    Operations.is_instantiated(ctx) && return
    Types.update_registries(ctx)
    pkgs = PackageSpec[]
    Operations.load_all_deps!(ctx, pkgs)
    Operations.check_registered(ctx, pkgs)
    new_git = UUID[]
    for pkg in pkgs
        pkg.repo.url !== nothing || continue
        sourcepath = Operations.source_path(pkg)
        isdir(sourcepath) && continue
        # download repo at tree hash
        push!(new_git, pkg.uuid)
        clonepath = Types.clone_path!(ctx, pkg.repo.url)
        tmp_source = Types.repo_checkout(ctx, clonepath, string(pkg.tree_hash))
        mkpath(sourcepath)
        mv(tmp_source, sourcepath; force=true)
    end
    new_apply = Operations.download_source(ctx, pkgs)
    Operations.build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git); verbose=verbose)
end


@deprecate status(mode::PackageMode) status(mode=mode)

status(; kwargs...) = status(PackageSpec[]; kwargs...)
status(pkg::Union{AbstractString,PackageSpec}; kwargs...) = status([pkg]; kwargs...)
status(pkgs::Vector{<:AbstractString}; kwargs...) =
    status([check_package_name(pkg) for pkg in pkgs]; kwargs...)
status(pkgs::Vector{PackageSpec}; kwargs...) = status(Context(), pkgs; kwargs...)
function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool=false, mode=PKGMODE_PROJECT,
                kwargs...)
    Context!(ctx; kwargs...)
    project_resolve!(ctx, pkgs)
    project_deps_resolve!(ctx, pkgs)
    if mode === PKGMODE_MANIFEST
        foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    end
    manifest_resolve!(ctx, pkgs)
    ensure_resolved(ctx, pkgs)
    Pkg.Display.status(ctx, pkgs, diff=diff, mode=mode)
    return nothing
end


function activate()
    Base.ACTIVE_PROJECT[] = nothing
    p = Base.active_project()
    p === nothing || printpkgstyle(Context(), :Activating, "environment at $(pathrepr(p))")
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
function activate(path::AbstractString; shared::Bool=false)
    if !shared
        # `pkg> activate path`/`Pkg.activate(path)` does the following
        # 1. if path exists, activate that
        # 2. if path exists in deps, and the dep is deved, activate that path (`devpath` above)
        # 3. activate the non-existing directory (e.g. as in `pkg> activate .` for initing a new env)
        if Types.isdir_windows_workaround(path)
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
                 url = nothing, rev = nothing, path=nothing, mode::PackageMode = PKGMODE_PROJECT)
    path !== nothing && url !== nothing &&
        pkgerror("cannot specify both a path and url")
    url !== nothing && version !== nothing &&
        pkgerror("`version` can not be given with `url`, use `rev` instead")
    repo = Types.GitRepo(rev = rev, url = url !== nothing ? url : path)
    version = version === nothing ? VersionSpec() : VersionSpec(version)
    uuid isa String && (uuid = UUID(uuid))
    PackageSpec(;name=name, uuid=uuid, version=version, mode=mode, path=nothing,
                special_action=PKGSPEC_NOTHING, repo=repo, tree_hash=nothing)
end
Package(name::AbstractString) = PackageSpec(name)
Package(name::AbstractString, uuid::UUID) = PackageSpec(name, uuid)
Package(name::AbstractString, uuid::UUID, version::VersionTypes) = PackageSpec(name, uuid, version)

end # module
