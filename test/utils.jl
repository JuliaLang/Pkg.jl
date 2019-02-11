# This file is a part of Julia. License is MIT: https://julialang.org/license
import Pkg

function temp_pkg_dir(fn::Function;rm=true)
    local env_dir
    local old_load_path
    local old_depot_path
    local old_home_project
    local old_active_project
    local old_general_registry_url
    try
        # Clone the registry only once
        old_general_registry_url = Pkg.Types.DEFAULT_REGISTRIES[1].url
        generaldir = joinpath(@__DIR__, "registries", "General")
        if !isdir(generaldir)
            mkpath(generaldir)
            Base.shred!(LibGit2.CachedCredentials()) do creds
                LibGit2.with(Pkg.GitTools.clone(Pkg.Types.Context(),
                                                "https://github.com/JuliaRegistries/General.git",
                    generaldir, credentials = creds)) do repo
                end
            end
        end

        old_load_path = copy(LOAD_PATH)
        old_depot_path = copy(DEPOT_PATH)
        old_home_project = Base.HOME_PROJECT[]
        old_active_project = Base.ACTIVE_PROJECT[]
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

function write_build(path, content)
    build_filename = joinpath(path, "deps", "build.jl")
    mkpath(dirname(build_filename))
    write(build_filename, content)
end

function with_current_env(f)
    Pkg.activate(".")
    try
        f()
    finally
        Pkg.activate()
    end
end

function with_temp_env(f, env_name::AbstractString="Dummy"; rm=true)
    env_path = joinpath(mktempdir(), env_name)
    Pkg.generate(env_path)
    Pkg.activate(env_path)
    try
        applicable(f, env_path) ? f(env_path) : f()
    finally
        Pkg.activate()
        try
            rm && Base.rm(env_path; force = true, recursive = true)
        catch err
            # Avoid raising an exception here as it will mask the original exception
            println(Base.stderr, "Exception in finally: $(sprint(showerror, err))")
        end
    end
end

function with_pkg_env(fn::Function, path::AbstractString="."; change_dir=false)
    Pkg.activate(path)
    try
        if change_dir
            cd(fn, path)
        else
            fn()
        end
    finally
        Pkg.activate()
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

function copy_test_package(tmpdir::String, name::String)
    cp(joinpath(@__DIR__, "test_packages", name), joinpath(tmpdir, name))

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
end
function add_test_package(name::String, uuid::UUID)
    test_pkg_dir = joinpath(@__DIR__, "test_packages", name)
    spec = Pkg.Types.PackageSpec(
        name=name,
        uuid=uuid,
        path=test_pkg_dir,
    )
    Pkg.add(spec)
end

function add_this_pkg()
    pkg_dir = dirname(@__DIR__)
    pkg_uuid = Pkg.TOML.parsefile(joinpath(pkg_dir, "Project.toml"))["uuid"]
    spec = Pkg.Types.PackageSpec(
        name="Pkg",
        uuid=UUID(pkg_uuid),
        path=pkg_dir,
    )
    Pkg.develop(spec)
end
