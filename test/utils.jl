# This file is a part of Julia. License is MIT: https://julialang.org/license

module Utils

import ..Pkg

export temp_pkg_dir, cd_tempdir, isinstalled, write_build, with_current_env,
       with_temp_env, with_pkg_env, git_init_and_commit, copy_test_package,
       git_init_package, add_this_pkg, TEST_SIG, TEST_PKG, isolate, LOADED_DEPOT

const LOADED_DEPOT = joinpath(@__DIR__, "loaded_depot")

const REGISTRY_DIR = joinpath(@__DIR__, "registries", "General")


function isolate(fn::Function; loaded_depot=false)
    old_load_path = copy(LOAD_PATH)
    old_depot_path = copy(DEPOT_PATH)
    old_home_project = Base.HOME_PROJECT[]
    old_active_project = Base.ACTIVE_PROJECT[]
    old_working_directory = pwd()
    old_general_registry_url = Pkg.Types.DEFAULT_REGISTRIES[1].url
    try
        # Clone the registry only once
        if !isdir(REGISTRY_DIR)
            mkpath(REGISTRY_DIR)
            Base.shred!(LibGit2.CachedCredentials()) do creds
                LibGit2.with(Pkg.GitTools.clone(Pkg.Types.Context(),
                                                "https://github.com/JuliaRegistries/General.git",
                    REGISTRY_DIR, credentials = creds)) do repo
                end
            end
        end

        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        Base.HOME_PROJECT[] = nothing
        Base.ACTIVE_PROJECT[] = nothing
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = false
        Pkg.Types.DEFAULT_REGISTRIES[1].url = REGISTRY_DIR
        Pkg.REPLMode.TEST_MODE[] = false
        withenv("JULIA_PROJECT" => nothing,
                "JULIA_LOAD_PATH" => nothing,
                "JULIA_PKG_DEVDIR" => nothing) do
            target_depot = nothing
            try
                target_depot = mktempdir()
                push!(LOAD_PATH, "@", "@v#.#", "@stdlib")
                push!(DEPOT_PATH, target_depot)
                loaded_depot && push!(DEPOT_PATH, LOADED_DEPOT)
                fn()
            finally
                if target_depot !== nothing && isdir(target_depot)
                    try
                        Base.rm(target_depot; force=true, recursive=true)
                    catch err
                        @show err
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
        Pkg.Types.DEFAULT_REGISTRIES[1].url = old_general_registry_url
    end
end

function temp_pkg_dir(fn::Function;rm=true)
    old_load_path = copy(LOAD_PATH)
    old_depot_path = copy(DEPOT_PATH)
    old_home_project = Base.HOME_PROJECT[]
    old_active_project = Base.ACTIVE_PROJECT[]
    old_general_registry_url = Pkg.Types.DEFAULT_REGISTRIES[1].url
    try
        # Clone the registry only once
        generaldir = joinpath(@__DIR__, "registries", "General")
        if !isdir(generaldir)
            mkpath(generaldir)
            LibGit2.with(Pkg.GitTools.clone(Pkg.Types.Context(),
                                            "https://github.com/JuliaRegistries/General.git",
                generaldir)) do repo
            end
        end
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        Base.HOME_PROJECT[] = nothing
        Base.ACTIVE_PROJECT[] = nothing
        Pkg.Types.DEFAULT_REGISTRIES[1].url = generaldir
        withenv("JULIA_PROJECT" => nothing,
                "JULIA_LOAD_PATH" => nothing,
                "JULIA_PKG_DEVDIR" => nothing) do
            env_dir = mktempdir()
            depot_dir = mktempdir()
            try
                push!(LOAD_PATH, "@", "@v#.#", "@stdlib")
                push!(DEPOT_PATH, depot_dir)
                fn(env_dir)
            finally
                try
                    rm && Base.rm(env_dir; force=true, recursive=true)
                    rm && Base.rm(depot_dir; force=true, recursive=true)
                catch err
                    # Avoid raising an exception here as it will mask the original exception
                    println(Base.stderr, "Exception in finally: $(sprint(showerror, err))")
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
        Pkg.Types.DEFAULT_REGISTRIES[1].url = old_general_registry_url
    end
end

function cd_tempdir(f; rm=true)
    tmp = mktempdir()
    cd(tmp) do
        f(tmp)
    end
    try
        rm && Base.rm(tmp; force = true, recursive = true)
    catch err
        # Avoid raising an exception here as it will mask the original exception
        println(Base.stderr, "Exception in finally: $(sprint(showerror, err))")
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
    env_path = joinpath(mktempdir(), env_name)
    Pkg.generate(env_path)
    Pkg.activate(env_path)
    try
        applicable(f, env_path) ? f(env_path) : f()
    finally
        Base.ACTIVE_PROJECT[] = prev_active
        try
            rm && Base.rm(env_path; force = true, recursive = true)
        catch err
            # Avoid raising an exception here as it will mask the original exception
            println(Base.stderr, "Exception in finally: $(sprint(showerror, err))")
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

function copy_test_package(tmpdir::String, name::String; use_pkg=true)
    target = joinpath(tmpdir, name)
    cp(joinpath(@__DIR__, "test_packages", name), target)
    use_pkg || return target

    # The known Pkg UUID, and whatever UUID we're currently using for testing
    known_pkg_uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
    pkg_uuid = Pkg.TOML.parsefile(joinpath(dirname(@__DIR__), "Project.toml"))["uuid"]

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

function add_this_pkg()
    pkg_dir = dirname(@__DIR__)
    pkg_uuid = Pkg.TOML.parsefile(joinpath(pkg_dir, "Project.toml"))["uuid"]
    spec = Pkg.PackageSpec(
        name="Pkg",
        uuid=UUID(pkg_uuid),
        path=pkg_dir,
    )
    Pkg.develop(spec)
end

end
