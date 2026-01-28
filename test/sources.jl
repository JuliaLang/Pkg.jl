module SourcesTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils
using UUIDs

temp_pkg_dir() do project_path
    @testset "test Project.toml [sources]" begin
        mktempdir() do dir
            path = copy_test_package(dir, "WithSources")
            cd(path) do
                with_current_env() do
                    Pkg.resolve()
                    @test !isempty(Pkg.project().sources["Example"])
                    project_backup = cp("Project.toml", "Project.toml.bak"; force = true)
                    Pkg.free("Example")
                    @test !haskey(Pkg.project().sources, "Example")
                    cp("Project.toml.bak", "Project.toml"; force = true)
                    Pkg.add(; url = "https://github.com/JuliaLang/Example.jl/", rev = "78406c204b8")
                    @test Pkg.project().sources["Example"] == Dict("url" => "https://github.com/JuliaLang/Example.jl/", "rev" => "78406c204b8")
                    cp("Project.toml.bak", "Project.toml"; force = true)
                    cp("BadManifest.toml", "Manifest.toml"; force = true)
                    Pkg.resolve()
                    @test Pkg.project().sources["Example"] == Dict("url" => "https://github.com/JuliaLang/Example.jl")
                    @test Pkg.project().sources["LocalPkg"] == Dict("path" => "LocalPkg")
                end
            end

            cd(joinpath(dir, "WithSources", "TestWithUnreg")) do
                with_current_env() do
                    Pkg.test()
                end
            end

            cd(joinpath(dir, "WithSources", "TestMonorepo")) do
                with_current_env() do
                    Pkg.test()
                end
            end

            cd(joinpath(dir, "WithSources", "TestProject")) do
                with_current_env() do
                    Pkg.test()
                end
            end

            cd(joinpath(dir, "WithSources", "URLSourceInDevvedPackage")) do
                with_current_env() do
                    Pkg.test()
                end
            end

            @testset "Don't add paths or URLs to sources in v1.12" begin
                # Test that we're not creating sources when dev-ing
                Pkg.generate("A")
                Pkg.generate("B")
                Pkg.activate("A")
                Pkg.develop(path = "B")
                @test isempty(Pkg.project().sources)

                Pkg.add(url = "https://github.com/JuliaLang/Example.jl", rev = "master")
                @test isempty(Pkg.project().sources)
            end
        end
    end

    # Regression test for https://github.com/JuliaLang/Pkg.jl/issues/4337
    # Switching between path and repo sources should not cause assertion error
    @testset "switching between path and repo sources (#4337)" begin
        mktempdir() do tmp
            cd(tmp) do
                # Create a local package and initialize it as a git repo
                local_pkg_uuid = UUID("00000000-0000-0000-0000-000000000001")
                mkdir("LocalPkg")
                write(
                    joinpath("LocalPkg", "Project.toml"), """
                    name = "LocalPkg"
                    uuid = "$local_pkg_uuid"
                    version = "0.1.0"
                    """
                )
                mkdir(joinpath("LocalPkg", "src"))
                write(joinpath("LocalPkg", "src", "LocalPkg.jl"), "module LocalPkg end")

                # Initialize as a git repo
                git_init_and_commit("LocalPkg")

                # Get the absolute path for file:// URL
                local_pkg_url = make_file_url(abspath("LocalPkg"))

                # Create test project with path source
                write(
                    "Project.toml", """
                    [deps]
                    LocalPkg = "$local_pkg_uuid"

                    [sources]
                    LocalPkg = { path = "LocalPkg" }
                    """
                )

                with_current_env() do
                    # Initial resolve with path source
                    Pkg.resolve()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    @test manifest[local_pkg_uuid].path !== nothing
                    @test manifest[local_pkg_uuid].tree_hash === nothing
                    @test manifest[local_pkg_uuid].repo.source === nothing
                    # Update should work without error
                    Pkg.update()

                    # Switch to repo source using file:// protocol
                    write(
                        "Project.toml", """
                        [deps]
                        LocalPkg = "$local_pkg_uuid"

                        [sources]
                        LocalPkg = { url = "$local_pkg_url", rev = "HEAD" }
                        """
                    )

                    # This should NOT cause an assertion error about tree_hash and path both being set
                    Pkg.update()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    @test manifest[local_pkg_uuid].path === nothing
                    @test manifest[local_pkg_uuid].tree_hash !== nothing
                    @test manifest[local_pkg_uuid].repo.source !== nothing

                    # Switch back to path source
                    write(
                        "Project.toml", """
                        [deps]
                        LocalPkg = "$local_pkg_uuid"

                        [sources]
                        LocalPkg = { path = "LocalPkg" }
                        """
                    )

                    # This should work and restore the path source without assertion error
                    Pkg.update()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    @test manifest[local_pkg_uuid].path !== nothing
                    @test manifest[local_pkg_uuid].tree_hash === nothing
                    @test manifest[local_pkg_uuid].repo.source === nothing
                end
            end
        end
    end

    @testset "path normalization in Project.toml [sources]" begin
        mktempdir() do tmp
            cd(tmp) do
                # Create a minimal Project.toml with sources containing a path
                write(
                    "Project.toml",
                    """
                    name = "TestPackage"
                    uuid = "12345678-1234-1234-1234-123456789abc"

                    [deps]
                    LocalPkg = "87654321-4321-4321-4321-cba987654321"

                    [sources]
                    LocalPkg = { path = "subdir/LocalPkg" }
                    """
                )

                # Read the project
                project = Pkg.Types.read_project("Project.toml")

                # Verify the path is read correctly (will have native separators internally)
                @test haskey(project.sources, "LocalPkg")
                @test haskey(project.sources["LocalPkg"], "path")

                # Write it back
                Pkg.Types.write_project(project, "Project.toml")

                # Read the written file as string and verify forward slashes are used
                project_content = read("Project.toml", String)
                @test occursin("path = \"subdir/LocalPkg\"", project_content)
                # Verify backslashes are NOT in the path (would indicate Windows path wasn't normalized)
                @test !occursin("path = \"subdir\\\\LocalPkg\"", project_content)
            end
        end
    end
end

end # module
