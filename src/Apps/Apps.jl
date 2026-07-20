module Apps

using Pkg
using Pkg: atomic_toml_write, stdout_f
using Pkg.Versions
using Pkg.Types: AppInfo, PackageSpec, Context, EnvCache, PackageEntry, Manifest, handle_repo_add!, handle_repo_develop!, write_manifest, write_project,
    pkgerror, projectfile_path
using Pkg.Operations: print_single, source_path, update_package_add
using Pkg.API: handle_package_input!
using TOML, UUIDs
using Dates
import FileWatching
import Pkg.Registry

public add, rm, status, update, develop

app_env_folder() = joinpath(first(DEPOT_PATH), "environments", "apps")
app_manifest_file() = joinpath(app_env_folder(), "AppManifest.toml")
julia_bin_path() = joinpath(first(DEPOT_PATH), "bin")
julia_executable() = joinpath(Sys.BINDIR, "julia" * (Sys.iswindows() ? ".exe" : ""))

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


function rm_shim(name; kwargs...)
    validate_app_name(name)
    return Base.rm(joinpath(julia_bin_path(), name * (Sys.iswindows() ? ".bat" : "")); kwargs...)
end

function get_project(sourcepath)
    project_file = projectfile_path(sourcepath)

    isfile(project_file) || pkgerror("Project file not found: $project_file")

    project = Pkg.Types.read_project(project_file)
    isempty(project.apps) && pkgerror("No apps found in Project.toml for package $(project.name) at version $(project.version)")
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

function check_apps_in_path(apps)
    for app_name in keys(apps)
        which_name = app_name * (Sys.iswindows() ? ".bat" : "")
        which_result = Sys.which(which_name)
        if which_result === nothing
            @warn """
            App '$app_name' was installed but is not available in PATH.
            Consider adding '$(julia_bin_path())' to your PATH environment variable.
            """ maxlog = 1
            break  # Only show warning once per installation
        else
            # Check for collisions
            expected_path = joinpath(julia_bin_path(), app_name * (Sys.iswindows() ? ".bat" : ""))
            if which_result != expected_path
                @warn """
                App '$app_name' collision detected:
                Expected: $expected_path
                Found: $which_result
                Another application with the same name exists in PATH.
                """
            end
        end
    end
    return
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


# Remove shims from a previous version of the package that it no longer
# provides and warn about app names that other packages already provide
function reconcile_shims(manifest::Manifest, pkg::PackageSpec, project)
    old_entry = get(manifest.deps, pkg.uuid, nothing)
    if old_entry !== nothing
        for appname in keys(old_entry.apps)
            haskey(project.apps, appname) || rm_shim(appname; force = true)
        end
    end
    for (uuid, entry) in manifest.deps
        uuid == pkg.uuid && continue
        overlap = sort!(collect(intersect(keys(entry.apps), keys(project.apps))))
        if !isempty(overlap)
            @warn "Overwriting apps $(join(overlap, ", ")) provided by package $(entry.name)"
        end
    end
    return
end


##################
# Main Functions #
##################

function _resolve(manifest::Manifest, pkgname = nothing)
    for (uuid, pkg) in manifest.deps
        if pkgname !== nothing && pkg.name !== pkgname
            continue
        end

        # TODO: Add support for existing manifest

        projectfile = joinpath(app_env_folder(), pkg.name, "Project.toml")

        sourcepath = source_path(app_manifest_file(), pkg)
        original_project_file = projectfile_path(sourcepath)

        mkpath(dirname(projectfile))

        if isfile(original_project_file)
            cp(original_project_file, projectfile; force = true)
            chmod(projectfile, 0o644)  # Make the copied project file writable

            project_data = TOML.parsefile(projectfile)

            # Paths inside the depot are written relative to the app environment
            # so that the depot can be relocated
            depot_prefix = joinpath(normpath(first(DEPOT_PATH)), "")
            project_dir = dirname(projectfile)
            relative_to_depot(path) = startswith(normpath(path), depot_prefix) ? relpath(path, project_dir) : path

            # Add entryfile stanza pointing to the package entry file,
            # respecting an existing entryfile in the project
            entryfile = get(project_data, "entryfile", joinpath("src", "$(pkg.name).jl"))
            entryfile = isabspath(entryfile) ? entryfile : normpath(joinpath(sourcepath, entryfile))
            project_data["entryfile"] = relative_to_depot(entryfile)

            # Relative paths in [sources] are relative to the original project
            # location, not the app environment the project file is copied to.
            # Resolve them against the original location (for packages added
            # from a local path) or the installed package tree; drop entries
            # that do not resolve so the dependency comes from a registry.
            sources = get(project_data, "sources", nothing)
            if sources !== nothing
                original_dir = nothing
                if pkg.repo.source !== nothing && !Pkg.isurl(pkg.repo.source)
                    original_dir = normpath(joinpath(app_env_folder(), pkg.repo.source))
                    if pkg.repo.subdir !== nothing
                        original_dir = joinpath(original_dir, pkg.repo.subdir)
                    end
                end
                for (depname, source) in collect(sources)
                    path = get(source, "path", nothing)
                    (path === nothing || isabspath(path)) && continue
                    candidates = String[]
                    original_dir !== nothing && push!(candidates, normpath(joinpath(original_dir, path)))
                    push!(candidates, normpath(joinpath(sourcepath, path)))
                    resolved = findfirst(isdir, candidates)
                    if resolved === nothing
                        @warn "Ignoring source with relative path `$(path)` for dependency $(depname) of package $(pkg.name) since it does not exist relative to the installed package"
                        delete!(source, "path")
                        isempty(source) && delete!(sources, depname)
                    else
                        source["path"] = relative_to_depot(candidates[resolved])
                    end
                end
                isempty(sources) && delete!(project_data, "sources")
            end

            atomic_toml_write(projectfile, project_data)
        else
            pkgerror("could not find project file for package $pkg")
        end

        # Create a manifest with the manifest entry
        Pkg.activate(joinpath(app_env_folder(), pkg.name)) do
            ctx = Context()
            ctx.env.manifest.deps[uuid] = pkg
            Pkg.resolve(ctx)
        end

        # TODO: Julia path
        generate_shims_for_apps(pkg.name, pkg.apps, dirname(projectfile), julia_executable())
    end
    return write_manifest(manifest, app_manifest_file())
end


"""
    Pkg.Apps.add(pkg::Union{String, PackageSpec})
    Pkg.Apps.add(; name, uuid, version, url, rev, path, subdir)

Install the apps of package `pkg`. The package is installed into an isolated
environment and shims for its apps are created in `~/.julia/bin` (which should
be added to `PATH`). Apps can be added from a registry, a git URL, or a local
path (which needs to be a git repository).

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
function _add(pkg::PackageSpec)
    handle_package_input!(pkg)

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

    # Run Pkg.build()?

    Base.rm(joinpath(app_env_folder(), pkg.name); force = true, recursive = true)
    sourcepath = source_path(ctx.env.manifest_file, pkg)
    project = get_project(sourcepath)
    reconcile_shims(manifest, pkg, project)
    # TODO: Wrong if package itself has a sourcepath?
    # PackageEntry requires version::Union{VersionNumber, Nothing}, but project.version can be VersionSpec
    entry = PackageEntry(; apps = project.apps, name = pkg.name, version = project.version isa VersionNumber ? project.version : nothing, tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid = pkg.uuid)
    manifest.deps[pkg.uuid] = entry

    _resolve(manifest, pkg.name)
    if new === true || (new isa Set{UUID} && pkg.uuid in new)
        Pkg.Operations.build_versions(ctx, Set([pkg.uuid]); verbose = true)
    end
    precompile(pkg.name)

    @info "For package: $(pkg.name) installed apps $(join(keys(project.apps), ","))"
    return check_apps_in_path(project.apps)
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
    Base.rm(joinpath(app_env_folder(), pkg.name); force = true, recursive = true)
    sourcepath = abspath(source_path(ctx.env.manifest_file, pkg))
    project = get_project(sourcepath)

    # Seems like the `.repo.source` field is not cleared.
    # At least repo-url is still in the manifest after doing a dev with a path
    # Figure out why for normal dev this is not needed.
    # XXX: Why needed?
    if pkg.path !== nothing
        pkg.repo.source = nothing
    end

    # PackageEntry requires version::Union{VersionNumber, Nothing}, but project.version can be VersionSpec
    entry = PackageEntry(; apps = project.apps, name = pkg.name, version = project.version isa VersionNumber ? project.version : nothing, tree_hash = pkg.tree_hash, path = sourcepath, repo = pkg.repo, uuid = pkg.uuid)
    manifest = ctx.env.manifest
    reconcile_shims(manifest, pkg, project)
    manifest.deps[pkg.uuid] = entry

    # For dev, we don't create an app environment - just point shims directly to the dev'd project
    write_manifest(manifest, app_manifest_file())

    # The shims run with the dev'd project as the load path so it needs
    # a resolved manifest for the dependencies to be loadable
    Pkg.activate(sourcepath) do
        Pkg.instantiate()
    end

    generate_shims_for_apps(pkg.name, project.apps, sourcepath, julia_executable())

    @info "For package: $(pkg.name) installed apps: $(join(keys(project.apps), ","))"
    return check_apps_in_path(project.apps)
end


"""
    Pkg.Apps.update(name::Union{Nothing, String} = nothing)

Update the package providing the app `name` (or the package named `name`) to
the latest compatible version, or all installed apps if no name is given.
For developed packages the dependencies of the project are updated instead.
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
    for dep in deps
        info = manifest.deps[dep.uuid]
        if pkg !== nothing && info.name != pkg.name && !(pkg.name in keys(info.apps))
            continue
        end
        updated = true
        if info.path !== nothing
            # Developed app: update the dependencies of the developed project
            # and refresh the app info from it
            sourcepath = abspath(source_path(ctx.env.manifest_file, info))
            Pkg.activate(sourcepath) do
                Pkg.update()
            end
            develop(PackageSpec(path = sourcepath))
        elseif info.repo.source !== nothing || info.repo.rev !== nothing
            # Repo tracked app: re-add to fetch the latest revision
            add(PackageSpec(name = info.name, uuid = info.uuid, url = info.repo.source, rev = info.repo.rev, subdir = info.repo.subdir))
        else
            # Registry tracked app: re-add to resolve the latest version
            add(PackageSpec(name = info.name, uuid = info.uuid))
        end
    end
    if pkg !== nothing && !updated
        pkgerror("no app or package named `$(pkg.name)` found in the app manifest")
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

function status(pkg_or_app::Union{PackageSpec, Nothing} = nothing; io::IO = stdout_f())
    # TODO: Sort.
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name
    manifest = Pkg.Types.read_manifest(app_manifest_file())
    deps = Pkg.Operations.load_manifest_deps(manifest)

    is_pkg = pkg_or_app !== nothing && any(dep -> dep.name == pkg_or_app, values(manifest.deps))

    for dep in deps
        info = manifest.deps[dep.uuid]
        if is_pkg && dep.name !== pkg_or_app
            continue
        end
        if !is_pkg && pkg_or_app !== nothing
            if !(pkg_or_app in keys(info.apps))
                continue
            end
        end

        printstyled(io, "[", string(dep.uuid)[1:8], "] "; color = :light_black)
        print_single(io, dep)
        println(io)
        for (appname, appinfo) in info.apps
            if !is_pkg && pkg_or_app !== nothing && appname !== pkg_or_app
                continue
            end
            julia_cmd = contractuser(appinfo.julia_command)
            printstyled(io, "  $(appname)", color = :green)
            printstyled(io, " $(julia_cmd) \n", color = :gray)
        end
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
        env_dir = info.path !== nothing ? abspath(source_path(app_manifest_file(), info)) :
            joinpath(app_env_folder(), info.name)
        Pkg.activate(env_dir) do
            Pkg.instantiate()
            Pkg.precompile()
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
        @info "Deleting all apps for package $(dep.name)"
        delete!(manifest.deps, dep.uuid)
        for (appname, appinfo) in dep.apps
            @info "Deleted $(appname)"
            rm_shim(appname; force = true)
        end
        if dep.path === nothing
            Base.rm(joinpath(app_env_folder(), dep.name); recursive = true, force = true)
        end
    else
        found = false
        for (uuid, pkg) in collect(manifest.deps)
            app_idx = findfirst(app -> app.name == pkg_or_app, pkg.apps)
            app_idx === nothing && continue
            found = true
            app = pkg.apps[app_idx]
            @info "Deleted app $(app.name)"
            delete!(pkg.apps, app.name)
            rm_shim(app.name; force = true)
            if isempty(pkg.apps)
                delete!(manifest.deps, uuid)
                if pkg.path === nothing
                    Base.rm(joinpath(app_env_folder(), pkg.name); recursive = true, force = true)
                end
            end
        end
        if !found
            pkgerror("no app or package named `$(pkg_or_app)` found in the app manifest")
        end
    end
    # XXX: What happens if something fails above and we do not write out the updated manifest?
    Pkg.Types.write_manifest(manifest, app_manifest_file())
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
const SHIM_VERSION = 1.2
const SHIM_HEADER = """$SHIM_COMMENT This file is generated by the Julia package manager.
$SHIM_COMMENT Shim version: $SHIM_VERSION"""

function generate_shims_for_apps(pkgname, apps, env, julia)
    for (_, app) in apps
        generate_shim(pkgname, app, env, julia)
    end
    return
end

function generate_shim(pkgname, app::AppInfo, env, julia)
    validate_package_name(pkgname)
    validate_app_name(app.name)
    validate_submodule_name(app.submodule)

    module_spec = app.submodule === nothing ? pkgname : "$(pkgname).$(app.submodule)"

    filename = app.name * (Sys.iswindows() ? ".bat" : "")
    julia_bin_filename = joinpath(julia_bin_path(), filename)
    mkpath(dirname(julia_bin_filename))
    content = if Sys.iswindows()
        julia_escaped = "\"$(Base.shell_escape_wincmd(julia))\""
        module_spec_escaped = "\"$(Base.shell_escape_wincmd(module_spec))\""
        windows_shim(julia_escaped, module_spec_escaped, env, app.julia_flags)
    else
        julia_escaped = Base.shell_escape(julia)
        module_spec_escaped = Base.shell_escape(module_spec)
        shell_shim(julia_escaped, module_spec_escaped, env, app.julia_flags)
    end
    overwrite_file_if_different(julia_bin_filename, content)
    return if Sys.isunix()
        chmod(julia_bin_filename, 0o755)
    end
end


function shell_shim(julia_escaped::String, module_spec_escaped::String, env, julia_flags::Vector{String})
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

    return """
    #!/bin/sh
    set -eu

    $SHIM_HEADER

    # Locate the depot from the location of this script (<depot>/bin/<app>) so
    # that a relocated depot keeps working; fall back to the install time depot
    script_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd -P)
    depot=\$(dirname -- "\$script_dir")
    if [ ! -e "\$depot/environments/apps/AppManifest.toml" ]; then
        depot=$depot_escaped
    fi

    # Pin Julia paths for the child process
    # (the trailing ':' appends the default system depots)
    export JULIA_DEPOT_PATH="\$depot:"
    export JULIA_LOAD_PATH=$load_path_part

    # Allow overriding Julia executable via environment variable
    if [ -n "\${JULIA_APPS_JULIA_CMD:-}" ]; then
        julia_cmd="\$JULIA_APPS_JULIA_CMD"
    else
        julia_cmd=$julia_escaped
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

    exec "\$julia_cmd" --startup-file=no$julia_flags_part "\$@"
    """
end

function windows_shim(
        julia_escaped::String,
        module_spec_escaped::String,
        env,
        julia_flags::Vector{String},
    )
    flags_escaped = join(Base.shell_escape_wincmd.(julia_flags), " ")
    flags_part = isempty(julia_flags) ? "" : " $flags_escaped"

    depot = normpath(first(DEPOT_PATH))
    env = normpath(env)
    # Environments inside the depot are located relative to it so that the
    # depot can be relocated (developed projects keep their absolute path)
    load_path = if startswith(env, joinpath(depot, ""))
        "%depot%\\$(relpath(env, depot))"
    else
        env
    end

    return """
    @echo off
    setlocal EnableExtensions DisableDelayedExpansion

    $SHIM_HEADER

    rem --- Locate the depot from the location of this script (<depot>\\bin\\<app>) so
    rem --- that a relocated depot keeps working; fall back to the install time depot
    for %%I in ("%~dp0..") do set "depot=%%~fI"
    if not exist "%depot%\\environments\\apps\\AppManifest.toml" set "depot=$depot"

    rem --- Environment (no delayed expansion here to keep '!' literal) ---
    rem --- (the trailing ';' appends the default system depots) ---
    set "JULIA_LOAD_PATH=$load_path"
    set "JULIA_DEPOT_PATH=%depot%;"

    rem --- Allow overriding Julia executable via environment variable ---
    if defined JULIA_APPS_JULIA_CMD (
        set "julia_cmd=%JULIA_APPS_JULIA_CMD%"
    ) else (
        set "julia_cmd=$julia_escaped"
    )

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
        "%julia_cmd%" ^
            --startup-file=no$flags_part !julia_args! ^
            -m $module_spec_escaped ^
            !app_args!
    ) else (
        "%julia_cmd%" ^
            --startup-file=no$flags_part ^
            -m $module_spec_escaped ^
            %*
    )
    """
end

end
