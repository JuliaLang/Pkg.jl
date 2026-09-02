module PkgTestTests

using Test, UUIDs
import ..Pkg
using Pkg.Types: PkgError
using ..Utils

exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")
unregistered_uuid = UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")

inside_test_sandbox(fn, name; kwargs...) = Pkg.test(name; test_fn = fn, kwargs...)

inside_test_sandbox(fn; kwargs...) = Pkg.test(; test_fn = fn, kwargs...)

@testset "test: printing" begin
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example")
        io = Base.BufferStream()
        Pkg.test("Example"; io = io)
        closewrite(io)
        output = read(io, String)
        @test occursin(r"Testing Example", output)
        @test occursin(r"Status `.+Project\.toml`", output)
        @test occursin(r"Status `.+Manifest\.toml`", output)
        @test occursin(r"Testing Running tests...", output)
        @test occursin(r"Testing Example tests passed", output)
    end
end

@testset "test: sandboxing" begin
    # explicit test dependencies and the tested project are available within the test sandbox
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            foo_uuid = UUID("02250abe-2050-11e9-017e-b301a2b5bcc4")
            path = copy_test_package(tempdir, "BasicSandbox")
            # we set readonly here to simulate the permissions in the `$DEPOT/packages` directory
            Pkg.Types.set_readonly(path)
            Pkg.develop(path = path)
            inside_test_sandbox("BasicSandbox") do
                Pkg.dependencies(foo_uuid) do pkg
                    @test length(pkg.dependencies) == 1
                    @test haskey(pkg.dependencies, "Random")
                end
                @test haskey(Pkg.project().dependencies, "Test")
                @test haskey(Pkg.project().dependencies, "BasicSandbox")
            end
        end
    end
    # the active dependency graph is transferred to the test sandbox
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "TransferSubgraph")
            Pkg.activate(path)
            active_json_version = Pkg.dependencies()[json_uuid].version
            inside_test_sandbox("Unregistered") do
                @test Pkg.dependencies()[json_uuid].version == active_json_version
            end
        end
    end
    # the active dep graph is transferred to test sandbox, even when tracking unregistered repos
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "TestSubgraphTrackingRepo")
            Pkg.activate(path)
            inside_test_sandbox() do
                Pkg.dependencies(unregistered_uuid) do pkg
                    @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
                    @test !pkg.is_tracking_registry
                end
            end
        end
    end
    # a test dependency can track a path
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "TestDepTrackingPath")
            Pkg.activate(path)
            inside_test_sandbox() do
                @test Pkg.dependencies()[unregistered_uuid].is_tracking_path
            end
        end
    end
    # a test dependency can track a repo
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "TestDepTrackingRepo")
            Pkg.activate(path)
            inside_test_sandbox() do
                Pkg.dependencies(unregistered_uuid) do pkg
                    @test !pkg.is_tracking_registry
                    @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
                end
            end
        end
    end
    # `compat` for test dependencies is honored
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "TestDepCompat")
            Pkg.activate(path)
            inside_test_sandbox() do
                deps = Pkg.dependencies()
                @test deps[exuuid].version == v"0.3.0"
                @test deps[UUID("9cb9b0df-a8d1-4a6c-a371-7d2ae60a2f25")].version == v"0.1.0"
            end
        end
    end
end

# These tests cover the original "targets" API for specifying test dependencies
@testset "test: 'targets' based testing" begin
    # `Pkg.test` should work on dependency graphs with nodes sharing the same name but not the same UUID
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            Pkg.activate(joinpath(@__DIR__, "test_packages", "SameNameDifferentUUID"))
            inside_test_sandbox("Example") do
                Pkg.dependencies(UUID("6876af07-990d-54b4-ab0e-23690620f79a")) do pkg
                    @test pkg.name == "Example"
                    @test realpath(pkg.source) == realpath(joinpath(@__DIR__, "test_packages", "SameNameDifferentUUID", "dev", "Example"))
                end
            end
        end
    end
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            basic_test_target = UUID("50adb811-5a1f-4be4-8146-2725c7f5d900")
            path = copy_test_package(tempdir, "BasicTestTarget")
            # we set readonly here to simulate the permissions in the `$DEPOT/packages` directory
            Pkg.Types.set_readonly(path)
            Pkg.develop(path = path)
            inside_test_sandbox("BasicTestTarget") do
                @test haskey(Pkg.project().dependencies, "Markdown")
                @test haskey(Pkg.project().dependencies, "Test")
                @test haskey(Pkg.project().dependencies, "BasicTestTarget")
                Pkg.dependencies(basic_test_target) do pkg
                    @test pkg.is_tracking_path == true
                    @test haskey(pkg.dependencies, "UUIDs")
                    @test !haskey(pkg.dependencies, "Markdown")
                    @test !haskey(pkg.dependencies, "Test")
                end
            end
        end
    end
    # dependency of test dependency (#567)
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            for x in ["x1", "x2", "x3"]
                path = copy_test_package(tempdir, x)
                Pkg.develop(Pkg.PackageSpec(path = path))
            end
            Pkg.test("x3")
        end
    end
    # preserve root of active project if it is a dependency (#1423)
    isolate(loaded_depot = false) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "ActiveProjectInTestSubgraph")
            Pkg.activate(path)
            inside_test_sandbox("B") do
                deps = Pkg.dependencies()
                @test deps[UUID("c86f0f68-174e-41db-bd5e-b032223de205")].version == v"1.2.3"
            end
        end
    end
    # test targets should also honor compat
    isolate(loaded_depot = false) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "TestTargetCompat")
            Pkg.activate(path)
            inside_test_sandbox() do
                deps = Pkg.dependencies()
                @test deps[exuuid].version == v"0.3.0"
            end
        end
    end
end

@testset "test: fallback when no project file exists" begin
    isolate(loaded_depot = true) do
        Pkg.add(name = "Permutations", version = "0.3.2")
        if Sys.WORD_SIZE == 32
            # The Permutations.jl v0.3.2 tests are known to fail on 32-bit Julia
            @test_skip Pkg.test("Permutations")
        else
            Pkg.test("Permutations")
        end
    end
end

@testset "using a test/REQUIRE file" begin
    isolate() do
        Pkg.add(name = "EnglishText", version = "0.6.0")
        Pkg.test("EnglishText")
    end
end

@testset "test" begin
    # stdlib special casing
    isolate(loaded_depot = true) do
        Pkg.add("UUIDs")
        Pkg.test("UUIDs")
    end
    # test args smoketest
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "TestArguments")
            Pkg.activate(joinpath(tempdir, "TestArguments"))
            # test the old code path (no test/Project.toml)
            Pkg.test("TestArguments"; test_args = `a b`, julia_args = `--quiet --check-bounds=no`)
            Pkg.test("TestArguments"; test_args = ["a", "b"], julia_args = ["--quiet", "--check-bounds=no"])
            # test new code path
            touch(joinpath(tempdir, "TestArguments", "test", "Project.toml"))
            Pkg.test("TestArguments"; test_args = `a b`, julia_args = `--quiet --check-bounds=no`)
            Pkg.test("TestArguments"; test_args = ["a", "b"], julia_args = ["--quiet", "--check-bounds=no"])
        end
    end

    @testset "threads" begin
        isolate(loaded_depot = true) do;
            mktempdir() do dir
                path = copy_test_package(dir, "TestThreads")
                cd(path) do
                    # Do this all in a subprocess to protect against the parent having non-default threadpool sizes.
                    script = """
                        using Pkg, Test
                        @testset "JULIA_NUM_THREADS=1" begin
                            withenv(
                                "EXPECTED_NUM_THREADS_DEFAULT" => "1",
                                "EXPECTED_NUM_THREADS_INTERACTIVE" => "0", # https://github.com/JuliaLang/julia/pull/57454
                                "JULIA_NUM_THREADS" => "1",
                            ) do
                                Pkg.test("TestThreads")
                            end
                        end
                        @testset "JULIA_NUM_THREADS=2" begin
                            withenv(
                                "EXPECTED_NUM_THREADS_DEFAULT" => "2",
                                "EXPECTED_NUM_THREADS_INTERACTIVE" => "1",
                                "JULIA_NUM_THREADS" => "2",
                            ) do
                                Pkg.test("TestThreads")
                            end
                        end
                        @testset "JULIA_NUM_THREADS=2,0" begin
                            withenv(
                                "EXPECTED_NUM_THREADS_DEFAULT" => "2",
                                "EXPECTED_NUM_THREADS_INTERACTIVE" => "0",
                                "JULIA_NUM_THREADS" => "2,0",
                            ) do
                                Pkg.test("TestThreads")
                            end
                        end

                        @testset "--threads=1" begin
                            withenv(
                                "EXPECTED_NUM_THREADS_DEFAULT" => "1",
                                "EXPECTED_NUM_THREADS_INTERACTIVE" => "0", # https://github.com/JuliaLang/julia/pull/57454
                                "JULIA_NUM_THREADS" => nothing,
                            ) do
                                Pkg.test("TestThreads"; julia_args=`--threads=1`)
                            end
                        end
                        @testset "--threads=2" begin
                            withenv(
                                "EXPECTED_NUM_THREADS_DEFAULT" => "2",
                                "EXPECTED_NUM_THREADS_INTERACTIVE" => "1",
                                "JULIA_NUM_THREADS" => nothing,
                            ) do
                                Pkg.test("TestThreads"; julia_args=`--threads=2`)
                            end
                        end
                        @testset "--threads=2,0" begin
                            withenv(
                                "EXPECTED_NUM_THREADS_DEFAULT" => "2",
                                "EXPECTED_NUM_THREADS_INTERACTIVE" => "0",
                                "JULIA_NUM_THREADS" => nothing,
                            ) do
                                Pkg.test("TestThreads"; julia_args=`--threads=2,0`)
                            end
                        end
                    """
                    @test Utils.show_output_if_command_errors(
                        addenv(
                            `$(Base.julia_cmd()) --project=$(path) --startup-file=no -e "$script"`,
                            "JULIA_DEPOT_PATH" => join(Base.DEPOT_PATH, Sys.iswindows() ? ";" : ":")
                        )
                    )
                end
            end
        end
    end
end

@testset "build" begin
    # Test package that fails build
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            package_path = copy_test_package(tempdir, "FailBuild")
            Pkg.activate(package_path)
            @test_throws PkgError Pkg.build()
        end
    end

    # Build log location
    isolate(loaded_depot = true) do;
        mktempdir() do tmp
            path = git_init_package(tmp, joinpath(@__DIR__, "test_packages", "FailBuild"))
            # Log file in the directory when it is deved
            Pkg.develop(path = path; io = devnull)
            log_file_dev = joinpath(path, "deps", "build.log")
            @test !isfile(log_file_dev)
            @test_throws PkgError Pkg.build("FailBuild"; io = devnull)
            @test isfile(log_file_dev)
            @test occursin("oops", read(log_file_dev, String))
            # Log file in scratchspace when added
            addpath = dirname(dirname(Base.find_package("FailBuild")))
            log_file_add = joinpath(path, "deps", "build.log")
            @test_throws PkgError Pkg.add(path = path; io = devnull)
            @test !isfile(joinpath(Base.find_package("FailBuild"), "..", "..", "deps", "build.log"))
            log_file_add = joinpath(
                DEPOT_PATH[1], "scratchspaces",
                "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "f99d57aad0e5eb2434491b47bac92bb88d463001", "build.log"
            )
            @test isfile(log_file_add)
            @test isfile(joinpath(DEPOT_PATH[1], "scratchspaces", "CACHEDIR.TAG"))
            @test occursin("oops", read(log_file_add, String))
        end
    end
end

end # module
