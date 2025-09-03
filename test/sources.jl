module SourcesTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils

temp_pkg_dir() do project_path
    @testset "test Project.toml [sources]" begin
        mktempdir() do dir
            path = copy_test_package(dir, "WithSources")
            cd(path) do
                with_current_env() do
                    Pkg.resolve()
                    @test !isempty(Pkg.project().sources["Example"])
                    project_backup = cp("Project.toml", "Project.toml.bak"; force=true)
                    Pkg.free("Example")
                    @test !haskey(Pkg.project().sources, "Example")
                    cp("Project.toml.bak", "Project.toml"; force=true)
                    Pkg.add(; url="https://github.com/JuliaLang/Example.jl/", rev="78406c204b8")
                    @test Pkg.project().sources["Example"] == Dict("url" => "https://github.com/JuliaLang/Example.jl/", "rev" => "78406c204b8")
                    cp("Project.toml.bak", "Project.toml"; force=true)
                    cp("BadManifest.toml", "Manifest.toml"; force=true)
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
        end
    end
    @testset "Issue #4368: dev with existing url source" begin
        mktempdir() do temp_dir
            # Create a test project
            project_path = joinpath(temp_dir, "test_project")
            mkpath(project_path)

            # Create Project.toml with a source that has a URL
            project_toml = joinpath(project_path, "Project.toml")
            write(
                project_toml, """
                name = "TestProject"
                uuid = "12345678-1234-1234-1234-123456789abc"
                version = "0.1.0"
                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                [sources]
                Example = {url = "https://github.com/JuliaLang/Example.jl", rev="master"}
                """
            )

            # Create a local copy of the package to dev
            local_pkg_path = joinpath(temp_dir, "Example")
            mkpath(joinpath(local_pkg_path, "src"))
            write(
                joinpath(local_pkg_path, "Project.toml"), """
                name = "Example"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.4"
                """
            )
            write(
                joinpath(local_pkg_path, "src", "Example.jl"), """
                module Example
                greet() = print("Hello World!")
                end
                """
            )

            # Try to dev the local package - this should work without conflict error
            cd(project_path) do
                with_current_env() do
                    # Before the fix, this would throw: "`path` and `url` are conflicting specifications"
                    Pkg.develop(path = local_pkg_path)

                    # Verify the package was successfully added as a development dependency
                    @test haskey(Pkg.project().dependencies, "Example")

                    # Verify that the path takes precedence over the URL in sources
                    sources = Pkg.project().sources
                    @test haskey(sources, "Example")
                    example_source = sources["Example"]
                    @test haskey(example_source, "path")
                    @test !haskey(example_source, "url")  # URL should be removed when path is set
                end
            end
        end
    end
end

end # module
