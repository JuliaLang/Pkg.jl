# This file is a part of Julia. License is MIT: https://julialang.org/license

module Utils

import ..Pkg
import Pkg: stdout_f, stderr_f
using Tar
using TOML
using UUIDs

export temp_pkg_dir, cd_tempdir, isinstalled, write_build, with_current_env,
       with_temp_env, with_pkg_env, git_init_and_commit, copy_test_package,
       git_init_package, add_this_pkg, TEST_SIG, TEST_PKG, isolate, LOADED_DEPOT,
       list_tarball_files, recursive_rm_cov_files

const CACHE_DIRECTORY = realpath(mktempdir(; cleanup = true))

const LOADED_DEPOT = joinpath(CACHE_DIRECTORY, "loaded_depot")

const REGISTRY_DEPOT = joinpath(CACHE_DIRECTORY, "registry_depot")
const REGISTRY_DIR = joinpath(REGISTRY_DEPOT, "registries", "General")

const GENERAL_UUID = UUID("23338594-aafe-5451-b93e-139f81909106")

function check_init_reg()
    isfile(joinpath(REGISTRY_DIR, "Registry.toml")) && return
    mkpath(REGISTRY_DIR)
    if Pkg.Registry.registry_use_pkg_server()
        url = Pkg.Registry.pkg_server_registry_urls()[GENERAL_UUID]
        @info "Downloading General registry from $url"
        Pkg.PlatformEngines.download_verify_unpack(url, nothing, REGISTRY_DIR, ignore_existence = true, io = stderr_f())
        tree_info_file = joinpath(REGISTRY_DIR, ".tree_info.toml")
        hash = Pkg.Registry.pkg_server_url_hash(url)
        write(tree_info_file, "git-tree-sha1 = " * repr(string(hash)))
    else
        Base.shred!(LibGit2.CachedCredentials()) do creds
            f = retry(delays = fill(5.0, 3), check=(s,e)->isa(e, Pkg.Types.PkgError)) do
                LibGit2.with(Pkg.GitTools.clone(
                    stderr_f(),
                    "https://github.com/JuliaRegistries/General.git",
                    REGISTRY_DIR,
                    credentials = creds)) do repo
                end
            end
            f() # retry returns a function that should be called
        end
    end
    isfile(joinpath(REGISTRY_DIR, "Registry.toml")) || error("Registry did not install properly")
end

function isolate(fn::Function; loaded_depot=false, linked_reg=true)
    old_load_path = copy(LOAD_PATH)
    old_depot_path = copy(DEPOT_PATH)
    old_home_project = Base.HOME_PROJECT[]
    old_active_project = Base.ACTIVE_PROJECT[]
    old_working_directory = pwd()
    old_general_registry_url = Pkg.Registry.DEFAULT_REGISTRIES[1].url
    old_general_registry_path = Pkg.Registry.DEFAULT_REGISTRIES[1].path
    old_general_registry_linked = Pkg.Registry.DEFAULT_REGISTRIES[1].linked
    try
        # Clone/download the registry only once
        check_init_reg()

        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        Base.HOME_PROJECT[] = nothing
        Base.ACTIVE_PROJECT[] = nothing
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = false
        Pkg.Registry.DEFAULT_REGISTRIES[1].url = nothing
        Pkg.Registry.DEFAULT_REGISTRIES[1].path = REGISTRY_DIR
        Pkg.Registry.DEFAULT_REGISTRIES[1].linked = linked_reg
        Pkg.REPLMode.TEST_MODE[] = false
        withenv("JULIA_PROJECT" => nothing,
                "JULIA_LOAD_PATH" => nothing,
                "JULIA_PKG_DEVDIR" => nothing) do
            target_depot = realpath(mktempdir())
            push!(LOAD_PATH, "@", "@v#.#", "@stdlib")
            push!(DEPOT_PATH, target_depot)
            Base.append_bundled_depot_path!(DEPOT_PATH)
            loaded_depot && push!(DEPOT_PATH, LOADED_DEPOT)
            depot_mtimes = Dict(d => mtime(d) for d in DEPOT_PATH if isdir(d))
            try
                fn()
            finally
                for (d, t) in depot_mtimes
                    d == target_depot && continue # tests allowed to modify target depot
                    isdir(d) || continue
                    if mtime(d) != t
                        error("shared depot $d was modified during isolated test: readdir(depot) = $(readdir(d))")
                    end
                end
                if !haskey(ENV, "CI") && target_depot !== nothing && isdir(target_depot)
                    try
                        Base.rm(target_depot; force=true, recursive=true)
                    catch err
                        println("warning: isolate failed to clean up depot.\n  $err")
                    end
                end
            end
        end
    finally
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        append!(LOAD_PATH, old_load_path)
        append!(DEPOT_PATH, old_depot_path)
        Base.HOME_PROJECT[] = old_home_project
        Base.ACTIVE_PROJECT[] = old_active_project
        cd(old_working_directory)
        Pkg.REPLMode.TEST_MODE[] = false # reset unconditionally
        Pkg.Registry.DEFAULT_REGISTRIES[1].path = old_general_registry_path
        Pkg.Registry.DEFAULT_REGISTRIES[1].url = old_general_registry_url
        Pkg.Registry.DEFAULT_REGISTRIES[1].linked = old_general_registry_linked
    end
end

function isolate_and_pin_registry(fn::Function; registry_url::String, registry_commit::String)
    isolate(loaded_depot = false, linked_reg = true) do
        this_gen_reg_path = joinpath(first(Base.DEPOT_PATH), "registries", "General")
        rm(this_gen_reg_path; force = true) # delete the symlinked registry directory
        cmd = `git clone $(registry_url) $(this_gen_reg_path)`
        run(pipeline(cmd, stdout = stdout_f(), stderr = stderr_f()))
        cd(this_gen_reg_path) do
            run(pipeline(`git checkout $(registry_commit)`, stdout = stdout_f(), stderr = stderr_f()))
        end
        fn()
    end
    return nothing
end

function temp_pkg_dir(fn::Function;rm=true, linked_reg=true)
    old_load_path = copy(LOAD_PATH)
    old_depot_path = copy(DEPOT_PATH)
    old_home_project = Base.HOME_PROJECT[]
    old_active_project = Base.ACTIVE_PROJECT[]
    old_general_registry_url = Pkg.Registry.DEFAULT_REGISTRIES[1].url
    old_general_registry_path = Pkg.Registry.DEFAULT_REGISTRIES[1].path
    old_general_registry_linked = Pkg.Registry.DEFAULT_REGISTRIES[1].linked
    try
        # Clone/download the registry only once
        check_init_reg()

        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        Base.HOME_PROJECT[] = nothing
        Base.ACTIVE_PROJECT[] = nothing
        Pkg.Registry.DEFAULT_REGISTRIES[1].url = nothing
        Pkg.Registry.DEFAULT_REGISTRIES[1].path = REGISTRY_DIR
        Pkg.Registry.DEFAULT_REGISTRIES[1].linked = linked_reg
        withenv("JULIA_PROJECT" => nothing,
                "JULIA_LOAD_PATH" => nothing,
                "JULIA_PKG_DEVDIR" => nothing) do
            env_dir = realpath(mktempdir())
            depot_dir = realpath(mktempdir())
            try
                push!(LOAD_PATH, "@", "@v#.#", "@stdlib")
                push!(DEPOT_PATH, depot_dir)
                Base.append_bundled_depot_path!(DEPOT_PATH)
                fn(env_dir)
            finally
                if rm && !haskey(ENV, "CI")
                    try
                        Base.rm(env_dir; force=true, recursive=true)
                        Base.rm(depot_dir; force=true, recursive=true)
                    catch err
                        # Avoid raising an exception here as it will mask the original exception
                        println(stderr_f(), "Exception in finally: $(sprint(showerror, err))")
                    end
                end
            end
        end
    finally
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        append!(LOAD_PATH, old_load_path)
        append!(DEPOT_PATH, old_depot_path)
        Base.HOME_PROJECT[] = old_home_project
        Base.ACTIVE_PROJECT[] = old_active_project
        Pkg.Registry.DEFAULT_REGISTRIES[1].path = old_general_registry_path
        Pkg.Registry.DEFAULT_REGISTRIES[1].url = old_general_registry_url
        Pkg.Registry.DEFAULT_REGISTRIES[1].linked = old_general_registry_linked
    end
end

function cd_tempdir(f; rm=true)
    tmp = realpath(mktempdir())
    cd(tmp) do
        f(tmp)
    end
    if rm && !haskey(ENV, "CI")
        try
            Base.rm(tmp; force = true, recursive = true)
        catch err
            # Avoid raising an exception here as it will mask the original exception
            println(stderr_f(), "Exception in finally: $(sprint(showerror, err))")
        end
    end
end

isinstalled(pkg) = Base.locate_package(Base.PkgId(pkg.uuid, pkg.name)) !== nothing
# For top level deps
isinstalled(pkg::String) = Base.find_package(pkg) !== nothing

function write_build(path, content)
    build_filename = joinpath(path, "deps", "build.jl")
    mkpath(dirname(build_filename))
    write(build_filename, content)
end

function with_current_env(f)
    prev_active = Base.ACTIVE_PROJECT[]
    Pkg.activate(".")
    try
        f()
    finally
        Base.ACTIVE_PROJECT[] = prev_active
    end
end

function with_temp_env(f, env_name::AbstractString="Dummy"; rm=true)
    prev_active = Base.ACTIVE_PROJECT[]
    env_path = joinpath(realpath(mktempdir()), env_name)
    Pkg.generate(env_path)
    Pkg.activate(env_path)
    try
        applicable(f, env_path) ? f(env_path) : f()
    finally
        Base.ACTIVE_PROJECT[] = prev_active
        if rm && !haskey(ENV, "CI")
            try
                Base.rm(env_path; force = true, recursive = true)
            catch err
                # Avoid raising an exception here as it will mask the original exception
                println(stderr_f(), "Exception in finally: $(sprint(showerror, err))")
            end
        end
    end
end

function with_pkg_env(fn::Function, path::AbstractString="."; change_dir=false)
    prev_active = Base.ACTIVE_PROJECT[]
    Pkg.activate(path)
    try
        if change_dir
            cd(fn, path)
        else
            fn()
        end
    finally
        Base.ACTIVE_PROJECT[] = prev_active
    end
end

import LibGit2
using UUIDs
const TEST_SIG = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time()), 0)
const TEST_PKG = (name = "Example", uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))

function git_init_and_commit(path; msg = "initial commit")
    LibGit2.with(LibGit2.init(path)) do repo
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, msg; author=TEST_SIG, committer=TEST_SIG)
    end
end

function git_init_package(tmp, path)
    base = basename(path)
    pkgpath = joinpath(tmp, base)
    cp(path, pkgpath)
    git_init_and_commit(pkgpath)
    return pkgpath
end

function ensure_test_package_user_writable(dir)
    for (root, _, files) in walkdir(dir)
        chmod(root, filemode(root) | 0o200 | 0o100)

        for file in files
            filepath = joinpath(root, file)
            chmod(filepath, filemode(filepath) | 0o200)
        end
    end
end

function copy_test_package(tmpdir::String, name::String; use_pkg=true)
    target = joinpath(tmpdir, name)
    cp(joinpath(@__DIR__, "test_packages", name), target)
    ensure_test_package_user_writable(target)
    use_pkg || return target

    # The known Pkg UUID, and whatever UUID we're currently using for testing
    known_pkg_uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
    pkg_uuid = TOML.parsefile(joinpath(dirname(@__DIR__), "Project.toml"))["uuid"]

    # We usually want this test package to load our pkg, so update its Pkg UUID:
    test_pkg_dir = joinpath(@__DIR__, "test_packages", name)
    for f in ("Manifest.toml", "Project.toml")
        fpath = joinpath(tmpdir, name, f)
        if isfile(fpath)
            write(fpath, replace(read(fpath, String), known_pkg_uuid => pkg_uuid))
        end
    end
    return target
end

function add_this_pkg(; platform=Base.BinaryPlatforms.HostPlatform())
    try
        Pkg.respect_sysimage_versions(false)
        pkg_dir = dirname(@__DIR__)
        pkg_uuid = TOML.parsefile(joinpath(pkg_dir, "Project.toml"))["uuid"]
        spec = Pkg.PackageSpec(
            name="Pkg",
            uuid=UUID(pkg_uuid),
            path=pkg_dir,
        )
        Pkg.develop(spec; platform)
    finally
        Pkg.respect_sysimage_versions(true)
    end
end

function list_tarball_files(tarball_path::AbstractString)
    names = String[]
    Tar.list(`$(Pkg.PlatformEngines.exe7z()) x $tarball_path -so`) do hdr
        push!(names, hdr.path)
    end
    return names
end

function show_output_if_command_errors(cmd::Cmd)
    out = IOBuffer()
    proc = run(pipeline(cmd; stdout=out); wait = false)
    wait(proc)
    if !success(proc)
        seekstart(out)
        println(read(out, String))
        Base.pipeline_error(proc)
    end
    return nothing
end

function recursive_rm_cov_files(rootdir::String)
    for (root, _, files) in walkdir(rootdir)
        for file in files
            endswith(file, ".cov") && rm(joinpath(root, file))
        end
    end
end

end
