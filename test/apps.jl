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
        nestedexename = Sys.iswindows() ? "juliarot13nested.bat" : "juliarot13nested"
        flagsexename = Sys.iswindows() ? "juliarot13flags.bat" : "juliarot13flags"
        withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
            # Test original app
            @test contains(Sys.which("$exename"), first(DEPOT_PATH))
            @test read(`$exename test`, String) == "grfg\n"

            # Test submodule app
            @test contains(Sys.which("$cliexename"), first(DEPOT_PATH))
            @test read(`$cliexename test`, String) == "CLI: grfg\n"

            # Test nested submodule app
            @test contains(Sys.which("$nestedexename"), first(DEPOT_PATH))
            @test read(`$nestedexename test`, String) == "Nested: grfg\n"

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

                # Test that argument boundaries are preserved exactly
                if !Sys.iswindows()
                    argv_mock = joinpath(tmpdir, "argv-julia")
                    write(argv_mock, "#!/bin/sh\nfor a in \"\$@\"; do printf '%s\\n' \"\$a\"; done\n")
                    chmod(argv_mock, 0o755)
                    argv(args) = withenv("JULIA_APPS_JULIA_CMD" => argv_mock) do
                        split(read(`$exename $args`, String), "\n"; keepempty = true)[1:(end - 1)]
                    end
                    # app args with spaces and empty strings
                    @test argv(["a b", "", "c"]) == ["--startup-file=no", "-m", "Rot13", "a b", "", "c"]
                    # julia arg containing a space
                    @test argv(["--project=a b", "--", "z"]) == ["--startup-file=no", "--project=a b", "-m", "Rot13", "z"]
                    # only the first -- is the separator
                    @test argv(["--", "a", "--", "b"]) == ["--startup-file=no", "-m", "Rot13", "a", "--", "b"]
                    # glob characters are not expanded
                    @test argv(["*"]) == ["--startup-file=no", "-m", "Rot13", "*"]
                end
            end

            Pkg.Apps.rm("Rot13")
            @test Sys.which(exename) == nothing
            @test Sys.which(cliexename) == nothing
            @test Sys.which(nestedexename) == nothing
            @test Sys.which(flagsexename) == nothing

            # Removing apps one by one; removing the last one removes the package
            Pkg.Apps.develop(path = joinpath(@__DIR__, "test_packages", "Rot13.jl"))
            for app in ("juliarot13", "juliarot13cli", "juliarot13nested", "juliarot13flags")
                Pkg.Apps.rm(app)
            end
            @test Sys.which(exename) == nothing
            @test Sys.which(flagsexename) == nothing
            manifest = Pkg.Types.read_manifest(joinpath(first(DEPOT_PATH), "environments", "apps", "AppManifest.toml"))
            @test isempty(manifest.deps)
            # Removing something that is not installed errors
            @test_throws Pkg.Types.PkgError Pkg.Apps.rm("juliarot13")
            # add/develop with nothing to add errors
            @test_throws Pkg.Types.PkgError Pkg.Apps.add()
            @test_throws Pkg.Types.PkgError Pkg.Apps.develop()
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

            # Test both absolute path and relative path "." work for develop
            # https://github.com/JuliaLang/Pkg.jl/issues/4258 and #4480
            for test_path in [path, "."]
                if test_path == "."
                    cd(path) do
                        Pkg.Apps.develop(path = test_path)
                    end
                else
                    Pkg.Apps.develop(path = test_path)
                end

                # Verify that dev does not create an app environment directory
                app_env_dir = joinpath(first(DEPOT_PATH), "environments", "apps", "Rot13")
                @test !isdir(app_env_dir)

                # Verify that changes to the dev'd package are immediately reflected (only test once)
                if test_path == path
                    mv(joinpath(path, "src", "Rot13_edited.jl"), joinpath(path, "src", "Rot13.jl"); force = true)
                    withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
                        @test read(`$exename test`, String) == "Updated!\n"
                    end
                end

                Pkg.Apps.rm("Rot13")
            end
        end
    end

    isolate(loaded_depot = true) do
        # Relative paths in [sources] of an app's Project.toml (#4532)
        mktempdir() do tmpdir
            sep = Sys.iswindows() ? ';' : ':'
            somedep = joinpath(tmpdir, "SomeDep")
            mkpath(joinpath(somedep, "src"))
            write(
                joinpath(somedep, "Project.toml"), """
                name = "SomeDep"
                uuid = "b5c6e794-171e-4c69-906b-483714562d9a"
                version = "0.1.0"
                """
            )
            write(
                joinpath(somedep, "src", "SomeDep.jl"), """
                module SomeDep
                greet() = println("hello from SomeDep")
                end
                """
            )
            someapp_stage = joinpath(tmpdir, "staging", "SomeApp")
            mkpath(joinpath(someapp_stage, "src"))
            write(
                joinpath(someapp_stage, "Project.toml"), """
                name = "SomeApp"
                uuid = "6fe06ad9-5ce4-4b58-bb0c-29b0d7e1fd75"
                version = "0.1.0"

                [deps]
                SomeDep = "b5c6e794-171e-4c69-906b-483714562d9a"

                [sources]
                SomeDep = {path = "../SomeDep"}

                [apps]
                someapp = {}
                someapp2 = {}
                """
            )
            write(
                joinpath(someapp_stage, "src", "SomeApp.jl"), """
                module SomeApp
                using SomeDep
                function (@main)(ARGS)
                    SomeDep.greet()
                    return 0
                end
                end
                """
            )
            someapp = git_init_package(tmpdir, someapp_stage)
            Pkg.Apps.add(path = someapp)
            exename = Sys.iswindows() ? "someapp.bat" : "someapp"
            current_path = ENV["PATH"]
            withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
                @test read(`$exename`, String) == "hello from SomeDep\n"
            end

            # a relocated depot keeps working: shims locate the depot from
            # their own location and the app environment uses relative paths
            relocated = joinpath(mktempdir(), "relocated-depot")
            mkpath(relocated)
            for dir in ("bin", "environments", "packages")
                srcdir = joinpath(first(DEPOT_PATH), dir)
                isdir(srcdir) && cp(srcdir, joinpath(relocated, dir))
            end
            @test read(`$(joinpath(relocated, "bin", exename))`, String) == "hello from SomeDep\n"

            # update of a repo-tracked app fetches the latest commit (#4634)
            # and removes shims for apps the new version no longer provides
            exename2 = Sys.iswindows() ? "someapp2.bat" : "someapp2"
            @test isfile(joinpath(first(DEPOT_PATH), "bin", exename2))
            write(
                joinpath(someapp, "src", "SomeApp.jl"), """
                module SomeApp
                using SomeDep
                function (@main)(ARGS)
                    SomeDep.greet()
                    println("v2")
                    return 0
                end
                end
                """
            )
            write(
                joinpath(someapp, "Project.toml"), """
                name = "SomeApp"
                uuid = "6fe06ad9-5ce4-4b58-bb0c-29b0d7e1fd75"
                version = "0.2.0"

                [deps]
                SomeDep = "b5c6e794-171e-4c69-906b-483714562d9a"

                [sources]
                SomeDep = {path = "../SomeDep"}

                [apps]
                someapp = {}
                """
            )
            git_init_and_commit(someapp; msg = "v2")
            Pkg.Apps.update("SomeApp")
            withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
                @test read(`$exename`, String) == "hello from SomeDep\nv2\n"
            end
            @test !isfile(joinpath(first(DEPOT_PATH), "bin", exename2))
            Pkg.Apps.rm("SomeApp")

            # develop of an app with dependencies should give it a resolved
            # manifest so the dependencies can be loaded (#4697)
            Pkg.Apps.develop(path = someapp)
            @test isfile(joinpath(someapp, "Manifest.toml"))
            withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
                @test read(`$exename`, String) == "hello from SomeDep\nv2\n"
            end
            Pkg.Apps.rm("SomeApp")
        end
    end

    isolate(loaded_depot = true) do
        Pkg.Registry.add("General")
        Pkg.Apps.add(name = "Runic", version = "1.5.1")
        app_manifest() = Pkg.Types.read_manifest(joinpath(first(DEPOT_PATH), "environments", "apps", "AppManifest.toml"))
        runic_version() = only(e for e in values(app_manifest().deps) if e.name == "Runic").version
        @test runic_version() == v"1.5.1"
        # updating should bump the app itself to the latest version (#4634)
        Pkg.Apps.update("Runic")
        @test runic_version() > v"1.5.1"
        # update with no arguments updates all apps
        Pkg.Apps.update()
        # updating by app name also works
        Pkg.Apps.update("runic")
        # unknown app/package name errors
        @test_throws Pkg.Types.PkgError Pkg.Apps.update("DoesNotExist")
    end
end

end # module
