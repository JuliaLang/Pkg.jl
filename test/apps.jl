module AppsTests

import ..Pkg # ensure we are using the correct Pkg
using ..Utils

using Test

@testset "Apps" begin

    isolate(loaded_depot = true) do
        sep = Sys.iswindows() ? ';' : ':'
        Pkg.Apps.develop(path = joinpath(@__DIR__, "test_packages", "Rot13.jl"))
        current_path = ENV["PATH"]
        exename = Sys.iswindows() ? "juliarot13.bat" : "juliarot13"
        cliexename = Sys.iswindows() ? "juliarot13cli.bat" : "juliarot13cli"
        flagsexename = Sys.iswindows() ? "juliarot13flags.bat" : "juliarot13flags"
        withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
            # Test original app
            @test contains(Sys.which("$exename"), first(DEPOT_PATH))
            @test read(`$exename test`, String) == "grfg\n"

            # Test submodule app
            @test contains(Sys.which("$cliexename"), first(DEPOT_PATH))
            @test read(`$cliexename test`, String) == "CLI: grfg\n"

            # Test flags app with default julia_flags
            @test contains(Sys.which("$flagsexename"), first(DEPOT_PATH))
            flags_output = read(`$flagsexename arg1 arg2`, String)
            @test contains(flags_output, "Julia flags demo!")
            @test contains(flags_output, "Thread count: 2")  # from --threads=2
            @test contains(flags_output, "Optimization level: 3")  # from --optimize=3
            @test contains(flags_output, "App arguments: arg1 arg2")

            # Test flags app with runtime julia flags (should override defaults)
            runtime_output = read(`$flagsexename --threads=4 -- runtime_arg`, String)
            @test contains(runtime_output, "Thread count: 4")  # overridden by runtime
            @test contains(runtime_output, "App arguments: runtime_arg")

            # Test JULIA_APPS_JULIA_CMD environment variable override
            mktempdir() do tmpdir
                # Create a mock Julia executable that outputs an identifiable string
                mock_julia_path = joinpath(tmpdir, Sys.iswindows() ? "mock-julia.bat" : "mock-julia")
                mock_script = if Sys.iswindows()
                    "@echo off\necho MOCK_JULIA_EXECUTED\n"
                else
                    "#!/bin/sh\necho MOCK_JULIA_EXECUTED\n"
                end
                write(mock_julia_path, mock_script)
                if !Sys.iswindows()
                    chmod(mock_julia_path, 0o755)
                end

                # Test that JULIA_APPS_JULIA_CMD overrides the Julia executable
                withenv("JULIA_APPS_JULIA_CMD" => mock_julia_path) do
                    mock_output = read(`$exename test`, String)
                    @test contains(mock_output, "MOCK_JULIA_EXECUTED")
                end
            end

            Pkg.Apps.rm("Rot13")
            @test Sys.which(exename) == nothing
            @test Sys.which(cliexename) == nothing
            @test Sys.which(flagsexename) == nothing
        end
    end

    isolate(loaded_depot = true) do
        mktempdir() do tmpdir
            sep = Sys.iswindows() ? ';' : ':'
            path = git_init_package(tmpdir, joinpath(@__DIR__, "test_packages", "Rot13.jl"))
            Pkg.Apps.add(path = path)
            exename = Sys.iswindows() ? "juliarot13.bat" : "juliarot13"
            cliexename = Sys.iswindows() ? "juliarot13cli.bat" : "juliarot13cli"
            flagsexename = Sys.iswindows() ? "juliarot13flags.bat" : "juliarot13flags"
            current_path = ENV["PATH"]
            withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
                # Test original app
                @test contains(Sys.which(exename), first(DEPOT_PATH))
                @test read(`$exename test`, String) == "grfg\n"

                # Test submodule app
                @test contains(Sys.which(cliexename), first(DEPOT_PATH))
                @test read(`$cliexename test`, String) == "CLI: grfg\n"

                # Test flags app functionality
                @test contains(Sys.which(flagsexename), first(DEPOT_PATH))
                flags_output = read(`$flagsexename hello`, String)
                @test contains(flags_output, "Julia flags demo!")
                @test contains(flags_output, "App arguments: hello")

                Pkg.Apps.rm("Rot13")
                @test Sys.which(exename) == nothing
                @test Sys.which(cliexename) == nothing
                @test Sys.which(flagsexename) == nothing
            end

            # https://github.com/JuliaLang/Pkg.jl/issues/4258
            Pkg.Apps.add(path = path)
            Pkg.Apps.develop(path = path)

            # Verify that dev does not create an app environment directory
            app_env_dir = joinpath(first(DEPOT_PATH), "environments", "apps", "Rot13")
            @test !isdir(app_env_dir)

            # Verify that changes to the dev'd package are immediately reflected
            mv(joinpath(path, "src", "Rot13_edited.jl"), joinpath(path, "src", "Rot13.jl"); force = true)
            withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
                @test read(`$exename test`, String) == "Updated!\n"
            end
        end
    end

end

end # module
