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

    @test isempty(Test.detect_closure_boxes(Pkg))

    const original_depot_had_registries = isdir(joinpath(Base.DEPOT_PATH[1], "registries"))

    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0
    ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"] = 1
    # Disable auto-gc for the whole suite (test workers read this in `Pkg.__init__`)
    ENV["JULIA_PKG_GC_AUTO"] = "false"
    Pkg._auto_gc_enabled[] = false

    logdir = get(ENV, "JULIA_TEST_VERBOSE_LOGS_DIR", nothing)
    ### Send all Pkg output to log files
    islogging = logdir !== nothing

    if islogging
        logfile = joinpath(logdir, "Pkg.log")
        default_io = open(logfile, "a")
        @info "Pkg test output is being logged to file" logfile
    else
        default_io = devnull # or stdout
    end

    # Also publishes the shared cache directory in ENV for the test workers
    include("utils.jl")
    include("pkg_server_proxy.jl")

    test_files = [
        "api.jl",
        "add.jl",
        "update.jl",
        "pkgtest.jl",
        "concurrent.jl",
        "repl.jl",
        "status.jl",
        "develop.jl",
        "repo.jl",
        "project_files.jl",
        "gc.jl",
        "misc.jl",
        "registry.jl",
        "subdir.jl",
        "extensions.jl",
        "binaryplatforms.jl",
        "platformengines.jl",
        "resolve.jl",
        "force_latest_compatible_version.jl",
        "manifests.jl",
        "project_manifest.jl",
        "project_comments.jl",
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

    # Set up the state shared by all test processes, before any test runs:
    # a caching proxy in front of the pkg server (every test process inherits
    # `JULIA_PKG_SERVER`, so each unique resource is downloaded once per cache
    # lifetime), plus the registry and the loaded depot, shared through
    # `Utils.CACHE_DIRECTORY`. This keeps network traffic low and independent
    # of the number of workers.
    function setup_shared_test_state()
        return @with Pkg.DEFAULT_IO => default_io begin
            Logging.with_logger((islogging || default_io == devnull) ? Logging.ConsoleLogger(default_io) : Logging.current_logger()) do
                if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
                    s = read(`curl -sLI $(server)`, String)
                    @info "Pkg Server metadata:\n$s"
                end
                proxy_cache = get(ENV, "PKG_TESTS_PKG_SERVER_CACHE_DIR") do
                    # on CI the cache lives and dies with the run; locally it
                    # persists in the depot so re-runs skip the downloads
                    haskey(ENV, "CI") ? joinpath(Utils.CACHE_DIRECTORY, "pkg_server_cache") :
                        joinpath(first(Base.DEPOT_PATH), "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "pkg_server_cache")
                end
                PkgServerProxy.start!(upstream = Pkg.pkg_server(), cache_dir = proxy_cache)
                Utils.check_init_reg()
                Utils.populate_loaded_depot!()
            end
        end
    end

    # ParallelTestRunner is a test-only dependency, not available when running
    # via `Base.runtests` — fall back to running the test files serially there.
    PTR_pkgid = Base.PkgId(Base.UUID("d3525ed8-44d0-4b2c-a655-542cee43accc"), "ParallelTestRunner")

    if Base.locate_package(PTR_pkgid) !== nothing

        using ParallelTestRunner

        args = ParallelTestRunner.parse_args(ARGS)

        testsuite = Dict{String, Expr}()
        for f in test_files
            path = joinpath(@__DIR__, f)
            testsuite[chopsuffix(f, ".jl")] = quote
                @with Pkg.DEFAULT_IO => Main.PKG_TEST_IO begin
                    Logging.with_logger(Logging.ConsoleLogger(Main.PKG_TEST_IO)) do
                        include($path)
                    end
                end
                Main.PKG_TEST_IO === devnull || flush(Main.PKG_TEST_IO)
            end
        end

        args.list === nothing && setup_shared_test_state()

        # Run once per worker process, in its `Main`
        init_worker_code = quote
            import Pkg
            import REPL # loads REPLExt (from cache; precompiling Pkg is disallowed)
            @assert Base.get_extension(Pkg, :REPLExt) !== nothing
            using Logging
            include($(joinpath(@__DIR__, "utils.jl"))) # defines Main.Utils
            # Per-worker destination for Pkg output during tests
            const PKG_TEST_IO = let logdir = get(ENV, "JULIA_TEST_VERBOSE_LOGS_DIR", nothing)
                logdir === nothing ? devnull : open(joinpath(logdir, "Pkg-worker-$(getpid()).log"), "a")
            end
            # make sure we're in an active project and that it's clean
            Pkg.activate(; temp = true, io = PKG_TEST_IO)
        end

        # Run in each test's sandbox module: test files reference `Pkg` and
        # `Utils` from their parent module (formerly `PkgTestsInner`)
        init_code = quote
            import Pkg, Logging
            using Base.ScopedValues: @with
            import Main: Utils
        end

        try
            runtests(Pkg, args; testsuite, init_code, init_worker_code)
        finally
            islogging && close(default_io)
            cd(original_wd)
        end

    else

        setup_shared_test_state()
        @with Pkg.DEFAULT_IO => default_io begin
            Logging.with_logger((islogging || default_io == devnull) ? Logging.ConsoleLogger(default_io) : Logging.current_logger()) do
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
        end

    end

    # Make sure that none of our tests have left temporary registries lying around
    if isdir(joinpath(Base.DEPOT_PATH[1], "registries")) != original_depot_had_registries
        @warn "Test left temporary registries in depot" Base.DEPOT_PATH[1] original_depot_had_registries
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
