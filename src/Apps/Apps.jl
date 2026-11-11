module Apps

using Pkg
using Pkg: atomic_toml_write, stdout_f, stderr_f, isurl, printpkgstyle, pathrepr
using Pkg.Versions
using Pkg.Types: AppInfo, PackageSpec, Context, EnvCache, PackageEntry, Manifest, handle_repo_add!, handle_repo_develop!, write_manifest, write_project,
    pkgerror, projectfile_path, manifestfile_path, read_project, read_manifest
using Pkg.Operations: print_single, source_path, update_package_add
using Pkg.API: handle_package_input!
using TOML, UUIDs
using Dates
import FileWatching
import Pkg.Registry

public add, rm, status, update, develop, relink

app_env_folder() = joinpath(first(DEPOT_PATH), "environments", "apps")
app_env_dir(pkgname) = joinpath(app_env_folder(), pkgname)
app_manifest_file() = joinpath(app_env_folder(), "AppManifest.toml")
julia_bin_path() = joinpath(first(DEPOT_PATH), "bin")
julia_executable() = joinpath(Sys.BINDIR, "julia" * (Sys.iswindows() ? ".exe" : ""))
shim_filename(name) = name * (Sys.iswindows() ? ".bat" : "")
shim_path(name) = joinpath(julia_bin_path(), shim_filename(name))

# The juliaup directory (the one holding `juliaup.json`) that `julia` is installed
# in, or `nothing` if `julia` is not installed by juliaup
function juliaup_home(julia::AbstractString)
    dir = dirname(abspath(julia))
    while true
        isfile(joinpath(dir, "juliaup.json")) && return dir
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
    return
end

# The juliaup channel that the shim of an app falls back to when `julia` was
# removed: the `major.minor` channel of the running julia, so that a patch
# release replacing it (which keeps the app manifest valid) is used, together
# with the juliaup config file that tells whether that channel is installed.
# Nightlies and other development builds have no such channel.
function juliaup_channel(julia::AbstractString)
    julia == julia_executable() || return nothing
    home = juliaup_home(julia)
    home === nothing && return nothing
    !isempty(VERSION.prerelease) && first(VERSION.prerelease) == "DEV" && return nothing
    return (; name = "$(VERSION.major).$(VERSION.minor)", config = joinpath(home, "juliaup.json"))
end

app_julia(app::AppInfo) = something(app.julia_command, julia_executable())

app_context() = Context(env = EnvCache(joinpath(app_env_folder(), "Project.toml")))

const _apps_lock_held = Base.ScopedValues.ScopedValue(false)

# Serialize operations that mutate the app environments and the AppManifest
function with_apps_lock(f)
    # Operations can be nested (e.g. update calls add) so the lock is reentrant
    _apps_lock_held[] && return f()
    mkpath(app_env_folder())
    return FileWatching.mkpidlock(joinpath(app_env_folder(), ".pid"), stale_age = 10) do
        Base.ScopedValues.@with _apps_lock_held => true f()
    end
end

function validate_app_name(name::AbstractString)
    if isempty(name)
        pkgerror("App name cannot be empty")
    end
    if !occursin(r"^[a-zA-Z][a-zA-Z0-9_-]*$", name)
        pkgerror("App name must start with a letter and contain only letters, numbers, underscores, and hyphens")
    end
    return if occursin(r"\.\.", name) || occursin(r"[/\\]", name)
        pkgerror("App name cannot contain path traversal sequences or path separators")
    end
end

function validate_package_name(name::AbstractString)
    if isempty(name)
        pkgerror("Package name cannot be empty")
    end
    return if !occursin(r"^[a-zA-Z][a-zA-Z0-9_]*$", name)
        pkgerror("Package name must start with a letter and contain only letters, numbers, and underscores")
    end
end

function validate_submodule_name(name::Union{AbstractString, Nothing})
    return if name !== nothing
        if isempty(name)
            pkgerror("Submodule name cannot be empty")
        end
        # Nested submodules are allowed, e.g. `Foo.Bar`
        if !occursin(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)*$", name)
            pkgerror("Submodule name must be dot-separated identifiers, each starting with a letter and containing only letters, numbers, and underscores")
        end
    end
end

# The `project` of an app is the directory, relative to the package and with
# `/` as separator, of the project the app runs in
function validate_app_project(appname::AbstractString, project::Union{AbstractString, Nothing})
    project === nothing && return
    parts = split(project, '/')
    if any(part -> part in (".", "..") || !occursin(r"^[a-zA-Z0-9_.-]+$", part), parts)
        pkgerror("The `project` of app `$appname` must be a relative path (with `/` as separator) to a directory inside the package, got `$project`")
    end
    return
end

subproject_path(root::AbstractString, subproject::Union{String, Nothing}) =
    subproject === nothing ? root : joinpath(root, split(subproject, '/')...)

# The projects used by `apps`, the package itself (`nothing`) first
subprojects(apps) = sort!(unique(Union{String, Nothing}[app.project for app in values(apps)]); by = p -> something(p, ""))

# The project in the package `pkgname` at `sourcepath` that the apps with `project = subproject` run in
function read_subproject(pkgname, sourcepath::AbstractString, subproject::String)
    project_file = projectfile_path(subproject_path(sourcepath, subproject); strict = true)
    project_file === nothing && pkgerror("The project `$subproject` used by apps of package $pkgname does not exist")
    project = read_project(project_file)
    if project.name === nothing || project.uuid === nothing
        pkgerror("The project `$subproject` used by apps of package $pkgname must be a package (have a `name` and a `uuid`)")
    end
    return project
end

# The name of the package holding the module that `app` of the package `pkgname` at `sourcepath` runs
app_package_name(pkgname, sourcepath::AbstractString, app::AppInfo) =
    app.project === nothing ? pkgname : read_subproject(pkgname, sourcepath, app.project).name

function rm_shim(name; kwargs...)
    validate_app_name(name)
    return Base.rm(shim_path(name); kwargs...)
end

function get_project(sourcepath)
    project_file = projectfile_path(sourcepath)

    isfile(project_file) || pkgerror("Project file not found: $project_file")

    project = read_project(project_file)
    isempty(project.apps) && pkgerror("No apps found in Project.toml for package $(project.name) at version $(project.version)")
    for app in values(project.apps)
        validate_app_name(app.name)
        validate_submodule_name(app.submodule)
        validate_app_project(app.name, app.project)
        app.project === nothing || read_subproject(project.name, sourcepath, app.project)
    end
    return project
end


function overwrite_file_if_different(file, content)
    # Windows batch files require CRLF line endings for reliable label parsing
    if endswith(file, ".bat")
        content = replace(content, "\r\n" => "\n")  # normalize to LF first
        content = replace(content, "\n" => "\r\n")  # then convert to CRLF
    end
    return if !isfile(file) || read(file, String) != content
        mkpath(dirname(file))
        write(file, content)
    end
end

# Whether the directory with the app shims is in PATH
function bin_in_path()
    bindir = julia_bin_path()
    isdir(bindir) || return false
    for dir in split(get(ENV, "PATH", ""), Sys.iswindows() ? ';' : ':'; keepempty = false)
        (dir == bindir || (isdir(dir) && Base.Filesystem.samefile(dir, bindir))) && return true
    end
    return false
end

# How to add the directory with the app shims to PATH, for the shell of the user
function path_instructions()
    bindir = julia_bin_path()
    if Sys.iswindows()
        return """
        To add it, run the following in PowerShell and open a new terminal:
            [Environment]::SetEnvironmentVariable("Path", "$bindir;" + [Environment]::GetEnvironmentVariable("Path", "User"), "User")"""
    end
    home = joinpath(homedir(), "")
    dir = startswith(bindir, home) ? "\$HOME/" * relpath(bindir, home) : bindir
    shell = basename(get(ENV, "SHELL", ""))
    command = if !occursin(r"^[a-zA-Z0-9_.\-/$]+$", dir)
        nothing
    elseif shell == "fish"
        "fish_add_path \"$dir\""
    elseif shell == "zsh"
        "echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc"
    elseif shell == "bash"
        "echo 'export PATH=\"$dir:\$PATH\"' >> ~/.$(Sys.isapple() ? "bash_profile" : "bashrc")"
    else
        nothing
    end
    command === nothing && return "To add it, put it in the PATH environment variable in the startup file of your shell."
    return """
    To add it, run the following and open a new terminal:
        $command"""
end

function check_apps_in_path(apps)
    if !bin_in_path()
        @warn """
        The directory with the apps, $(pathrepr(julia_bin_path())), is not in PATH so the apps can not be run by their name.
        $(path_instructions())
        """
        return
    end
    for app_name in sort!(collect(keys(apps)))
        found = Sys.which(shim_filename(app_name))
        expected = shim_path(app_name)
        if found !== nothing && found != expected && !Base.Filesystem.samefile(found, expected)
            @warn "App `$app_name` is shadowed by $(pathrepr(found)) which comes before $(pathrepr(julia_bin_path())) in PATH"
        end
    end
    return
end

# Source path of a developed app, or `nothing` if the entry is not one.
# Pkg 1.12.6 wrote registry apps with `path = "."`, which resolves to the
# apps folder itself and must not be used as a project (#4805).
function developed_source_path(manifest_file::String, info::PackageEntry)
    info.path === nothing && return nothing
    sourcepath = abspath(source_path(manifest_file, info))
    isdir(sourcepath) && Base.Filesystem.samefile(sourcepath, app_env_folder()) && return nothing
    return sourcepath
end

# PackageEntry requires version::Union{VersionNumber, Nothing}, but project.version can be a VersionSpec
function package_entry(pkg::PackageSpec, project, apps, path)
    version = project.version isa VersionNumber ? project.version : nothing
    return PackageEntry(; apps, name = pkg.name, version, tree_hash = pkg.tree_hash, path, repo = pkg.repo, uuid = pkg.uuid)
end

function get_max_version_register(pkg::PackageSpec, regs)
    max_v = nothing
    tree_hash = nothing
    for reg in regs
        reg_pkg = get(reg, pkg.uuid, nothing)
        if reg_pkg !== nothing
            pkg_info = Registry.registry_info(reg, reg_pkg)
            for (version, info) in pkg_info.version_info
                info.yanked && continue
                if pkg.version isa VersionNumber
                    pkg.version == version || continue
                else
                    version in pkg.version || continue
                    # Skip versions that are not compatible with the running julia
                    julia_compat = Registry.query_compat_for_version(pkg_info, version, Registry.JULIA_UUID)
                    if julia_compat !== nothing && !(VERSION in julia_compat)
                        continue
                    end
                end
                if max_v === nothing || version > max_v
                    max_v = version
                    tree_hash = info.git_tree_sha1
                end
            end
        end
    end
    if max_v === nothing
        pkgerror("Suitable package version for $(pkg.name) not found in any registries.")
    end
    return (max_v, tree_hash)
end


# Remove the shims of apps that the installed version of the package `entry`
# provides but the new one does not, and take over apps with the same name
# from other packages
function reconcile_shims!(manifest::Manifest, entry::PackageEntry)
    old_entry = get(manifest.deps, entry.uuid, nothing)
    if old_entry !== nothing
        for appname in keys(old_entry.apps)
            haskey(entry.apps, appname) || rm_shim(appname; force = true)
        end
    end
    for (uuid, other) in collect(manifest.deps)
        uuid == entry.uuid && continue
        overlap = sort!(collect(intersect(keys(other.apps), keys(entry.apps))))
        isempty(overlap) && continue
        what = length(overlap) == 1 ? "app" : "apps"
        @warn "Replacing the $what $(join(overlap, ", ")) of package $(other.name) with the $what of package $(entry.name)"
        foreach(appname -> delete!(other.apps, appname), overlap)
        isempty(other.apps) && rm_package!(manifest, other)
    end
    return
end

# Remove a package without apps left from the app manifest
function rm_package!(manifest::Manifest, entry::PackageEntry)
    delete!(manifest.deps, entry.uuid)
    if entry.path === nothing
        Base.rm(app_env_dir(entry.name); recursive = true, force = true)
    end
    return
end

# Apps that the installed version of a package provides but that have been
# removed stay removed when the package is updated
function without_removed_apps(manifest_file::String, old_entry::PackageEntry, apps::Dict{String, AppInfo})
    old_source = source_path(manifest_file, old_entry)
    old_source === nothing && return apps
    project_file = projectfile_path(old_source; strict = true)
    project_file === nothing && return apps
    old_apps = try
        read_project(project_file).apps
    catch
        return apps
    end
    removed = setdiff(keys(old_apps), keys(old_entry.apps))
    kept = filter(app -> !(app.first in removed), apps)
    return isempty(kept) ? apps : kept
end

function report_apps(entry::PackageEntry, old_entry::Union{PackageEntry, Nothing}; updating::Bool = false)
    version(e) = e.version === nothing ? "" : " v$(e.version)"
    names = join(("`$name`" for name in sort!(collect(keys(entry.apps)))), ", ")
    what = length(entry.apps) == 1 ? "app" : "apps"
    io = stderr_f()
    if entry.path !== nothing
        printpkgstyle(io, :Installed, "$what $names of $(entry.name)$(version(entry)) developed at $(pathrepr(entry.path))")
    elseif !updating || old_entry === nothing
        printpkgstyle(io, :Installed, "$what $names of $(entry.name)$(version(entry))")
    elseif old_entry.version == entry.version && old_entry.tree_hash == entry.tree_hash
        printpkgstyle(io, Symbol("No Changes"), "to $(entry.name)$(version(entry)) with $what $names")
    else
        printpkgstyle(io, :Updated, "$what $names of $(entry.name)$(version(old_entry)) ⇒$(version(entry))")
    end
    return
end

function report_removed(entry::PackageEntry, appnames::Vector{String})
    names = join(("`$name`" for name in sort(appnames)), ", ")
    printpkgstyle(stderr_f(), :Removed, "$(length(appnames) == 1 ? "app" : "apps") $names of $(entry.name)")
    return
end


##################
# Main Functions #
##################

# Packages in the repository of the package `info` (the package itself and the
# projects of its workspace), which the project of an app uses as they are installed
function inrepo_packages(info::PackageEntry, sourcepath::String)
    paths = Dict{UUID, String}(info.uuid => sourcepath)
    for (project_file, project) in Pkg.Types.collect_workspace(projectfile_path(sourcepath))
        project.uuid === nothing || get!(paths, project.uuid, dirname(project_file))
    end
    return paths
end

# Create the environment in `envdir` for the apps of the package `info` (installed at
# `sourcepath`) that run in `subproject`. `old_envdir` is the environment of a previous
# installation, if any, that the changes are shown relative to.
function create_app_env(info::PackageEntry, sourcepath::String, subproject::Union{String, Nothing}, envdir::String, old_envdir::Union{String, Nothing})
    project_source = subproject_path(sourcepath, subproject)
    original_project_file = projectfile_path(project_source)
    isfile(original_project_file) || pkgerror("could not find project file for package $(info.name)")

    projectfile = joinpath(envdir, "Project.toml")
    mkpath(envdir)
    cp(original_project_file, projectfile; force = true)
    chmod(projectfile, 0o644)  # Make the copied project file writable

    comments = TOML.Comments()
    project_data = TOML.parsefile(projectfile; comments)

    # Paths inside the depot are written relative to the app environment
    # so that the depot can be relocated
    depot_prefix = joinpath(normpath(first(DEPOT_PATH)), "")
    relative_to_depot(path) = startswith(normpath(path), depot_prefix) ? relpath(path, envdir) : path

    # Add entryfile stanza pointing to the package entry file,
    # respecting an existing entryfile in the project
    entryfile = get(project_data, "entryfile", joinpath("src", "$(project_data["name"]).jl"))
    entryfile = isabspath(entryfile) ? entryfile : normpath(joinpath(project_source, entryfile))
    project_data["entryfile"] = relative_to_depot(entryfile)

    # The environment is on its own, not part of the workspace of the package
    delete!(project_data, "workspace")

    # Relative paths in [sources] are relative to the original project
    # location, not the app environment the project file is copied to.
    # Paths inside the package resolve to the installed package tree and
    # other paths to the original location (for packages added from a local
    # path); entries that do not resolve are dropped so the dependency
    # comes from a registry.
    sources = get!(project_data, "sources", Dict{String, Any}())
    original_dir = nothing
    if info.repo.source !== nothing && !Pkg.isurl(info.repo.source)
        original_dir = normpath(joinpath(app_env_folder(), info.repo.source))
        if info.repo.subdir !== nothing
            original_dir = joinpath(original_dir, info.repo.subdir)
        end
        original_dir = subproject_path(original_dir, subproject)
    end
    package_prefix = joinpath(normpath(sourcepath), "")
    for (depname, source) in collect(sources)
        path = get(source, "path", nothing)
        (path === nothing || isabspath(path)) && continue
        candidates = String[]
        installed = normpath(joinpath(project_source, path))
        startswith(joinpath(installed, ""), package_prefix) && push!(candidates, installed)
        original_dir !== nothing && push!(candidates, normpath(joinpath(original_dir, path)))
        resolved = findfirst(isdir, candidates)
        if resolved === nothing
            @warn "Ignoring source with relative path `$(path)` for dependency $(depname) of package $(project_data["name"]) since it does not exist relative to the installed package"
            delete!(source, "path")
            isempty(source) && delete!(sources, depname)
        else
            source["path"] = relative_to_depot(candidates[resolved])
        end
    end
    if subproject !== nothing
        inrepo = inrepo_packages(info, sourcepath)
        for section in ("deps", "weakdeps"), (depname, uuid) in get(project_data, section, Dict{String, Any}())
            path = get(inrepo, UUID(uuid), nothing)
            (path === nothing || haskey(sources, depname)) && continue
            sources[depname] = Dict{String, Any}("path" => relative_to_depot(path))
        end
    end
    isempty(sources) && delete!(project_data, "sources")

    # Preserves Pkg's project key ordering, inline [sources] tables and comments
    write_project(project_data, projectfile; comments)

    Pkg.activate(envdir) do
        ctx = Context()
        Base.ScopedValues.@with Pkg.Operations.SHOW_UPDATE => false Pkg.resolve(ctx)
        show_env_changes(ctx, old_envdir)
    end
    return
end

# Show how the packages in a new app environment differ from the ones of the
# previous installation of the app in `old_envdir`, if any
function show_env_changes(ctx::Context, old_envdir::Union{String, Nothing})
    old_env = EnvCache()
    old_env.project = Pkg.Types.Project()
    old_env.manifest = Manifest()
    if old_envdir !== nothing && isfile(projectfile_path(old_envdir))
        try
            old_env.manifest = read_manifest(manifestfile_path(old_envdir))
            old_env.project = read_project(projectfile_path(old_envdir))
        catch
        end
    end
    # (the manifest also has an entry for the project itself)
    installed(manifest) = Dict(
        uuid => (entry.version, entry.tree_hash, entry.path, entry.repo)
            for (uuid, entry) in manifest.deps if uuid != ctx.env.project.uuid
    )
    installed(ctx.env.manifest) == installed(old_env.manifest) && return
    Pkg.Operations.status(
        ctx.env, ctx.registries; header = :Updating, mode = Pkg.Types.PKGMODE_MANIFEST, env_diff = old_env,
        ignore_indent = false, show_usagetips = false, io = ctx.io
    )
    return
end

# Create the environments that the apps of the tracked package `info` run in, one
# for each project that the apps use. A previous installation is kept if this fails.
function create_app_envs(info::PackageEntry)
    sourcepath = source_path(app_manifest_file(), info)
    envroot = app_env_dir(info.name)
    backup = envroot * ".old"
    Base.rm(backup; force = true, recursive = true)
    has_backup = ispath(envroot)
    has_backup && mv(envroot, backup)
    try
        for subproject in subprojects(info.apps)
            old_envdir = has_backup ? subproject_path(backup, subproject) : nothing
            create_app_env(info, sourcepath, subproject, subproject_path(envroot, subproject), old_envdir)
        end
    catch
        Base.rm(envroot; force = true, recursive = true)
        has_backup && mv(backup, envroot)
        rethrow()
    end
    Base.rm(backup; force = true, recursive = true)
    return
end

function generate_shims_for_apps(info::PackageEntry)
    sourcepath = developed_source_path(app_manifest_file(), info)
    if sourcepath === nothing
        # Tracked apps run in their app environment, developed ones in the developed project
        generate_shims_for_apps(info.name, info.apps, source_path(app_manifest_file(), info), app_env_dir(info.name), julia_executable())
    else
        generate_shims_for_apps(info.name, info.apps, sourcepath, sourcepath, julia_executable())
    end
    return
end


"""
    Pkg.Apps.add(pkg::Union{String, PackageSpec})
    Pkg.Apps.add(; name, uuid, version, url, rev, path, subdir)

Install the apps of package `pkg`. The package is installed into an isolated
environment and shims for its apps are created in `~/.julia/bin` (which should
be added to `PATH`). Apps can be added from a registry, a git URL, or a local
path (which needs to be a git repository).

If the package is already installed it is replaced, and all of its apps are
installed again. A previous installation is kept if the installation fails.

# Examples
```julia
Pkg.Apps.add("Runic")
Pkg.Apps.add(name = "Runic", version = "1.5")
Pkg.Apps.add(url = "https://github.com/fredrikekre/Runic.jl", rev = "master")
Pkg.Apps.add(path = "path/to/Package")
```
"""
function add(pkg::Vector{PackageSpec})
    require_not_empty(pkg, :add)
    for p in pkg
        add(p)
    end
    return
end


add(pkg::PackageSpec) = with_apps_lock(() -> _add(pkg))
function _add(pkg::PackageSpec; updating::Bool = false)
    handle_package_input!(pkg)
    # A relative local path is given relative to the working directory, but
    # the app manifest lives in the depot, so store it as an absolute path
    if pkg.repo.source !== nothing && !isurl(pkg.repo.source)
        pkg.repo.source = abspath(pkg.repo.source)
    end

    # Must run before `app_context()` since `Context` loads the registries
    Pkg.Registry.download_default_registries(Pkg.stderr_f())

    ctx = app_context()

    Pkg.Operations.update_registries(ctx; force = false, update_cooldown = Day(1))

    manifest = ctx.env.manifest
    new = false

    # Download package
    if pkg.repo.source !== nothing || pkg.repo.rev !== nothing
        entry = Pkg.API.manifest_info(ctx.env.manifest, pkg.uuid)
        pkg = update_package_add(ctx, pkg, entry, false)
        new = handle_repo_add!(ctx, pkg)
    else
        pkgs = [pkg]
        Pkg.Operations.registry_resolve!(ctx.registries, pkgs)
        Pkg.Operations.ensure_resolved(ctx, manifest, pkgs, registry = true)

        pkg.version, pkg.tree_hash = get_max_version_register(pkg, ctx.registries)

        new = Pkg.Operations.download_source(ctx, pkgs)
    end

    sourcepath = source_path(ctx.env.manifest_file, pkg)
    project = get_project(sourcepath)
    old_entry = get(manifest.deps, pkg.uuid, nothing)
    apps = project.apps
    if updating && old_entry !== nothing
        apps = without_removed_apps(ctx.env.manifest_file, old_entry, apps)
    end
    # TODO: Wrong if package itself has a sourcepath?
    entry = package_entry(pkg, project, apps, pkg.path)

    # Nothing of a previous installation is touched until the environments are in place
    create_app_envs(entry)
    reconcile_shims!(manifest, entry)
    manifest.deps[pkg.uuid] = entry
    generate_shims_for_apps(entry)
    write_manifest(manifest, app_manifest_file())

    if new === true || (new isa Set{UUID} && pkg.uuid in new)
        Pkg.Operations.build_versions(ctx, Set([pkg.uuid]); verbose = true)
    end
    # Like for the other operations, only precompile if auto-precompilation is enabled
    Pkg.should_autoprecompile() && precompile(pkg.name)

    report_apps(entry, old_entry; updating)
    return check_apps_in_path(entry.apps)
end

"""
    Pkg.Apps.develop(pkg::Union{String, PackageSpec})
    Pkg.Apps.develop(; name, uuid, version, url, rev, path, subdir)

Like [`Pkg.Apps.add`](@ref) but the apps run directly from the developed
project so changes made to it are immediately reflected in the apps.

# Examples
```julia
Pkg.Apps.develop("Runic")
Pkg.Apps.develop(path = "path/to/Package")
```
"""
function develop(pkg::Vector{PackageSpec})
    require_not_empty(pkg, :develop)
    for p in pkg
        develop(p)
    end
    return
end

develop(pkg::PackageSpec) = with_apps_lock(() -> _develop(pkg))
function _develop(pkg::PackageSpec)
    if pkg.path !== nothing
        pkg.path = abspath(pkg.path)
    end
    handle_package_input!(pkg)
    ctx = app_context()
    handle_repo_develop!(ctx, pkg, #=shared =# true)
    sourcepath = abspath(source_path(ctx.env.manifest_file, pkg))
    project = get_project(sourcepath)

    # Seems like the `.repo.source` field is not cleared.
    # At least repo-url is still in the manifest after doing a dev with a path
    # Figure out why for normal dev this is not needed.
    # XXX: Why needed?
    if pkg.path !== nothing
        pkg.repo.source = nothing
    end

    manifest = ctx.env.manifest
    old_entry = get(manifest.deps, pkg.uuid, nothing)
    entry = package_entry(pkg, project, project.apps, sourcepath)

    # For dev, we don't create an app environment - the shims point directly to the
    # dev'd project, which needs resolved manifests for the dependencies to be loadable
    instantiate_developed(sourcepath, entry.apps)

    reconcile_shims!(manifest, entry)
    manifest.deps[pkg.uuid] = entry
    Base.rm(app_env_dir(pkg.name); force = true, recursive = true)
    generate_shims_for_apps(entry)
    write_manifest(manifest, app_manifest_file())

    report_apps(entry, old_entry)
    return check_apps_in_path(entry.apps)
end

function instantiate_developed(sourcepath::String, apps; resolve::Bool = false)
    for subproject in subprojects(apps)
        Pkg.activate(subproject_path(sourcepath, subproject)) do
            resolve && Pkg.resolve()
            Pkg.instantiate()
        end
    end
    return
end


"""
    Pkg.Apps.update(name::Union{Nothing, String} = nothing)

Update the package providing the app `name` (or the package named `name`) to
the latest compatible version, or all installed apps if no name is given.
For developed packages the dependencies of the project are updated instead.

Apps of a package that have been removed with [`Pkg.Apps.rm`](@ref) are not
installed again.
"""
update(pkgs_or_apps::String) = update([pkgs_or_apps])
function update(pkgs_or_apps::Vector)
    if isempty(pkgs_or_apps)
        update(nothing)
    else
        for pkg_or_app in pkgs_or_apps
            if pkg_or_app isa String
                pkg_or_app = PackageSpec(pkg_or_app)
            end
            update(pkg_or_app)
        end
    end
    return
end

update(pkg::Union{PackageSpec, Nothing} = nothing) = with_apps_lock(() -> _update(pkg))
function _update(pkg::Union{PackageSpec, Nothing})
    ctx = app_context()
    manifest = ctx.env.manifest
    deps = Pkg.Operations.load_manifest_deps(manifest)
    updated = false
    failed = String[]
    for dep in deps
        info = manifest.deps[dep.uuid]
        if pkg !== nothing && info.name != pkg.name && !(pkg.name in keys(info.apps))
            continue
        end
        updated = true
        try
            update_package(ctx, info)
        catch err
            # When updating everything, a package that fails does not stop the others
            (pkg !== nothing || err isa InterruptException) && rethrow()
            push!(failed, info.name)
            printpkgstyle(stderr_f(), :Error, "could not update $(info.name): $(sprint(showerror, err))"; color = Base.error_color())
        end
    end
    isempty(failed) || pkgerror("could not update $(join(failed, ", ")), the installed apps of $(length(failed) == 1 ? "that package" : "those packages") are unchanged")
    if pkg !== nothing && !updated
        pkgerror("no app or package named `$(pkg.name)` found in the app manifest")
    end
    return
end

function update_package(ctx::Context, info::PackageEntry)
    sourcepath = developed_source_path(ctx.env.manifest_file, info)
    if sourcepath !== nothing
        # Developed app: update the dependencies of the developed projects
        # and refresh the app info from it
        for subproject in subprojects(info.apps)
            dir = subproject_path(sourcepath, subproject)
            isdir(dir) || continue
            Pkg.activate(dir) do
                Pkg.update()
            end
        end
        _develop(PackageSpec(path = sourcepath))
    elseif info.repo.source !== nothing || info.repo.rev !== nothing
        # Repo tracked app: re-add to fetch the latest revision
        _add(PackageSpec(name = info.name, uuid = info.uuid, url = info.repo.source, rev = info.repo.rev, subdir = info.repo.subdir); updating = true)
    else
        # Registry tracked app: re-add to resolve the latest version
        _add(PackageSpec(name = info.name, uuid = info.uuid); updating = true)
    end
    return
end

"""
    Pkg.Apps.relink(name::Union{Nothing, String} = nothing)

Make the app `name` (or the apps of the package named `name`), or all installed
apps if no name is given, run with the running julia instead of the julia they
were installed with. The versions of the packages are kept, but the app
environments are resolved again for the running julia when needed.

Use this when the julia an app was installed with was removed (for example by
juliaup) or to move apps to a newer julia. Apps whose package does not support
the running julia according to its `julia` compat are skipped with a warning.
"""
relink(pkgs_or_apps::String) = relink([pkgs_or_apps])
function relink(pkgs_or_apps::Vector)
    if isempty(pkgs_or_apps)
        relink(nothing)
    else
        for pkg_or_app in pkgs_or_apps
            relink(pkg_or_app isa String ? PackageSpec(pkg_or_app) : pkg_or_app)
        end
    end
    return
end

relink(pkg::Union{PackageSpec, Nothing} = nothing) = with_apps_lock(() -> _relink(pkg))
function _relink(pkg::Union{PackageSpec, Nothing})
    ctx = app_context()
    manifest = ctx.env.manifest
    relinked = String[]
    found = false
    for (uuid, info) in manifest.deps
        if pkg !== nothing && info.name != pkg.name && !(pkg.name in keys(info.apps))
            continue
        end
        found = true
        sourcepath = developed_source_path(ctx.env.manifest_file, info)
        # Keep apps on their julia when the running one is outside their julia compat
        project = get_project(something(sourcepath, source_path(ctx.env.manifest_file, info)))
        if !(VERSION in Pkg.Operations.get_compat(project, "julia"))
            version = info.version === nothing ? "" : " v$(info.version)"
            julia_compat = Pkg.Operations.get_compat_str(project, "julia")
            @warn "Not relinking $(info.name): $(info.name)$version does not support Julia $VERSION (compat `julia = \"$julia_compat\"`), use `app update $(info.name)` to get a version that does"
            continue
        end
        push!(relinked, info.name)
        for (appname, app) in info.apps
            # an unset julia command is written as the running julia
            info.apps[appname] = AppInfo(app.name, nothing, app.submodule, app.julia_flags, app.project, app.other)
        end
        if sourcepath === nothing
            create_app_envs(info)
        else
            # resolve for the running julia, which can have other stdlib versions
            instantiate_developed(sourcepath, info.apps; resolve = true)
        end
        generate_shims_for_apps(info)
    end
    if pkg !== nothing && !found
        pkgerror("no app or package named `$(pkg.name)` found in the app manifest")
    end
    write_manifest(manifest, app_manifest_file())
    if Pkg.should_autoprecompile()
        foreach(precompile, relinked)
    end
    return
end

"""
    Pkg.Apps.status(name::Union{Nothing, String} = nothing)

Show the installed apps, the version of their package, and the julia command
used to run them. If `name` is given, limit the output to that app or package.
"""
function status(pkgs_or_apps::Vector; io::IO = stdout_f())
    return if isempty(pkgs_or_apps)
        status(; io)
    else
        for pkg_or_app in pkgs_or_apps
            if pkg_or_app isa String
                pkg_or_app = PackageSpec(pkg_or_app)
            end
            status(pkg_or_app; io)
        end
    end
end

status(pkg_or_app::String; kwargs...) = status(PackageSpec(pkg_or_app); kwargs...)
function status(pkg_or_app::Union{PackageSpec, Nothing} = nothing; io::IO = stdout_f())
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name
    manifest = read_manifest(app_manifest_file())
    deps = Pkg.Operations.load_manifest_deps(manifest)

    is_pkg = pkg_or_app !== nothing && any(dep -> dep.name == pkg_or_app, values(manifest.deps))
    missing_julia = false
    found = false

    for dep in sort!(deps; by = dep -> dep.name)
        info = manifest.deps[dep.uuid]
        if is_pkg && dep.name !== pkg_or_app
            continue
        end
        if !is_pkg && pkg_or_app !== nothing
            if !(pkg_or_app in keys(info.apps))
                continue
            end
        end
        found = true

        printstyled(io, "[", string(dep.uuid)[1:8], "] "; color = :light_black)
        print_single(io, dep)
        println(io)
        for appname in sort!(collect(keys(info.apps)))
            appinfo = info.apps[appname]
            if !is_pkg && pkg_or_app !== nothing && appname !== pkg_or_app
                continue
            end
            julia_cmd = contractuser(app_julia(appinfo))
            printstyled(io, "  $(appname)", color = :green)
            printstyled(io, " $(julia_cmd)", color = :gray)
            if !isfile(app_julia(appinfo))
                missing_julia = true
                printstyled(io, " (missing)"; color = :red)
            end
            println(io)
        end
    end
    if pkg_or_app !== nothing && !found
        pkgerror("no app or package named `$(pkg_or_app)` found in the app manifest")
    end
    if missing_julia
        printstyled(io, "Info"; color = :cyan, bold = true)
        println(
            io, " Some apps were installed with a julia that no longer exists and run with a fallback julia,",
            " use `app relink` to make them use the running julia"
        )
    end
    if found && !bin_in_path()
        printstyled(io, "Info"; color = :cyan, bold = true)
        println(io, " The directory with the apps, $(pathrepr(julia_bin_path())), is not in PATH. ", path_instructions())
    end
    return
end

function precompile(pkg::Union{Nothing, String} = nothing)
    manifest = Pkg.Types.read_manifest(app_manifest_file())
    deps = Pkg.Operations.load_manifest_deps(manifest)
    for dep in deps
        # TODO: Parallel app compilation..?
        info = manifest.deps[dep.uuid]
        if pkg !== nothing && info.name !== pkg
            continue
        end
        # Developed apps run directly from their project, tracked ones from the app environment
        sourcepath = developed_source_path(app_manifest_file(), info)
        envroot = sourcepath !== nothing ? sourcepath : app_env_dir(info.name)
        for subproject in subprojects(info.apps)
            Pkg.activate(subproject_path(envroot, subproject)) do
                Pkg.instantiate()
                Pkg.precompile()
            end
        end
    end
    return
end


function require_not_empty(pkgs, f::Symbol)
    return if pkgs === nothing || isempty(pkgs)
        pkgerror("app $f requires at least one package")
    end
end

"""
    Pkg.Apps.rm(name::String)

Remove the app `name`, or all apps of the package named `name`. This removes
the shims from `~/.julia/bin` and, when the last app of a package is removed,
its app environment.
"""
rm(pkgs_or_apps::String) = rm([pkgs_or_apps])
function rm(pkgs_or_apps::Vector)
    for pkg_or_app in pkgs_or_apps
        if pkg_or_app isa String
            pkg_or_app = PackageSpec(pkg_or_app)
        end
        rm(pkg_or_app)
    end
    return
end

rm(pkg_or_app::Union{PackageSpec, Nothing} = nothing) = with_apps_lock(() -> _rm(pkg_or_app))
function _rm(pkg_or_app::Union{PackageSpec, Nothing})
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name

    require_not_empty(pkg_or_app, :rm)

    manifest = Pkg.Types.read_manifest(app_manifest_file())
    dep_idx = findfirst(dep -> dep.name == pkg_or_app, manifest.deps)
    if dep_idx !== nothing
        dep = manifest.deps[dep_idx]
        foreach(appname -> rm_shim(appname; force = true), keys(dep.apps))
        report_removed(dep, collect(keys(dep.apps)))
        rm_package!(manifest, dep)
    else
        found = false
        for (uuid, pkg) in collect(manifest.deps)
            app_idx = findfirst(app -> app.name == pkg_or_app, pkg.apps)
            app_idx === nothing && continue
            found = true
            app = pkg.apps[app_idx]
            delete!(pkg.apps, app.name)
            rm_shim(app.name; force = true)
            report_removed(pkg, [app.name])
            isempty(pkg.apps) && rm_package!(manifest, pkg)
        end
        if !found
            pkgerror("no app or package named `$(pkg_or_app)` found in the app manifest")
        end
    end
    # XXX: What happens if something fails above and we do not write out the updated manifest?
    write_manifest(manifest, app_manifest_file())
    return
end

for f in (:develop, :add)
    @eval begin
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...) = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        function $f(;
                name::Union{Nothing, AbstractString} = nothing, uuid::Union{Nothing, String, UUID} = nothing,
                version::Union{VersionNumber, String, VersionSpec, Nothing} = nothing,
                url = nothing, rev = nothing, path = nothing, subdir = nothing, kwargs...
            )
            pkg = PackageSpec(; name, uuid, version, url, rev, path, subdir)
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


#########
# Shims #
#########

const SHIM_COMMENT = Sys.iswindows() ? "REM " : "#"
const SHIM_VERSION = 1.6
const SHIM_HEADER = """$SHIM_COMMENT This file is generated by the Julia package manager.
$SHIM_COMMENT Shim version: $SHIM_VERSION"""

# Depots after the first, excluding bundled depots (the shim appends those via
# a trailing empty entry so that they track the julia that runs it)
function stacked_depots()
    bundled = Base.append_bundled_depot_path!(String[])
    return String[normpath(d) for d in DEPOT_PATH[2:end] if normpath(d) ∉ bundled]
end

# Shims for the `apps` of the package `pkgname` at `sourcepath`, which run in the
# environments (one for each project used by the apps) in `envroot`
function generate_shims_for_apps(pkgname, apps, sourcepath, envroot, julia)
    for app in values(apps)
        generate_shim(app_package_name(pkgname, sourcepath, app), app, subproject_path(envroot, app.project), julia)
    end
    return
end

function generate_shim(pkgname, app::AppInfo, env, julia)
    validate_package_name(pkgname)
    validate_app_name(app.name)
    validate_submodule_name(app.submodule)

    module_spec = app.submodule === nothing ? pkgname : "$(pkgname).$(app.submodule)"

    julia_bin_filename = shim_path(app.name)
    channel = juliaup_channel(julia)
    content = Sys.iswindows() ? windows_shim(julia, module_spec, env, app.julia_flags; channel) :
        shell_shim(julia, module_spec, env, app.julia_flags; channel)
    overwrite_file_if_different(julia_bin_filename, content)
    return if Sys.isunix()
        chmod(julia_bin_filename, 0o755)
    end
end


function shell_shim(julia::String, module_spec::String, env, julia_flags::Vector{String}; channel::Union{@NamedTuple{name::String, config::String}, Nothing} = nothing)
    julia_escaped = Base.shell_escape(julia)
    module_spec_escaped = Base.shell_escape(module_spec)
    julia_flags_escaped = join(Base.shell_escape.(julia_flags), " ")
    julia_flags_part = isempty(julia_flags) ? "" : " $julia_flags_escaped"

    depot = normpath(first(DEPOT_PATH))
    depot_escaped = Base.shell_escape(depot)
    env = normpath(env)
    # Environments inside the depot are located relative to it so that the
    # depot can be relocated (developed projects keep their absolute path)
    load_path_part = if startswith(env, joinpath(depot, ""))
        "\"\$depot/$(join(splitpath(relpath(env, depot)), '/'))\""
    else
        Base.shell_escape(env)
    end

    # Stacked depots stay baked in so packages installed in them remain loadable
    depot_path_part = "\"\$depot:\"" * join(Base.shell_escape(d) * ":" for d in stacked_depots())

    return """
    #!/bin/sh
    set -eu

    $SHIM_HEADER

    # Locate the depot from the location of this script (<depot>/bin/<app>) so
    # that a relocated depot keeps working; fall back to the install time depot.
    # Symlinks to the script are followed to find where it is.
    script=\$0
    while [ -L "\$script" ]; do
        link=\$(readlink -- "\$script")
        case \$link in
            /*) script=\$link ;;
            *) script=\$(dirname -- "\$script")/\$link ;;
        esac
    done
    script_dir=\$(CDPATH= cd -- "\$(dirname -- "\$script")" && pwd -P)
    depot=\$(dirname -- "\$script_dir")
    if [ ! -e "\$depot/environments/apps/AppManifest.toml" ]; then
        depot=$depot_escaped
    fi

    # Pin Julia paths for the child process
    # (the trailing ':' appends the default system depots)
    export JULIA_DEPOT_PATH=$depot_path_part
    export JULIA_LOAD_PATH=$load_path_part

    # Allow overriding Julia executable via environment variable
    channel_arg=
    if [ -n "\${JULIA_APPS_JULIA_CMD:-}" ]; then
        julia_cmd="\$JULIA_APPS_JULIA_CMD"
    else
        julia_cmd=$julia_escaped
        if ! command -v "\$julia_cmd" >/dev/null 2>&1; then
            # The julia the app was installed with is gone (e.g. removed by juliaup)
    $(shell_fallback(channel))
        fi
    fi

    # If a `--` appears, args before it go to Julia, after it to the app.
    # If no `--` appears, all args go to the app (no Julia args).
    # Rebuild "\$@" in place as: <julia args> -m <module> <app args>, which
    # preserves argument boundaries exactly.
    orig_count=\$#
    seen_sep=false
    i=0
    while [ "\$i" -lt "\$orig_count" ]; do
        arg=\$1
        shift
        if [ "\$seen_sep" = false ] && [ "\$arg" = "--" ]; then
            seen_sep=true
            set -- "\$@" -m $module_spec_escaped
        else
            set -- "\$@" "\$arg"
        fi
        i=\$((i + 1))
    done
    if [ "\$seen_sep" = false ]; then
        set -- -m $module_spec_escaped "\$@"
    fi

    exec "\$julia_cmd" \${channel_arg:+"\$channel_arg"} --startup-file=no$julia_flags_part "\$@"
    """
end

# The part of the shell shim that picks another julia when the one the app was
# installed with is gone: the juliaup channel of the same minor version, or else
# the `julia` in `PATH`
function shell_fallback(channel)
    hint = "use \\`pkg> app relink\\` to make the app use another julia"
    lines = String[]
    if channel !== nothing
        append!(
            lines, [
                "juliaup_cmd=\$(command -v juliaup 2>/dev/null || true)",
                "# the juliaup launcher with the channel of the same minor version, if that is installed",
                "if [ -n \"\$juliaup_cmd\" ] && [ -x \"\$(dirname -- \"\$juliaup_cmd\")/julia\" ] &&",
                "        grep -qF '\"$(channel.name)\"' $(Base.shell_escape(channel.config)) 2>/dev/null; then",
                "    julia_cmd=\$(dirname -- \"\$juliaup_cmd\")/julia",
                "    channel_arg=+$(channel.name)",
                "elif command -v julia >/dev/null 2>&1; then",
            ]
        )
    else
        push!(lines, "if command -v julia >/dev/null 2>&1; then")
    end
    append!(
        lines, [
            "    echo \"warning: \$julia_cmd does not exist, running the app with the julia in PATH; $hint\" >&2",
            "    julia_cmd=julia",
            "else",
            "    echo \"error: \$julia_cmd does not exist and there is no julia in PATH; $hint\" >&2",
            "    exit 127",
            "fi",
        ]
    )
    return "        " * join(lines, "\n        ")
end

function escape_batch_set_value(s::AbstractString)
    occursin(r"[\"\r\n\0]", s) && pkgerror("cannot use $(repr(s)) in a Windows batch script")
    return replace(s, "%" => "%%")
end

function windows_shim(julia::String, module_spec::String, env, julia_flags::Vector{String}; channel::Union{@NamedTuple{name::String, config::String}, Nothing} = nothing)
    # Flags end up unquoted on the command line so escape cmd metacharacters
    flags_escaped = join((replace(Base.shell_escape_wincmd(f), "%" => "%%") for f in julia_flags), " ")
    flags_part = isempty(julia_flags) ? "" : " $flags_escaped"

    depot = normpath(first(DEPOT_PATH))
    env = normpath(env)
    # Environments inside the depot are located relative to it so that the
    # depot can be relocated (developed projects keep their absolute path)
    load_path = if startswith(env, joinpath(depot, ""))
        "%depot%\\$(escape_batch_set_value(relpath(env, depot)))"
    else
        escape_batch_set_value(env)
    end

    # Stacked depots stay baked in so packages installed in them remain loadable
    depot_path = "%depot%;" * join(escape_batch_set_value(d) * ";" for d in stacked_depots())

    return """
    @echo off
    setlocal EnableExtensions DisableDelayedExpansion

    $SHIM_HEADER

    rem --- Locate the depot from the location of this script (<depot>\\bin\\<app>) so
    rem --- that a relocated depot keeps working; fall back to the install time depot
    for %%I in ("%~dp0..") do set "depot=%%~fI"
    if not exist "%depot%\\environments\\apps\\AppManifest.toml" set "depot=$(escape_batch_set_value(depot))"

    rem --- Environment (no delayed expansion here to keep '!' literal) ---
    rem --- (the trailing ';' appends the default system depots) ---
    set "JULIA_LOAD_PATH=$load_path"
    set "JULIA_DEPOT_PATH=$depot_path"

    rem --- Allow overriding Julia executable via environment variable ---
    rem --- julia_cmd holds an unquoted path; the call sites add the quotes ---
    if defined JULIA_APPS_JULIA_CMD (
        set "julia_cmd=%JULIA_APPS_JULIA_CMD%"
    ) else (
        set "julia_cmd=$(escape_batch_set_value(julia))"
    )

    rem --- The julia the app was installed with is gone (e.g. removed by juliaup): ---
    rem --- use the juliaup channel of the same minor version or the julia in PATH ---
    set "channel_arg="
    if defined JULIA_APPS_JULIA_CMD goto __julia_found
    if exist "%julia_cmd%" goto __julia_found
    $(windows_fallback(channel))where julia >nul 2>nul || goto __no_julia
    echo warning: "%julia_cmd%" does not exist, running the app with the julia in PATH; use `pkg^> app relink` to make the app use another julia 1>&2
    set "julia_cmd=julia"
    goto __julia_found
    :__no_julia
    echo error: "%julia_cmd%" does not exist and there is no julia in PATH; use `pkg^> app relink` to make the app use another julia 1>&2
    exit /b 127
    :__julia_found

    rem --- Now enable delayed expansion for string building below ---
    setlocal EnableDelayedExpansion

    rem Parse arguments, splitting on first -- into julia_args / app_args
    set "found_sep="
    set "julia_args="
    set "app_args="

    :__next
    if "%~1"=="" goto __done

    if not defined found_sep if "%~1"=="--" (
        set "found_sep=1"
        shift
        goto __next
    )

    if not defined found_sep (
        if defined julia_args (
            set "julia_args=!julia_args! %1"
        ) else (
            set "julia_args=%1"
        )
        shift
        goto __next
    )

    if defined found_sep (
        if defined app_args (
            set "app_args=!app_args! %1"
        ) else (
            set "app_args=%1"
        )
        shift
        goto __next
    )

    :__done
    rem If no --, pass all original args to the app; otherwise use split vars
    if defined found_sep (
        "%julia_cmd%" %channel_arg% ^
            --startup-file=no$flags_part !julia_args! ^
            -m "$module_spec" ^
            !app_args!
    ) else (
        "%julia_cmd%" %channel_arg% ^
            --startup-file=no$flags_part ^
            -m "$module_spec" ^
            %*
    )
    """
end

function windows_fallback(channel)
    channel === nothing && return ""
    return """set "juliaup_dir="
    for /f "delims=" %%J in ('where juliaup 2^>nul') do if not defined juliaup_dir set "juliaup_dir=%%~dpJ"
    if not defined juliaup_dir goto __no_juliaup
    if not exist "%juliaup_dir%julia.exe" goto __no_juliaup
    findstr /l /c:"\\"$(channel.name)\\"" "$(escape_batch_set_value(channel.config))" >nul 2>nul || goto __no_juliaup
    set "julia_cmd=%juliaup_dir%julia.exe"
    set "channel_arg=+$(channel.name)"
    goto __julia_found
    :__no_juliaup
    """
end

end
