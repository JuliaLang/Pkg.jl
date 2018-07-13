function tempdir_util(fn::Function)
    tempdir = mktempdir()
    try
        fn(tempdir)
    finally
        try
            rm(tempdir; recursive=true, force=true)
        catch ex
            if ex is UVError && ex.prefix == "unlink"
                println("** code: [$(ex.code)]")
                println("** unlink error: [$ex]")
            elseif ex isa SystemError && ex.prefix == "rmdir"
                println("** code: [$(ex.code)]")
                println("** rmdir error: [$ex]")
            else
                throw(ex)
            end
        end
    end
end

function temp_pkg_dir(fn::Function)
    local env_dir
    local old_load_path
    local old_depot_path
    local old_home_project
    local old_active_project
    try
        old_load_path = copy(LOAD_PATH)
        old_depot_path = copy(DEPOT_PATH)
        old_home_project = Base.HOME_PROJECT[]
        old_active_project = Base.ACTIVE_PROJECT[]
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        Base.HOME_PROJECT[] = nothing
        Base.ACTIVE_PROJECT[] = nothing
        tempdir_util() do env_dir
            tempdir_util() do depot_dir
                push!(LOAD_PATH, "@", "@v#.#", "@stdlib")
                push!(DEPOT_PATH, depot_dir)
                fn(env_dir)
            end
        end
    finally
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        append!(LOAD_PATH, old_load_path)
        append!(DEPOT_PATH, old_depot_path)
        Base.HOME_PROJECT[] = old_home_project
        Base.ACTIVE_PROJECT[] = old_active_project
    end
end

function cd_tempdir(f)
    mktempdir() do tmp
        cd(tmp) do
            f(tmp)
        end
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

function with_temp_env(f, env_name::AbstractString="Dummy")
    env_path = joinpath(mktempdir(), env_name)
    Pkg.generate(env_path)
    Pkg.activate(env_path)
    try
        applicable(f, env_path) ? f(env_path) : f()
    finally
        Pkg.activate()
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
