first_run = true
mutable struct RemoveRegistry
    path::String
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
        mktempdir() do env_dir
            mktempdir() do depot_dir
                # In order not to clone the registry over and over we clone it once and then copy thatt_dir
                # to the correct place in successive uses of this function
                if first_run
                    tmp_reg = mktempdir()
                    # Clone the default registry
                    push!(DEPOT_PATH, tmp_reg)
                    Pkg.Types.registries()
                    # Remove the cloned registry when we are done
                    global __reg = RemoveRegistry(tmp_reg)
                    finalizer(__reg) do x
                        Base.rm(joinpath(x.path, "registries"); recursive=true)
                    end
                    empty!(DEPOT_PATH)
                    global first_run = false
                else
                    cp(joinpath(__reg.path, "registries"), joinpath(depot_dir, "registries"))
                end
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
