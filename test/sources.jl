module SourcesTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils
using UUIDs
using LibGit2

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

    @testset "changing rev in sources updates git-tree-sha1 (#4157)" begin
        isolate() do
            mktempdir() do tmp
                # Create a test package with two commits
                test_pkg_dir = joinpath(tmp, "TestPkg")
                mkpath(test_pkg_dir)
                cd(test_pkg_dir) do
                    write(
                        "Project.toml", """
                        name = "TestPkg"
                        uuid = "b4017d7c-a742-4580-99f2-e286571e6290"
                        version = "0.1.0"
                        """
                    )
                    mkpath("src")
                    write(
                        "src/TestPkg.jl", """
                        module TestPkg
                        greet() = "Hello, World!"
                        end
                        """
                    )

                    first_commit = string(git_init_and_commit(test_pkg_dir; msg = "Initial commit"))
                    first_tree_hash = LibGit2.with(LibGit2.GitRepo(test_pkg_dir)) do repo
                        string(LibGit2.GitHash(LibGit2.peel(LibGit2.GitTree, LibGit2.GitCommit(repo, first_commit))))
                    end

                    # Make a second commit
                    write("README.md", "# TestPkg\n")
                    second_commit = LibGit2.with(LibGit2.GitRepo(test_pkg_dir)) do repo
                        LibGit2.add!(repo, "README.md")
                        string(LibGit2.commit(repo, "Add README"; author = TEST_SIG, committer = TEST_SIG))
                    end
                    second_tree_hash = LibGit2.with(LibGit2.GitRepo(test_pkg_dir)) do repo
                        string(LibGit2.GitHash(LibGit2.peel(LibGit2.GitTree, LibGit2.GitCommit(repo, second_commit))))
                    end

                    # Create consumer project
                    consumer_dir = joinpath(tmp, "consumer")
                    mkpath(consumer_dir)
                    cd(consumer_dir) do
                        # Start with first revision
                        write(
                            "Project.toml", """
                            [deps]
                            TestPkg = "b4017d7c-a742-4580-99f2-e286571e6290"

                            [sources]
                            TestPkg = { url = "$test_pkg_dir", rev = "$first_commit" }
                            """
                        )

                        Pkg.activate(".")
                        Pkg.resolve()
                        @test isfile("Manifest.toml")
                        manifest = Pkg.Types.read_manifest("Manifest.toml")

                        # Verify first state
                        test_pkg_uuid = UUID("b4017d7c-a742-4580-99f2-e286571e6290")
                        @test haskey(manifest.deps, test_pkg_uuid)
                        test_pkg_entry = manifest[test_pkg_uuid]
                        @test test_pkg_entry.tree_hash !== nothing
                        @test string(test_pkg_entry.tree_hash) == first_tree_hash
                        @test test_pkg_entry.repo.rev == first_commit

                        # Change to second revision
                        write(
                            "Project.toml", """
                            [deps]
                            TestPkg = "b4017d7c-a742-4580-99f2-e286571e6290"

                            [sources]
                            TestPkg = { url = "$test_pkg_dir", rev = "$second_commit" }
                            """
                        )

                        Pkg.resolve()
                        manifest = Pkg.Types.read_manifest("Manifest.toml")

                        # Verify second state - git-tree-sha1 should change
                        test_pkg_entry = manifest[test_pkg_uuid]
                        @test test_pkg_entry.tree_hash !== nothing
                        @test string(test_pkg_entry.tree_hash) == second_tree_hash
                        @test test_pkg_entry.repo.rev == second_commit
                    end
                end
            end
        end
    end
end

end # module
