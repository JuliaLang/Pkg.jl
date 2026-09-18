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

                    # Regression test for: https://github.com/JuliaLang/Pkg.jl/issues/4688
                    # Check behaviour with a stale manifest.
                    err = try
                        Pkg.precompile()
                        nothing
                    catch e
                        e
                    end
                    @test err isa Pkg.Types.PkgError
                    @test occursin("manifest", err.msg)

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

    # Regression test for https://github.com/JuliaLang/Pkg.jl/issues/4157
    # Editing the `rev` of a `[sources]` entry directly in the project file must invalidate
    # the manifest, and `resolve` must check out the new rev instead of reusing the tree hash.
    @testset "changing the rev of a [sources] entry re-resolves the package (#4157)" begin
        mktempdir() do tmp
            cd(tmp) do
                local_pkg_uuid = UUID("00000000-0000-0000-0000-000000000002")
                mkdir("LocalPkg")
                mkdir(joinpath("LocalPkg", "src"))
                write(joinpath("LocalPkg", "src", "LocalPkg.jl"), "module LocalPkg end")
                project(version) = write(
                    joinpath("LocalPkg", "Project.toml"), """
                    name = "LocalPkg"
                    uuid = "$local_pkg_uuid"
                    version = "$version"
                    """
                )
                project("0.1.0")
                rev1 = string(git_init_and_commit("LocalPkg"))
                project("0.2.0")
                rev2 = string(git_init_and_commit("LocalPkg"; msg = "bump version"))
                @test rev1 != rev2
                local_pkg_url = make_file_url(abspath("LocalPkg"))

                env(rev) = write(
                    "Project.toml", """
                    [deps]
                    LocalPkg = "$local_pkg_uuid"

                    [sources]
                    LocalPkg = { url = "$local_pkg_url", rev = "$rev" }
                    """
                )
                env(rev1)
                with_current_env() do
                    Pkg.resolve()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    entry = manifest[local_pkg_uuid]
                    tree_hash1 = entry.tree_hash
                    project_hash1 = manifest.other["project_hash"]
                    @test entry.version == v"0.1.0"
                    @test entry.repo.rev == rev1
                    @test tree_hash1 !== nothing

                    # Resolving again without touching the project is a no-op
                    Pkg.resolve()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    @test manifest[local_pkg_uuid].tree_hash == tree_hash1
                    @test manifest.other["project_hash"] == project_hash1

                    env(rev2)
                    @test Pkg.Operations.is_manifest_current(Pkg.Types.EnvCache()) === false
                    Pkg.resolve()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    entry = manifest[local_pkg_uuid]
                    @test entry.version == v"0.2.0"
                    @test entry.repo.rev == rev2
                    @test entry.tree_hash != tree_hash1
                    @test manifest.other["project_hash"] != project_hash1
                    @test Pkg.Operations.is_manifest_current(Pkg.Types.EnvCache()) === true
                    @test Pkg.dependencies()[local_pkg_uuid].version == v"0.2.0"
                end
            end
        end
    end

    @testset "project hash covers [sources] filled in from the manifest" begin
        mktempdir() do tmp
            cd(tmp) do
                local_pkg_uuid = UUID("00000000-0000-0000-0000-000000000003")
                mkpath(joinpath("LocalPkg", "src"))
                write(
                    joinpath("LocalPkg", "Project.toml"), """
                    name = "LocalPkg"
                    uuid = "$local_pkg_uuid"
                    version = "0.1.0"
                    """
                )
                write(joinpath("LocalPkg", "src", "LocalPkg.jl"), "module LocalPkg end")
                git_init_and_commit("LocalPkg")
                local_pkg_url = make_file_url(abspath("LocalPkg"))
                is_current() = Pkg.Operations.is_manifest_current(Pkg.Types.EnvCache())

                with_current_env() do
                    Pkg.develop(path = "LocalPkg")
                    @test Pkg.project().sources["LocalPkg"] == Dict("path" => "LocalPkg")
                    @test is_current() === true
                    Pkg.resolve()
                    @test is_current() === true

                    Pkg.rm("LocalPkg")
                    Pkg.add(url = local_pkg_url)
                    @test Pkg.project().sources["LocalPkg"]["url"] == local_pkg_url
                    @test is_current() === true
                    Pkg.resolve()
                    @test is_current() === true
                end
            end
        end
    end

    # Regression test for https://github.com/JuliaLang/Pkg.jl/issues/4750
    # A `[sources]` entry in a dependency's project file must not take over a package that
    # the environment being resolved already tracks itself (here: from a registry).
    @testset "dependency [sources] don't hijack a registered direct dep (#4750)" begin
        isolate() do
            mktempdir() do tmp
                example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
                main_uuid = UUID("00000000-0000-0000-0000-000000004750")
                main = joinpath(tmp, "MainPkg")

                # MainPkg ships a copy of the registered package `Example` in a subdirectory
                # and points at it with `[sources]`, like KernelAbstractions does for
                # KernelInterface.
                mkpath(joinpath(main, "src"))
                mkpath(joinpath(main, "lib", "Example", "src"))
                write(
                    joinpath(main, "Project.toml"), """
                    name = "MainPkg"
                    uuid = "$main_uuid"
                    version = "0.1.0"

                    [deps]
                    Example = "$example_uuid"

                    [sources]
                    Example = {path = "lib/Example"}
                    """
                )
                write(joinpath(main, "src", "MainPkg.jl"), "module MainPkg\nusing Example\nend")
                write(
                    joinpath(main, "lib", "Example", "Project.toml"), """
                    name = "Example"
                    uuid = "$example_uuid"
                    version = "999.0.0-dev"
                    """
                )
                write(joinpath(main, "lib", "Example", "src", "Example.jl"), "module Example end")
                git_init_and_commit(main)

                Pkg.activate(joinpath(tmp, "env"))
                # Adding the registered `Example` alongside `MainPkg` used to error with
                # "could not find source path for package Example based on manifest ..."
                Pkg.add(
                    [
                        PackageSpec(name = "Example", uuid = example_uuid),
                        PackageSpec(url = make_file_url(main)),
                    ]
                )
                manifest = Pkg.Types.read_manifest(joinpath(tmp, "env", "Manifest.toml"))
                # `Example` stays tracked by the registry, not by MainPkg's `[sources]` path
                # (the vendored copy carries an impossible version so a regression that
                # resolves to it is also caught by the version check below)
                @test manifest[example_uuid].path === nothing
                @test manifest[example_uuid].tree_hash !== nothing
                @test manifest[example_uuid].version < v"999"
                @test !haskey(Pkg.project().sources, "Example")
                @test manifest[main_uuid].repo.source !== nothing
            end
        end
    end

    # Regression test for https://github.com/JuliaLang/Pkg.jl/issues/4650
    # The deved package's own manifest (here the workspace root manifest) is stale and
    # records a `[sources]` path dependency as registry-tracked. The tree hash must not be
    # carried over, or the entry ends up with both a path and a tree hash.
    @testset "dev package whose stale manifest tracks a [sources] path dep by tree hash (#4650)" begin
        isolate() do
            mktempdir() do tmp
                example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
                main_uuid = UUID("00000000-0000-0000-0000-000000004650")
                main = joinpath(tmp, "MainPkg")
                mkpath(joinpath(main, "src"))
                mkpath(joinpath(tmp, "Example", "src"))
                write(
                    joinpath(tmp, "Project.toml"), """
                    [workspace]
                    projects = ["MainPkg", "Example"]
                    """
                )
                # Install the registered `Example` so the stale manifest below refers to a
                # tree hash that exists in the depot, as it does when a manifest goes stale.
                Pkg.activate(joinpath(tmp, "scratch"))
                Pkg.add("Example")
                example_entry = Pkg.Types.read_manifest(joinpath(tmp, "scratch", "Manifest.toml"))[example_uuid]
                write(
                    joinpath(tmp, "Manifest.toml"), """
                    manifest_format = "2.0"

                    [[deps.Example]]
                    git-tree-sha1 = "$(example_entry.tree_hash)"
                    uuid = "$example_uuid"
                    version = "$(example_entry.version)"

                    [[deps.MainPkg]]
                    deps = ["Example"]
                    path = "MainPkg"
                    uuid = "$main_uuid"
                    version = "0.1.0"
                    """
                )
                write(
                    joinpath(main, "Project.toml"), """
                    name = "MainPkg"
                    uuid = "$main_uuid"
                    version = "0.1.0"

                    [deps]
                    Example = "$example_uuid"

                    [sources]
                    Example = {path = "../Example"}
                    """
                )
                write(joinpath(main, "src", "MainPkg.jl"), "module MainPkg\nusing Example\nend")
                write(
                    joinpath(tmp, "Example", "Project.toml"), """
                    name = "Example"
                    uuid = "$example_uuid"
                    version = "999.0.0-dev"
                    """
                )
                write(joinpath(tmp, "Example", "src", "Example.jl"), "module Example end")

                Pkg.activate(joinpath(tmp, "env"))
                Pkg.develop(path = main)
                manifest = Pkg.Types.read_manifest(joinpath(tmp, "env", "Manifest.toml"))
                @test manifest[example_uuid].path == joinpath("..", "Example")
                @test manifest[example_uuid].tree_hash === nothing
                @test manifest[example_uuid].version == v"999.0.0-dev"
            end
        end
    end
end

end # module
