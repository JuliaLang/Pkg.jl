module Apps

using Pkg
using Pkg.Versions
using Pkg.Types: AppInfo, PackageSpec, Context, EnvCache, PackageEntry, Manifest, handle_repo_add!, handle_repo_develop!, write_manifest, write_project,
                 pkgerror, projectfile_path, manifestfile_path
using Pkg.Operations: print_single, source_path, update_package_add
using Pkg.API: handle_package_input!
using TOML, UUIDs
import Pkg.Registry

app_env_folder() = joinpath(first(DEPOT_PATH), "environments", "apps")
app_manifest_file() = joinpath(app_env_folder(), "AppManifest.toml")
julia_bin_path() = joinpath(first(DEPOT_PATH), "bin")

app_context() = Context(env=EnvCache(joinpath(app_env_folder(), "Project.toml")))

function validate_app_name(name::AbstractString)
    if isempty(name)
        error("App name cannot be empty")
    end
    if !occursin(r"^[a-zA-Z][a-zA-Z0-9_-]*$", name)
        error("App name must start with a letter and contain only letters, numbers, underscores, and hyphens")
    end
    if occursin(r"\.\.", name) || occursin(r"[/\\]", name)
        error("App name cannot contain path traversal sequences or path separators")
    end
end

function validate_package_name(name::AbstractString)
    if isempty(name)
        error("Package name cannot be empty")
    end
    if !occursin(r"^[a-zA-Z][a-zA-Z0-9_]*$", name)
        error("Package name must start with a letter and contain only letters, numbers, and underscores")
    end
end

function validate_submodule_name(name::Union{AbstractString,Nothing})
    if name !== nothing
        if isempty(name)
            error("Submodule name cannot be empty")
        end
        if !occursin(r"^[a-zA-Z][a-zA-Z0-9_]*$", name)
            error("Submodule name must start with a letter and contain only letters, numbers, and underscores")
        end
    end
end


function rm_shim(name; kwargs...)
    validate_app_name(name)
    Base.rm(joinpath(julia_bin_path(), name * (Sys.iswindows() ? ".bat" : "")); kwargs...)
end

function get_project(sourcepath)
    project_file = projectfile_path(sourcepath)

    isfile(project_file) || error("Project file not found: $project_file")

    project = Pkg.Types.read_project(project_file)
    isempty(project.apps) && error("No apps found in Project.toml for package $(project.name) at version $(project.version)")
    return project
end


function overwrite_file_if_different(file, content)
    if !isfile(file) || read(file, String) != content
        mkpath(dirname(file))
        write(file, content)
    end
end

function check_apps_in_path(apps)
    for app_name in keys(apps)
        which_result = Sys.which(app_name)
        if which_result === nothing
            @warn """
            App '$app_name' was installed but is not available in PATH.
            Consider adding '$(julia_bin_path())' to your PATH environment variable.
            """ maxlog=1
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
end

function get_max_version_register(pkg::PackageSpec, regs)
    max_v = nothing
    tree_hash = nothing
    for reg in regs
        if get(reg, pkg.uuid, nothing) !== nothing
            reg_pkg = get(reg, pkg.uuid, nothing)
            reg_pkg === nothing && continue
            pkg_info = Registry.registry_info(reg_pkg)
            for (version, info) in pkg_info.version_info
                info.yanked && continue
                if pkg.version isa VersionNumber
                    pkg.version == version || continue
                else
                    version in pkg.version || continue
                end
                if max_v === nothing || version > max_v
                    max_v = version
                    tree_hash = info.git_tree_sha1
                end
            end
        end
    end
    if max_v === nothing
        error("Suitable package version for $(pkg.name) not found in any registries.")
    end
    return (max_v, tree_hash)
end


##################
# Main Functions #
##################

function _resolve(manifest::Manifest, pkgname=nothing)
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
            cp(original_project_file, projectfile; force=true)
            chmod(projectfile, 0o644)  # Make the copied project file writable

            # Add entryfile stanza pointing to the package entry file
            # TODO: What if project file has its own entryfile?
            project_data = TOML.parsefile(projectfile)
            project_data["entryfile"] = joinpath(sourcepath, "src", "$(pkg.name).jl")
            open(projectfile, "w") do io
                TOML.print(io, project_data)
            end
        else
            error("could not find project file for package $pkg")
        end

        # Create a manifest with the manifest entry
        Pkg.activate(joinpath(app_env_folder(), pkg.name)) do
            ctx = Context()
            ctx.env.manifest.deps[uuid] = pkg
            Pkg.resolve(ctx)
        end

        # TODO: Julia path
        generate_shims_for_apps(pkg.name, pkg.apps, dirname(projectfile), joinpath(Sys.BINDIR, "julia"))
    end
    write_manifest(manifest, app_manifest_file())
end


function add(pkg::Vector{PackageSpec})
    for p in pkg
        add(p)
    end
end


function add(pkg::PackageSpec)
    handle_package_input!(pkg)

    ctx = app_context()
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
        Pkg.Operations.ensure_resolved(ctx, manifest, pkgs, registry=true)

        pkg.version, pkg.tree_hash = get_max_version_register(pkg, ctx.registries)

        new = Pkg.Operations.download_source(ctx, pkgs)
    end

    # Run Pkg.build()?

    Base.rm(joinpath(app_env_folder(), pkg.name); force=true, recursive=true)
    sourcepath = source_path(ctx.env.manifest_file, pkg)
    project = get_project(sourcepath)
    # TODO: Wrong if package itself has a sourcepath?
    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid=pkg.uuid)
    manifest.deps[pkg.uuid] = entry

    _resolve(manifest, pkg.name)
    precompile(pkg.name)

    @info "For package: $(pkg.name) installed apps $(join(keys(project.apps), ","))"
    check_apps_in_path(project.apps)
end

function develop(pkg::Vector{PackageSpec})
    for p in pkg
        develop(p)
    end
end

function develop(pkg::PackageSpec)
    if pkg.path !== nothing
        pkg.path == abspath(pkg.path)
    end
    handle_package_input!(pkg)
    ctx = app_context()
    handle_repo_develop!(ctx, pkg, #=shared =# true)
    Base.rm(joinpath(app_env_folder(), pkg.name); force=true, recursive=true)
    sourcepath = abspath(source_path(ctx.env.manifest_file, pkg))
    project = get_project(sourcepath)

    # Seems like the `.repo.source` field is not cleared.
    # At least repo-url is still in the manifest after doing a dev with a path
    # Figure out why for normal dev this is not needed.
    # XXX: Why needed?
    if pkg.path !== nothing
        pkg.repo.source = nothing
    end


    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = sourcepath, repo = pkg.repo, uuid=pkg.uuid)
    manifest = ctx.env.manifest
    manifest.deps[pkg.uuid] = entry

    _resolve(manifest, pkg.name)
    precompile(pkg.name)
    @info "For package: $(pkg.name) installed apps: $(join(keys(project.apps), ","))"
    check_apps_in_path(project.apps)
end


update(pkgs_or_apps::String) = update([pkgs_or_apps])
function update(pkgs_or_apps::Vector)
    for pkg_or_app in pkgs_or_apps
        if pkg_or_app isa String
            pkg_or_app = PackageSpec(pkg_or_app)
        end
        update(pkg_or_app)
    end
end

# XXX: Is updating an app ever different from rm-ing and adding it from scratch?
function update(pkg::Union{PackageSpec, Nothing}=nothing)
    ctx = app_context()
    manifest = ctx.env.manifest
    deps = Pkg.Operations.load_manifest_deps(manifest)
    for dep in deps
        info = manifest.deps[dep.uuid]
        if pkg === nothing || info.name !== pkg.name
            continue
        end
        Pkg.activate(joinpath(app_env_folder(), info.name)) do
            # precompile only after updating all apps?
            if pkg !== nothing
                Pkg.update(pkg)
            else
                Pkg.update()
            end
        end
        sourcepath = abspath(source_path(ctx.env.manifest_file, info))
        project = get_project(sourcepath)
        # Get the tree hash from the project file
        manifest_file = manifestfile_path(joinpath(app_env_folder(), info.name))
        manifest_app = Pkg.Types.read_manifest(manifest_file)
        manifest_entry = manifest_app.deps[info.uuid]

        entry = PackageEntry(;apps = project.apps, name = manifest_entry.name, version = manifest_entry.version, tree_hash = manifest_entry.tree_hash,
                             path = manifest_entry.path, repo = manifest_entry.repo, uuid = manifest_entry.uuid)

        manifest.deps[dep.uuid] = entry
        Pkg.Types.write_manifest(manifest, app_manifest_file())
    end
    return
end

function status(pkgs_or_apps::Vector)
    if isempty(pkgs_or_apps)
        status()
    else
        for pkg_or_app in pkgs_or_apps
            if pkg_or_app isa String
                pkg_or_app = PackageSpec(pkg_or_app)
            end
            status(pkg_or_app)
        end
    end
end

function status(pkg_or_app::Union{PackageSpec, Nothing}=nothing)
    # TODO: Sort.
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name
    manifest = Pkg.Types.read_manifest(joinpath(app_env_folder(), "AppManifest.toml"))
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

        printstyled("[", string(dep.uuid)[1:8], "] "; color = :light_black)
        print_single(stdout, dep)
        println()
        for (appname, appinfo) in info.apps
            if !is_pkg && pkg_or_app !== nothing && appname !== pkg_or_app
                continue
            end
            julia_cmd = contractuser(appinfo.julia_command)
            printstyled("  $(appname)", color=:green)
            printstyled(" $(julia_cmd) \n", color=:gray)
        end
    end
end

function precompile(pkg::Union{Nothing, String}=nothing)
    manifest = Pkg.Types.read_manifest(joinpath(app_env_folder(), "AppManifest.toml"))
    deps = Pkg.Operations.load_manifest_deps(manifest)
    for dep in deps
        # TODO: Parallel app compilation..?
        info = manifest.deps[dep.uuid]
        if pkg !== nothing && info.name !== pkg
            continue
        end
        Pkg.activate(joinpath(app_env_folder(), info.name)) do
            Pkg.instantiate()
            Pkg.precompile()
        end
    end
end


function require_not_empty(pkgs, f::Symbol)
    if pkgs === nothing || isempty(pkgs)
        pkgerror("app $f requires at least one package")
    end
end

rm(pkgs_or_apps::String) = rm([pkgs_or_apps])
function rm(pkgs_or_apps::Vector)
    for pkg_or_app in pkgs_or_apps
        if pkg_or_app isa String
            pkg_or_app = PackageSpec(pkg_or_app)
        end
        rm(pkg_or_app)
    end
end

function rm(pkg_or_app::Union{PackageSpec, Nothing}=nothing)
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name

    require_not_empty(pkg_or_app, :rm)

    manifest = Pkg.Types.read_manifest(joinpath(app_env_folder(), "AppManifest.toml"))
    dep_idx = findfirst(dep -> dep.name == pkg_or_app, manifest.deps)
    if dep_idx !== nothing
        dep = manifest.deps[dep_idx]
        @info "Deleting all apps for package $(dep.name)"
        delete!(manifest.deps, dep.uuid)
        for (appname, appinfo) in dep.apps
            @info "Deleted $(appname)"
            rm_shim(appname; force=true)
        end
        if dep.path === nothing
            Base.rm(joinpath(app_env_folder(), dep.name); recursive=true)
        end
    else
        for (uuid, pkg) in manifest.deps
            app_idx = findfirst(app -> app.name == pkg_or_app, pkg.apps)
            if app_idx !== nothing
                app = pkg.apps[app_idx]
                @info "Deleted app $(app.name)"
                delete!(pkg.apps, app.name)
                rm_shim(app.name; force=true)
            end
            if isempty(pkg.apps)
                delete!(manifest.deps, uuid)
                Base.rm(joinpath(app_env_folder(), pkg.name); recursive=true)
            end
        end
    end
    # XXX: What happens if something fails above and we do not write out the updated manifest?
    Pkg.Types.write_manifest(manifest, app_manifest_file())
    return
end

for f in (:develop, :add)
    @eval begin
        $f(pkg::Union{AbstractString, PackageSpec}; kwargs...) = $f([pkg]; kwargs...)
        $f(pkgs::Vector{<:AbstractString}; kwargs...)          = $f([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
        function $f(; name::Union{Nothing,AbstractString}=nothing, uuid::Union{Nothing,String,UUID}=nothing,
                      version::Union{VersionNumber, String, VersionSpec, Nothing}=nothing,
                      url=nothing, rev=nothing, path=nothing, subdir=nothing, kwargs...)
            pkg = PackageSpec(; name, uuid, version, url, rev, path, subdir)
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


#########
# Shims #
#########

const SHIM_COMMENT = Sys.iswindows() ? "REM " : "#"
const SHIM_VERSION = 1.0
const SHIM_HEADER = """$SHIM_COMMENT This file is generated by the Julia package manager.
                       $SHIM_COMMENT Shim version: $SHIM_VERSION"""

function generate_shims_for_apps(pkgname, apps, env, julia)
    for (_, app) in apps
        generate_shim(pkgname, app, env, julia)
    end
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
        windows_shim(julia_escaped, module_spec_escaped, env)
    else
        julia_escaped = Base.shell_escape(julia)
        module_spec_escaped = Base.shell_escape(module_spec)
        bash_shim(julia_escaped, module_spec_escaped, env)
    end
    overwrite_file_if_different(julia_bin_filename, content)
    if Sys.isunix()
        chmod(julia_bin_filename, 0o755)
    end
end


function bash_shim(julia_escaped::String, module_spec_escaped::String, env)
    return """
        #!/usr/bin/env bash

        $SHIM_HEADER

        export JULIA_LOAD_PATH=$(repr(env))
        export JULIA_DEPOT_PATH=$(repr(join(DEPOT_PATH, ':')))
        exec $julia_escaped \\
            --startup-file=no \\
            -m $module_spec_escaped \\
            "\$@"
        """
end

function windows_shim(julia_escaped::String, module_spec_escaped::String, env)
    return """
        @echo off

        $SHIM_HEADER

        setlocal
        set JULIA_LOAD_PATH=$env
        set JULIA_DEPOT_PATH=$(join(DEPOT_PATH, ';'))

        $julia_escaped ^
            --startup-file=no ^
            -m $module_spec_escaped ^
            %*
        """
end

end
