module Apps

using Pkg
using Pkg.Types: AppInfo, PackageSpec, Context, EnvCache, PackageEntry, handle_repo_add!, handle_repo_develop!, write_manifest, write_project,
                 pkgerror
using Pkg.Operations: print_single, source_path
using Pkg.API: handle_package_input!
using TOML, UUIDs
import Pkg.Registry

#############
# Constants #
#############

const APP_ENV_FOLDER = joinpath(homedir(), ".julia", "environments", "apps")
const APP_MANIFEST_FILE = joinpath(APP_ENV_FOLDER, "AppManifest.toml")
const JULIA_BIN_PATH = joinpath(homedir(), ".julia", "bin")
const XDG_BIN_PATH = joinpath(homedir(), ".local", "bin")

##################
# Helper Methods #
##################

function rm_julia_and_xdg_bin(name; kwargs)
    Base.rm(joinpath(JULIA_BIN_PATH, name); kwargs...)
    Base.rm(joinpath(XDG_BIN_PATH, name); kwargs...)
end

function handle_project_file(sourcepath)
    project_file = joinpath(sourcepath, "Project.toml")
    isfile(project_file) || error("Project file not found: $project_file")

    project = Pkg.Types.read_project(project_file)
    isempty(project.apps) && error("No apps found in Project.toml for package $(project.name) at version $(project.version)")
    return project
end

function update_app_manifest(pkg)
    manifest = Pkg.Types.read_manifest(APP_MANIFEST_FILE)
    manifest.deps[pkg.uuid] = pkg
    write_manifest(manifest, APP_MANIFEST_FILE)
end

function overwrite_if_different(file, content)
    if !isfile(file) || read(file, String) != content
        open(file, "w") do f
            write(f, content)
        end
    end
end

function get_latest_version_register(pkg::PackageSpec, regs)
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

app_context() = Context(env=EnvCache(joinpath(APP_ENV_FOLDER, "Project.toml")))

##################
# Main Functions #
##################

# TODO: Add functions similar to API that takes name, Vector{String} etc and promotes it to `Vector{PackageSpec}`..

function add(pkg::String)
    pkg = PackageSpec(pkg)
    add(pkg)
end

function add(pkg::Vector{PackageSpec})
    for p in pkg
        add(p)
    end
end

function add(pkg::PackageSpec)
    handle_package_input!(pkg)

    ctx = app_context()
    new = false
    if pkg.repo.source !== nothing || pkg.repo.rev !== nothing
        entry = Pkg.API.manifest_info(ctx.env.manifest, pkg.uuid)
        pkg = Pkg.Operations.update_package_add(ctx, pkg, entry, false)
        new = handle_repo_add!(ctx, pkg)
    else
        pkgs = [pkg]
        Pkg.Operations.registry_resolve!(ctx.registries, pkgs)
        Pkg.Operations.ensure_resolved(ctx, ctx.env.manifest, pkgs, registry=true)

        pkg.version, pkg.tree_hash = get_latest_version_register(pkg, ctx.registries)

        new = Pkg.Operations.download_source(ctx, pkgs)
    end

    sourcepath = source_path(ctx.env.manifest_file, pkg)
    project = handle_project_file(sourcepath)
    project.path = sourcepath

    # TODO: Type stab
    # appdeps = get(project, "appdeps", Dict())
    # merge!(project.deps, appdeps)

    projectfile = joinpath(APP_ENV_FOLDER, pkg.name, "Project.toml")
    mkpath(dirname(projectfile))
    write_project(project, projectfile)

    # Move manifest if it exists here.

    Pkg.activate(joinpath(APP_ENV_FOLDER, pkg.name))
    Pkg.instantiate()

    if new
        # TODO: Call build on the package if it was freshly installed?
    end

    # Create the new package env.
    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid=pkg.uuid)
    update_app_manifest(entry)
    generate_shims_for_apps(entry.name, entry.apps, dirname(projectfile))
end


function develop(pkg::String)
    develop(PackageSpec(pkg))
end

function develop(pkg::PackageSpec)
    handle_package_input!(pkg)
    ctx = app_context()

    handle_repo_develop!(ctx, pkg, #=shared =# true)


    project = handle_project_file(pkg.path)

    # Seems like the `.repo.source` field is not cleared.
    # At least repo-url is still in the manifest after doing a dev with a path
    # Figure out why for normal dev this is not needed.
    # XXX: Why needed?
    if pkg.path !== nothing
        pkg.repo.source = nothing
    end

    entry = PackageEntry(;apps = project.apps, name = pkg.name, version = project.version, tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid=pkg.uuid)
    update_app_manifest(entry)
    generate_shims_for_apps(entry.name, entry.apps, entry.path)
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
    # TODO: Show julia version
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name
    manifest = Pkg.Types.read_manifest(joinpath(APP_ENV_FOLDER, "AppManifest.toml"))
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
        single_app = length(info.apps) == 1
        if !single_app
            println()
        else
            print(":")
        end
        for (appname, appinfo) in info.apps
            if !is_pkg && pkg_or_app !== nothing && appname !== pkg_or_app
                continue
            end
            printstyled("  $(appname) $(appinfo.julia_command) \n", color=:green)
        end
    end
end

function precompile(pkg::Union{Nothing, String}=nothing)
    manifest = Pkg.Types.read_manifest(joinpath(APP_ENV_FOLDER, "AppManifest.toml"))
    deps = Pkg.Operations.load_manifest_deps(manifest)
    for dep in deps
        # TODO: Parallel app compilation..?
        info = manifest.deps[dep.uuid]
        if pkg !== nothing && info.name !== pkg
            continue
        end
        Pkg.activate(joinpath(APP_ENV_FOLDER, info.name)) do
            @info "Precompiling $(info.name)..."
            Pkg.precompile()
        end
    end
end

function require_not_empty(pkgs, f::Symbol)
    pkgs === nothing && return
    isempty(pkgs) && pkgerror("app $f requires at least one package")
end

function rm(pkgs_or_apps::Union{Vector, Nothing})
    if pkgs_or_apps === nothing
        rm(nothing)
    else
        for pkg_or_app in pkgs_or_apps
            if pkg_or_app isa String
                pkg_or_app = PackageSpec(pkg_or_app)
            end
            rm(pkg_or_app)
        end
    end
end

function rm(pkg_or_app::Union{PackageSpec, Nothing}=nothing)
    pkg_or_app = pkg_or_app === nothing ? nothing : pkg_or_app.name

    require_not_empty(pkg_or_app, :rm)

    manifest = Pkg.Types.read_manifest(joinpath(APP_ENV_FOLDER, "AppManifest.toml"))
    dep_idx = findfirst(dep -> dep.name == pkg_or_app, manifest.deps)
    if dep_idx !== nothing
        dep = manifest.deps[dep_idx]
        @info "Deleted all apps for package $(dep.name)"
        delete!(manifest.deps, dep.uuid)
        for (appname, appinfo) in dep.apps
            @info "Deleted $(appname)"
            rm_julia_and_xdg_bin(appname; force=true)
        end
        Base.rm(joinpath(APP_ENV_FOLDER, dep.name); recursive=true)
    else
        for (uuid, pkg) in manifest.deps
            app_idx = findfirst(app -> app.name == pkg_or_app, pkg.apps)
            if app_idx !== nothing
                app = pkg.apps[app_idx]
                @info "Deleted app $(app.name)"
                delete!(pkg.apps, app.name)
                rm_julia_and_xdg_bin(appname; force=true)
            end
            if isempty(pkg.apps)
                delete!(manifest.deps, uuid)
                Base.rm(joinpath(APP_ENV_FOLDER, pkg.name); recursive=true)
            end
        end
    end

    Pkg.Types.write_manifest(manifest, APP_MANIFEST_FILE)
    return
end



#########
# Shims #
#########

function generate_shims_for_apps(pkgname, apps, env)
    for (_, app) in apps
        generate_shim(app, pkgname; env)
    end
end

function generate_shim(app::AppInfo, pkgname; julia_executable_path::String=joinpath(Sys.BINDIR, "julia"), env=joinpath(homedir(), ".julia", "environments", "apps", pkgname))
    filename = app.name * (Sys.iswindows() ? ".bat" : "")
    julia_bin_filename = joinpath(JULIA_BIN_PATH, filename)
    mkpath(dirname(filename))
    content = if Sys.iswindows()
        windows_shim(pkgname, julia_executable_path, env)
    else
        bash_shim(pkgname, julia_executable_path, env)
    end
    # TODO: Only overwrite if app is "controlled" by Julia?
    overwrite_if_different(julia_bin_filename, content)
    if Sys.isunix()
        if isdir(XDG_BIN_PATH) && !isfile(joinpath(XDG_BIN_PATH, filename))
            # TODO: Verify that this symlink is in fact pointing to the correct file.
            symlink(julia_bin_filename, joinpath(XDG_BIN_PATH, filename))
        end
        chmod(julia_bin_filename, 0o755)
    end
end


function bash_shim(pkgname, julia_executable_path::String, env)
    return """
        #!/usr/bin/env bash

        export JULIA_LOAD_PATH=$(repr(env))
        exec $julia_executable_path \\
            --startup-file=no \\
            -m $(pkgname) \\
            "\$@"
        """
end

function windows_shim(pkgname, julia_executable_path::String, env)
    return """
        @echo off
        set JULIA_LOAD_PATH=$(repr(env))

        $julia_executable_path ^
            --startup-file=no ^
            -m $(pkgname) ^
            %*
        """
end


#################
# PATH handling #
#################

function add_bindir_to_path()
    if Sys.iswindows()
        update_windows_PATH()
    else
        update_unix_PATH()
    end
end

function get_shell_config_file(julia_bin_path)
    home_dir = ENV["HOME"]
    # Check for various shell configuration files
    if occursin("/zsh", ENV["SHELL"])
        return (joinpath(home_dir, ".zshrc"), "path=('$julia_bin_path' \$path)\nexport PATH")
    elseif occursin("/bash", ENV["SHELL"])
        return (joinpath(home_dir, ".bashrc"), "export PATH=\"\$PATH:$julia_bin_path\"")
    elseif occursin("/fish", ENV["SHELL"])
        return (joinpath(home_dir, ".config/fish/config.fish"), "set -gx PATH \$PATH $julia_bin_path")
    elseif occursin("/ksh", ENV["SHELL"])
        return (joinpath(home_dir, ".kshrc"), "export PATH=\"\$PATH:$julia_bin_path\"")
    elseif occursin("/tcsh", ENV["SHELL"]) || occursin("/csh", ENV["SHELL"])
        return (joinpath(home_dir, ".tcshrc"), "setenv PATH \$PATH:$julia_bin_path") # or .cshrc
    else
        return (nothing, nothing)
    end
end

function update_unix_PATH()
    shell_config_file, path_command = get_shell_config_file(JULIA_BIN_PATH)
    if shell_config_file === nothing
        @warn "Failed to insert `.julia/bin` to PATH: Failed to detect shell"
        return
    end

    if !isfile(shell_config_file)
        @warn "Failed to insert `.julia/bin` to PATH: $(repr(shell_config_file)) does not exist."
        return
    end
    file_contents = read(shell_config_file, String)

    # Check for the comment fence
    start_fence = "# >>> julia apps initialize >>>"
    end_fence = "# <<< julia apps initialize <<<"
    fence_exists = occursin(start_fence, file_contents) && occursin(end_fence, file_contents)

    if !fence_exists
        open(shell_config_file, "a") do file
            print(file, "\n$start_fence\n\n")
            print(file, "# !! Contents within this block are managed by Julia's package manager Pkg !!\n\n")
            print(file, "$path_command\n\n")
            print(file, "$end_fence\n\n")
        end
    end
end

function update_windows_PATH()
    current_path = ENV["PATH"]
    occursin(JULIA_BIN_PATH, current_path) && return
    new_path = "$current_path;$JULIA_BIN_PATH"
    run(`setx PATH "$new_path"`)
end

end
