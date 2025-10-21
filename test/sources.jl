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
                    project_backup = cp("Project.toml", "Project.toml.bak"; force = true)
                    Pkg.free("Example")
                    @test !haskey(Pkg.project().sources, "Example")
                    cp("Project.toml.bak", "Project.toml"; force = true)
                    Pkg.add(; url = "https://github.com/JuliaLang/Example.jl/", rev = "78406c204b8")
                    @test Pkg.project().sources["Example"] == Dict("url" => "https://github.com/JuliaLang/Example.jl/", "rev" => "78406c204b8")
                    cp("Project.toml.bak", "Project.toml"; force = true)
                    cp("BadManifest.toml", "Manifest.toml"; force = true)
                    Pkg.resolve()
                    @test Pkg.project().sources["Example"] == Dict("rev" => "master", "url" => "https://github.com/JuliaLang/Example.jl")
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

    @testset "recursive [sources] via repo URLs" begin
        isolate() do
            mktempdir() do tmp
                file_url(path::AbstractString) = begin
                    normalized = replace(abspath(path), '\\' => '/')
                    if Sys.iswindows() && occursin(':', normalized)
                        normalized = "/" * normalized
                    end
                    return "file://$normalized"
                end

                template_root = joinpath(@__DIR__, "test_packages", "RecursiveSources")
                function prepare_pkg(name::AbstractString; replacements = Dict{String, String}())
                    src = joinpath(template_root, name)
                    dest = joinpath(tmp, name)
                    cp(src, dest; force = true)
                    Utils.ensure_test_package_user_writable(dest)
                    project_path = joinpath(dest, "Project.toml")
                    if !isempty(replacements)
                        content = read(project_path, String)
                        for (pattern, value) in replacements
                            content = replace(content, pattern => value)
                        end
                        write(project_path, content)
                    end
                    git_init_and_commit(dest)
                    return dest
                end

                grandchild_path = prepare_pkg("GrandchildPkg")
                grandchild_url = file_url(grandchild_path)

                child_path = prepare_pkg("ChildPkg"; replacements = Dict("__GRANDCHILD_URL__" => grandchild_url))
                child_url = file_url(child_path)

                parent_path = prepare_pkg("ParentPkg"; replacements = Dict("__CHILD_URL__" => child_url))
                parent_url = file_url(parent_path)

                Pkg.activate(temp = true)
                Pkg.add(; url = parent_url)

                dep_info_by_name = Dict(info.name => info for info in values(Pkg.dependencies()))
                for pkgname in ("ParentPkg", "ChildPkg", "GrandchildPkg", "SiblingPkg")
                    @test haskey(dep_info_by_name, pkgname)
                end
                @test dep_info_by_name["ParentPkg"].git_source == parent_url
                @test dep_info_by_name["ChildPkg"].git_source == child_url
                @test dep_info_by_name["GrandchildPkg"].git_source == grandchild_url
                sibling_info = dep_info_by_name["SiblingPkg"]
                @test sibling_info.is_tracking_path
                @test sibling_info.source !== nothing
                @test endswith(sibling_info.source, "SiblingPkg")

                result = include_string(
                    Module(), """
                    using ParentPkg
                    ParentPkg.parent_value()
                    """
                )
                @test result == 47
            end
        end
    end
end

end # module
