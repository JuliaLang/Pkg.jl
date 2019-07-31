# This file is a part of Julia. License is MIT: https://julialang.org/license

module API

using UUIDs
using Printf
import Random
import Dates
import LibGit2

import ..depots, ..depots1, ..logdir, ..devdir
import ..Operations, ..Display, ..GitTools, ..Pkg, ..UPDATED_REGISTRY_THIS_SESSION
using ..Types, ..TOML
using Pkg.Types: VersionTypes
using ..BinaryPlatforms


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

    any(pkg -> Types.collides_with_project(ctx.env, pkg), pkgs) &&
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

    project_deps_resolve!(ctx.env, pkgs)
    registry_resolve!(ctx.env, pkgs)
    stdlib_resolve!(ctx, pkgs)
    ensure_resolved(ctx.env, pkgs, registry=true)

    any(pkg -> Types.collides_with_project(ctx.env, pkg), pkgs) &&
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

    project_deps_resolve!(ctx.env, pkgs)
    manifest_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx.env, pkgs)

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
        Types.clone_default_registries()
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
        project_deps_resolve!(ctx.env, pkgs)
        manifest_resolve!(ctx.env, pkgs)
        ensure_resolved(ctx.env, pkgs)
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
    project_deps_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx.env, pkgs)
    Operations.pin(ctx, pkgs)
    return
end


free(pkg::Union{AbstractString, PackageSpec}; kwargs...) = free([pkg]; kwargs...)
free(pkgs::Vector{<:AbstractString}; kwargs...)          = free([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
free(pkgs::Vector{PackageSpec}; kwargs...)       = free(Context(), pkgs; kwargs...)

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
    manifest_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx.env, pkgs)

    find_registered!(ctx.env, UUID[pkg.uuid for pkg in pkgs])
    Operations.free(ctx, pkgs)
    return
end

test(;kwargs...)                                         = test(PackageSpec[]; kwargs...)
test(pkg::Union{AbstractString, PackageSpec}; kwargs...) = test([pkg]; kwargs...)
test(pkgs::Vector{<:AbstractString}; kwargs...)          = test([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
test(pkgs::Vector{PackageSpec}; kwargs...)               = test(Context(), pkgs; kwargs...)
function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, test_fn=nothing,
              julia_args::AbstractVector{<:Base.AbstractCmd}=Cmd[],
              test_args::AbstractVector{<:AbstractString}=String[], kwargs...)
    julia_args = convert(Vector{Cmd}, julia_args)
    test_args = convert(Vector{String}, test_args)
    pkgs = deepcopy(pkgs) # deepcopy for avoid mutating PackageSpec members
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()
    if isempty(pkgs)
        ctx.env.pkg === nothing && pkgerror("trying to test unnamed project") #TODO Allow this?
        push!(pkgs, ctx.env.pkg)
    else
        project_resolve!(ctx.env, pkgs)
        project_deps_resolve!(ctx.env, pkgs)
        manifest_resolve!(ctx.env, pkgs)
        ensure_resolved(ctx.env, pkgs)
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

function gc(ctx::Context=Context(); kwargs...)
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()
    env = ctx.env

    # If the manifest was not used
    usage_file = joinpath(logdir(), "manifest_usage.toml")

    # Collect only the manifest that is least recently used
    manifest_date = Dict{String, Dates.DateTime}()
    for (manifest_file, infos) in TOML.parse(String(read(usage_file)))
        for info in infos
            date = info["time"]
            manifest_date[manifest_file] = haskey(manifest_date, date) ? max(manifest_date[date], date) : date
        end
    end

    # Find all reachable packages through manifests recently used
    new_usage = Dict{String, Any}()
    paths_to_keep = String[]
    printpkgstyle(ctx, :Active, "manifests:")
    for (manifestfile, date) in manifest_date
        !isfile(manifestfile) && continue
        println("        $(Types.pathrepr(manifestfile))")
        manifest = try
            read_manifest(manifestfile)
        catch e
            @warn "Reading manifest file at $manifestfile failed with error" exception = e
            nothing
        end
        manifest == nothing && continue
        new_usage[manifestfile] = [Dict("time" => date)]
        for (uuid, entry) in manifest
            if entry.tree_hash !== nothing
                push!(paths_to_keep,
                      Operations.find_installed(entry.name, uuid, entry.tree_hash))
            end
        end
    end

    # Collect the paths to delete (everything that is not reachable)
    paths_to_delete = String[]
    for depot in depots()
        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                if isdir(joinpath(packagedir, name))
                    for slug in readdir(joinpath(packagedir, name))
                        versiondir = joinpath(packagedir, name, slug)
                        if !(versiondir in paths_to_keep) && isdir(versiondir)
                            push!(paths_to_delete, versiondir)
                        end
                    end
                end
            end
        end
    end

    pretty_byte_str = (size) -> begin
        bytes, mb = Base.prettyprint_getunits(size, length(Base._mem_units), Int64(1024))
        return @sprintf("%.3f %s", bytes, Base._mem_units[mb])
    end

    # Delete paths for noreachable package versions and compute size saved
    function recursive_dir_size(path)
        size = 0
        for (root, dirs, files) in walkdir(path)
            for file in files
                size += lstat(joinpath(root, file)).size
            end
        end
        return size
    end

    sz = 0
    for path in paths_to_delete
        sz_pkg = recursive_dir_size(path)
        if !ctx.preview
            try
                Base.rm(path; recursive=true)
            catch
                @warn "Failed to delete $path"
            end
        end
        printpkgstyle(ctx, :Deleted, Types.pathrepr(path) * " (" * pretty_byte_str(sz_pkg) * ")")
        sz += sz_pkg
    end

    # Delete package paths that are now empty
    for depot in depots()
        packagedir = abspath(depot, "packages")
        if isdir(packagedir)
            for name in readdir(packagedir)
                name_path = joinpath(packagedir, name)
                if isdir(name_path)
                    if isempty(readdir(name_path))
                        !ctx.preview && Base.rm(name_path)
                    end
                end
            end
        end
    end

    # Write the new condensed usage file
    if !ctx.preview
        open(usage_file, "w") do io
            TOML.print(io, new_usage, sorted=true)
        end
    end
    ndel = length(paths_to_delete)
    byte_save_str = ndel == 0 ? "" : (" (" * pretty_byte_str(sz) * ")")
    printpkgstyle(ctx, :Deleted, "$(ndel) package installation$(ndel == 1 ? "" : "s")$byte_save_str")

    ctx.preview && preview_info()
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
    project_resolve!(ctx.env, pkgs)
    foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    manifest_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx.env, pkgs)
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
                     update_registry::Bool=true, kwargs...)
    Context!(ctx; kwargs...)
    if (!isfile(ctx.env.manifest_file) && manifest == nothing) || manifest == false
        up(ctx; update_registry=update_registry)
        return
    end
    if !isfile(ctx.env.manifest_file) && manifest == true
        pkgerror("manifest at $(ctx.env.manifest_file) does not exist")
    end
    Operations.prune_manifest(ctx.env)
    for (name, uuid) in ctx.env.project.deps
        get(ctx.env.manifest, uuid, nothing) === nothing || continue
        pkgerror("`$name` is a direct dependency, but does not appear in the manifest.",
                 " If you intend `$name` to be a direct dependency, run `Pkg.resolve()` to populate the manifest.",
                 " Otherwise, remove `$name` with `Pkg.rm(\"$name\")`.",
                 " Finally, run `Pkg.instantiate()` again.")
    end
    Operations.is_instanitated(ctx) && return
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
        clonepath = Types.clone_path!(pkg.repo.url)
        tmp_source = Types.repo_checkout(clonepath, string(pkg.tree_hash))
        mkpath(sourcepath)
        mv(tmp_source, sourcepath; force=true)
    end
    new_apply = Operations.download_source(ctx, pkgs)
    z = union([pkg.uuid for pkg in new_apply], new_git)
    Operations.build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git))
end


@deprecate status(mode::PackageMode) status(mode=mode)

status(; kwargs...) = status(PackageSpec[]; kwargs...)
status(pkg::Union{AbstractString,PackageSpec}; kwargs...) = status([pkg]; kwargs...)
status(pkgs::Vector{<:AbstractString}; kwargs...) =
    status([check_package_name(pkg) for pkg in pkgs]; kwargs...)
status(pkgs::Vector{PackageSpec}; kwargs...) = status(Context(), pkgs; kwargs...)
function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool=false, mode=PKGMODE_PROJECT)
    project_resolve!(ctx.env, pkgs)
    project_deps_resolve!(ctx.env, pkgs)
    if mode === PKGMODE_MANIFEST
        foreach(pkg -> pkg.mode = PKGMODE_MANIFEST, pkgs)
    end
    manifest_resolve!(ctx.env, pkgs)
    ensure_resolved(ctx.env, pkgs)
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
    env = nothing
    try
        env = EnvCache()
    catch err
        err isa PkgError || rethrow()
        return
    end
    uuid = get(env.project.deps, dep_name, nothing)
    if uuid !== nothing
        entry = manifest_info(env, uuid)
        if entry.path !== nothing
            return joinpath(dirname(env.project_file), entry.path)
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
function activate(f::Function, args...; kwargs...)
    p = Base.active_project()
    try
        Pkg.activate(args...; kwargs...)
        f()
    finally
        Pkg.activate(p)
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
