# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTestsOuter

original_depot_path = copy(Base.DEPOT_PATH)
original_load_path = copy(Base.LOAD_PATH)
original_env = copy(ENV)
original_project = Base.active_project()

module PkgTestsInner

    original_wd = pwd()

    import Pkg
    import REPL # should precompile REPLExt before we disallow it below
    @assert Base.get_extension(Pkg, :REPLExt) !== nothing
    using Test, Logging
    using Base.ScopedValues

    if realpath(dirname(dirname(Base.pathof(Pkg)))) != realpath(dirname(@__DIR__))
        @show dirname(dirname(Base.pathof(Pkg))) realpath(dirname(@__DIR__))
        error("The wrong Pkg is being tested")
    end

    const original_depot_had_registries = isdir(joinpath(Base.DEPOT_PATH[1], "registries"))

    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0
    ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"] = 1

    logdir = get(ENV, "JULIA_TEST_VERBOSE_LOGS_DIR", nothing)
    ### Send all Pkg output to a file called Pkg.log
    islogging = logdir !== nothing

    if islogging
        logfile = joinpath(logdir, "Pkg.log")
        default_io = open(logfile, "a")
        @info "Pkg test output is being logged to file" logfile
    else
        default_io = devnull # or stdout
    end

    include("utils.jl")
    @with Pkg.DEFAULT_IO => default_io begin
        Logging.with_logger((islogging || default_io == devnull) ? Logging.ConsoleLogger(default_io) : Logging.current_logger()) do
            if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
                s = read(`curl -sLI $(server)`, String)
                @info "Pkg Server metadata:\n$s"
            end

            Utils.check_init_reg()

            test_files = [
                "new.jl",
                "pkg.jl",
                "repl.jl",
                "api.jl",
                "registry.jl",
                "subdir.jl",
                "extensions.jl",
                "binaryplatforms.jl",
                "platformengines.jl",
                "resolve.jl",
                "misc.jl",
                "force_latest_compatible_version.jl",
                "manifests.jl",
                "project_manifest.jl",
                "sources.jl",
                "workspaces.jl",
                "apps.jl",
                "stdlib_compat.jl",
            ]

            # Only test these if the test deps are available (they aren't typically via `Base.runtests`)
            HSV_pkgid = Base.PkgId(Base.UUID("6df8b67a-e8a0-4029-b4b7-ac196fe72102"), "HistoricalStdlibVersions")
            if Base.locate_package(HSV_pkgid) !== nothing
                push!(test_files, "historical_stdlib_version.jl")
            end
            Aqua_pkgid = Base.PkgId(Base.UUID("4c88cf16-eb10-579e-8560-4a9242c79595"), "Aqua")
            if Base.locate_package(Aqua_pkgid) !== nothing
                push!(test_files, "aqua.jl")
            end
            Preferences_pkgid = Base.PkgId(Base.UUID("21216c6a-2e73-6563-6e65-726566657250"), "Preferences")
            if Base.locate_package(Preferences_pkgid) !== nothing
                push!(test_files, "sandbox.jl")
                push!(test_files, "artifacts.jl")
            end

            verbose = true
            @testset "Pkg" verbose = verbose begin
                Pkg.activate(; temp = true) # make sure we're in an active project and that it's clean
                try
                    @testset "$f" verbose = verbose for f in test_files
                        @info "==== Testing `test/$f`"
                        flush(default_io)
                        include(f)
                    end
                finally
                    islogging && close(default_io)
                    cd(original_wd)
                end
            end
        end

        # Make sure that none of our tests have left temporary registries lying around
        @test isdir(joinpath(Base.DEPOT_PATH[1], "registries")) == original_depot_had_registries
    end

    if haskey(ENV, "CI")
        # if CI don't clean up as it will be slower than the runner filesystem reset
        empty!(Base.Filesystem.TEMP_CLEANUP)
    else
        @showtime Base.Filesystem.temp_cleanup_purge(force = true)
    end

end # module

empty!(Base.DEPOT_PATH)
empty!(Base.LOAD_PATH)
append!(Base.DEPOT_PATH, original_depot_path)
append!(Base.LOAD_PATH, original_load_path)

for k in setdiff(collect(keys(ENV)), collect(keys(original_env)))
    delete!(ENV, k)
end
for (k, v) in pairs(original_env)
    ENV[k] = v
end

Base.set_active_project(original_project)

end # module
