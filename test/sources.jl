module SourcesTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils
using UUIDs
import LibGit2

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
                # A relative path in the `[sources]` of a package tracked from a repository
                # refers to the same repository, not to the installation of the package
                sibling_info = dep_info_by_name["SiblingPkg"]
                @test !sibling_info.is_tracking_path
                @test sibling_info.git_source == child_url
                manifest = Pkg.Types.EnvCache().manifest
                sibling_uuid = UUID("44444444-4444-4444-4444-444444444444")
                child_uuid = UUID("22222222-2222-2222-2222-222222222222")
                @test manifest[sibling_uuid].repo.subdir == "SiblingPkg"
                @test manifest[sibling_uuid].repo.rev == manifest[child_uuid].repo.rev

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

    @testset "relative [sources] of a package tracked from a repository" begin
        isolate() do
            mktempdir() do tmp
                a_uuid = UUID("00000000-0000-0000-0000-00000000b001")
                b_uuid = UUID("00000000-0000-0000-0000-00000000b002")
                repo = joinpath(tmp, "Mono")
                for (name, uuid, extra) in (
                        (
                            "A", a_uuid, """
                            [deps]
                            B = "$b_uuid"

                            [sources]
                            B = {path = "../B"}

                            [extras]
                            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                            [targets]
                            test = ["Test"]
                            """,
                        ),
                        ("B", b_uuid, ""),
                    )
                    mkpath(joinpath(repo, "lib", name, "src"))
                    write(joinpath(repo, "lib", name, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n\n$extra")
                    write(joinpath(repo, "lib", name, "src", "$name.jl"), "module $name end")
                end
                mkpath(joinpath(repo, "lib", "A", "test"))
                write(joinpath(repo, "lib", "A", "test", "runtests.jl"), "using A, B, Test\n@test true\n")
                git_init_and_commit(repo)
                subtree_hash(subdir) = LibGit2.with(LibGit2.GitRepo(repo)) do r
                    tree = LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(r, "HEAD"))
                    Base.SHA1(string(LibGit2.GitHash(tree[subdir])))
                end

                # `B` is outside of the installation of `A`, and is tracked from the same
                # repository and commit
                env = joinpath(tmp, "env")
                Pkg.activate(env)
                Pkg.add(url = make_file_url(repo), subdir = "lib/A")
                manifest = Pkg.Types.read_manifest(joinpath(env, "Manifest.toml"))
                @test manifest[b_uuid].path === nothing
                @test manifest[b_uuid].repo.source == manifest[a_uuid].repo.source
                @test manifest[b_uuid].repo.rev == manifest[a_uuid].repo.rev
                @test manifest[b_uuid].repo.subdir == "lib/B"
                @test manifest[b_uuid].tree_hash == subtree_hash("lib/B")
                @test Base.locate_package(Base.PkgId(b_uuid, "B")) !== nothing
                @test !haskey(Pkg.project().sources, "B")
                # also in the sandbox of `Pkg.test`
                Pkg.test("A")
                # where a test-only dependency still comes from the installation
                root = joinpath(tmp, "Root")
                t_uuid = UUID("00000000-0000-0000-0000-00000000b004")
                mkpath(joinpath(root, "src"))
                mkpath(joinpath(root, "test"))
                mkpath(joinpath(root, "lib", "T", "src"))
                write(
                    joinpath(root, "Project.toml"), """
                    name = "Root"
                    uuid = "00000000-0000-0000-0000-00000000b005"
                    version = "0.1.0"

                    [extras]
                    T = "$t_uuid"
                    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                    [sources]
                    T = {path = "lib/T"}

                    [targets]
                    test = ["T", "Test"]
                    """
                )
                write(joinpath(root, "src", "Root.jl"), "module Root end")
                write(joinpath(root, "test", "runtests.jl"), "using Root, T, Test\n@test true\n")
                write(joinpath(root, "lib", "T", "Project.toml"), "name = \"T\"\nuuid = \"$t_uuid\"\nversion = \"0.1.0\"\n")
                write(joinpath(root, "lib", "T", "src", "T.jl"), "module T end")
                git_init_and_commit(root)
                Pkg.add(url = make_file_url(root))
                Pkg.test("Root")

                # Another operation keeps `B` at the recorded tree, also when the clone of the
                # repository has the new commit
                write(joinpath(repo, "lib", "B", "src", "B.jl"), "module B # changed\nend")
                git_init_and_commit(repo)
                Pkg.activate(joinpath(tmp, "other"))
                Pkg.add(url = make_file_url(repo), subdir = "lib/B")
                Pkg.activate(env)
                c = joinpath(tmp, "C")
                mkpath(joinpath(c, "src"))
                write(joinpath(c, "Project.toml"), "name = \"C\"\nuuid = \"00000000-0000-0000-0000-00000000b003\"\nversion = \"0.1.0\"\n")
                write(joinpath(c, "src", "C.jl"), "module C end")
                Pkg.develop(path = c)
                @test Pkg.Types.read_manifest(joinpath(env, "Manifest.toml"))[b_uuid].tree_hash == manifest[b_uuid].tree_hash

                # and updating `A` moves `B` along to the new commit
                Pkg.update()
                manifest = Pkg.Types.read_manifest(joinpath(env, "Manifest.toml"))
                @test manifest[b_uuid].tree_hash == subtree_hash("lib/B")
                @test manifest[a_uuid].tree_hash == subtree_hash("lib/A")

                # Another operation with the same context resolves the rev again
                ctx = Pkg.Types.Context()
                Pkg.update(ctx)
                write(joinpath(repo, "lib", "B", "src", "B.jl"), "module B # changed again\nend")
                git_init_and_commit(repo)
                Pkg.update(ctx)
                @test Pkg.Types.read_manifest(joinpath(env, "Manifest.toml"))[b_uuid].tree_hash == subtree_hash("lib/B")
            end
        end
    end

    # When a package of a workspace is added by URL or developed, the other packages of the
    # workspace that it depends on come from the same commit or checkout, as if they were
    # listed in its `[sources]`
    @testset "packages of the workspace of a package added by URL or developed" begin
        isolate() do
            mktempdir() do tmp
                example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
                mono_uuid = UUID("00000000-0000-0000-0000-00000000c001")
                sub_uuid = UUID("00000000-0000-0000-0000-00000000c002")
                # `Mono` and `Sub` use the workspace copy of `Example`, which has a version
                # that is not registered, without `[sources]`
                repo = joinpath(tmp, "Mono")
                mkpath(joinpath(repo, "src"))
                write(
                    joinpath(repo, "Project.toml"), """
                    name = "Mono"
                    uuid = "$mono_uuid"
                    version = "0.1.0"

                    [workspace]
                    projects = ["lib/Example", "lib/Sub", "test"]

                    [deps]
                    Sub = "$sub_uuid"
                    """
                )
                write(joinpath(repo, "src", "Mono.jl"), "module Mono\nusing Sub\nend")
                for (name, uuid, deps) in (
                        ("Example", example_uuid, ""),
                        ("Sub", sub_uuid, "[deps]\nExample = \"$example_uuid\"\n"),
                    )
                    mkpath(joinpath(repo, "lib", name, "src"))
                    write(joinpath(repo, "lib", name, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"999.0.0\"\n\n$deps")
                    write(joinpath(repo, "lib", name, "src", "$name.jl"), "module $name end")
                end
                mkpath(joinpath(repo, "test"))
                write(joinpath(repo, "test", "Project.toml"), "[deps]\nMono = \"$mono_uuid\"\n")
                git_init_and_commit(repo)
                subtree_hash(subdir) = LibGit2.with(LibGit2.GitRepo(repo)) do r
                    tree = LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(r, "HEAD"))
                    Base.SHA1(string(LibGit2.GitHash(tree[subdir])))
                end
                function check_from_repo(env, subdirs)
                    manifest = Pkg.Types.read_manifest(joinpath(env, "Manifest.toml"))
                    for (uuid, subdir) in subdirs
                        entry = manifest[uuid]
                        @test entry.version == v"999.0.0"
                        @test entry.path === nothing
                        @test entry.repo.source == make_file_url(repo)
                        @test entry.repo.subdir == subdir
                        @test entry.tree_hash == subtree_hash(subdir)
                    end
                    return manifest
                end
                # `UserPkg` has the registered `Example` as a dependency
                user = joinpath(tmp, "UserPkg")
                mkpath(joinpath(user, "src"))
                write(
                    joinpath(user, "Project.toml"), """
                    name = "UserPkg"
                    uuid = "00000000-0000-0000-0000-00000000c003"
                    version = "0.1.0"

                    [deps]
                    Example = "$example_uuid"
                    """
                )
                write(joinpath(user, "src", "UserPkg.jl"), "module UserPkg\nusing Example\nend")

                Pkg.activate(joinpath(tmp, "url"))
                Pkg.develop(path = user)
                @test Pkg.dependencies()[example_uuid].version < v"999"
                Pkg.add(url = make_file_url(repo))
                check_from_repo(joinpath(tmp, "url"), (sub_uuid => "lib/Sub", example_uuid => "lib/Example"))
                @test !haskey(Pkg.project().sources, "Sub")

                # Updating `Mono` moves the other packages along
                write(joinpath(repo, "lib", "Example", "src", "Example.jl"), "module Example # changed\nend")
                git_init_and_commit(repo)
                Pkg.update()
                check_from_repo(joinpath(tmp, "url"), (sub_uuid => "lib/Sub", example_uuid => "lib/Example"))

                # A package in a subdirectory of the repository
                Pkg.activate(joinpath(tmp, "subdir"))
                Pkg.add(url = make_file_url(repo), subdir = "lib/Sub")
                manifest = check_from_repo(joinpath(tmp, "subdir"), (example_uuid => "lib/Example",))
                @test !haskey(manifest, mono_uuid)

                # A direct dependency of the environment keeps its source
                Pkg.activate(joinpath(tmp, "direct"))
                Pkg.add("Example")
                Pkg.add(url = make_file_url(repo))
                @test Pkg.dependencies()[example_uuid].version < v"999"
                @test Pkg.dependencies()[sub_uuid].version == v"999.0.0"

                # Developing a package develops the packages of its workspace that it uses
                Pkg.activate(joinpath(tmp, "dev"))
                Pkg.develop(path = user)
                Pkg.develop(path = joinpath(repo, "lib", "Sub"))
                manifest = Pkg.Types.read_manifest(joinpath(tmp, "dev", "Manifest.toml"))
                @test manifest[example_uuid].path !== nothing
                @test samefile(joinpath(tmp, "dev", manifest[example_uuid].path), joinpath(repo, "lib", "Example"))
                @test !haskey(manifest, mono_uuid)
            end
        end
    end

    # Regression test for https://github.com/JuliaLang/Pkg.jl/issues/4337
    # Switching between path and repo sources should not cause assertion error
    @testset "[sources] url for a stdlib, resolved from scratch" begin
        # `source_path` used to answer with the bundled stdlib for a stdlib tracking a repo, so
        # the repo was never fetched and the manifest entry had a source but no tree hash
        mktempdir() do tmp
            cd(tmp) do
                base64_uuid = UUID("2a0f44e3-6c83-55bd-87e4-b1978d98bd5f")
                cp(joinpath(Sys.STDLIB, "Base64"), "Base64")
                chmod("Base64", 0o755; recursive = true)
                git_init_and_commit("Base64")
                write(
                    "Project.toml", """
                    [deps]
                    Base64 = "$base64_uuid"

                    [sources]
                    Base64 = { url = "$(make_file_url(abspath("Base64")))" }
                    """
                )
                with_current_env() do
                    Pkg.instantiate()
                    manifest = Pkg.Types.read_manifest("Manifest.toml")
                    @test manifest[base64_uuid].tree_hash !== nothing
                    @test manifest[base64_uuid].repo.source !== nothing
                    @test Pkg.dependencies()[base64_uuid].source != Pkg.Types.stdlib_path("Base64")
                    Pkg.instantiate() # and again, with the manifest in place
                end
            end
        end
    end

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

    # Regression test for https://github.com/JuliaLang/Pkg.jl/issues/4750
    # A `[sources]` entry in a dependency's project file must not take over a package that
    # the environment being resolved tracks itself (here: from a registry), but does take
    # over one that is only kept from the manifest.
    @testset "dependency [sources] and packages already in the environment (#4750)" begin
        isolate() do
            mktempdir() do tmp
                example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
                main_uuid = UUID("00000000-0000-0000-0000-000000004750")

                # MainPkg ships a copy of the registered package `Example` in a subdirectory
                # and points at it with `[sources]`, like KernelAbstractions does for
                # KernelInterface.
                function make_main(name, uuid)
                    dir = joinpath(tmp, name)
                    mkpath(joinpath(dir, "src"))
                    mkpath(joinpath(dir, "lib", "Example", "src"))
                    write(
                        joinpath(dir, "Project.toml"), """
                        name = "$name"
                        uuid = "$uuid"
                        version = "0.1.0"

                        [deps]
                        Example = "$example_uuid"

                        [sources]
                        Example = {path = "lib/Example"}
                        """
                    )
                    write(joinpath(dir, "src", "$name.jl"), "module $name\nusing Example\nend")
                    write(
                        joinpath(dir, "lib", "Example", "Project.toml"), """
                        name = "Example"
                        uuid = "$example_uuid"
                        version = "999.0.0-dev"
                        """
                    )
                    write(joinpath(dir, "lib", "Example", "src", "Example.jl"), "module Example # $name\nend")
                    git_init_and_commit(dir)
                    return dir
                end
                main = make_main("MainPkg", main_uuid)

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

                # A registered `Example` that is only in the manifest because another
                # package depends on it is taken over
                user = joinpath(tmp, "UserPkg")
                mkpath(joinpath(user, "src"))
                write(
                    joinpath(user, "Project.toml"), """
                    name = "UserPkg"
                    uuid = "00000000-0000-0000-0000-000000004751"
                    version = "0.1.0"

                    [deps]
                    Example = "$example_uuid"
                    """
                )
                write(joinpath(user, "src", "UserPkg.jl"), "module UserPkg\nusing Example\nend")
                Pkg.activate(joinpath(tmp, "indirect"))
                Pkg.develop(path = user)
                @test Pkg.dependencies()[example_uuid].version < v"999"
                Pkg.add(url = make_file_url(main))
                @test Pkg.dependencies()[example_uuid].version == v"999.0.0-dev"
                @test !haskey(Pkg.project().sources, "Example")
                # MainPkg is kept at its tree hash from now on, which doesn't tell the commit
                # that `Example` would come from, so freeing `Example` sticks
                Pkg.free("Example")
                @test Pkg.dependencies()[example_uuid].version < v"999"
                Pkg.resolve()
                @test Pkg.dependencies()[example_uuid].version < v"999"
                @test !Pkg.dependencies()[example_uuid].is_tracking_path
                # and can't be freed while the `[sources]` of a developed MainPkg track it
                Pkg.activate(joinpath(tmp, "free"))
                Pkg.develop(path = user)
                Pkg.develop(path = main)
                @test Pkg.dependencies()[example_uuid].version == v"999.0.0-dev"
                err = @test_throws Pkg.Types.PkgError Pkg.free("Example")
                @test occursin("can not be freed", err.value.msg)

                # Two packages with different `[sources]` for the same package
                other = make_main("OtherPkg", UUID("00000000-0000-0000-0000-000000004752"))
                Pkg.activate(joinpath(tmp, "conflict"))
                err = @test_throws Pkg.Types.PkgError Pkg.add([PackageSpec(url = make_file_url(main)), PackageSpec(url = make_file_url(other))])
                @test occursin("different `[sources]`", err.value.msg)

                # but a source that leaves out the rev is the same as one with the default branch
                dep = joinpath(tmp, "DepPkg")
                dep_uuid = UUID("00000000-0000-0000-0000-000000004753")
                mkpath(joinpath(dep, "src"))
                write(joinpath(dep, "Project.toml"), "name = \"DepPkg\"\nuuid = \"$dep_uuid\"\nversion = \"0.1.0\"\n")
                write(joinpath(dep, "src", "DepPkg.jl"), "module DepPkg end")
                git_init_and_commit(dep)
                branch = LibGit2.with(LibGit2.branch, LibGit2.GitRepo(dep))
                users = map(enumerate(("", ", rev = \"$branch\"", ", rev = \"feature\""))) do (i, rev)
                    user = joinpath(tmp, "DepUser$i")
                    mkpath(joinpath(user, "src"))
                    write(
                        joinpath(user, "Project.toml"), """
                        name = "DepUser$i"
                        uuid = "00000000-0000-0000-0000-00000000476$i"
                        version = "0.1.0"

                        [deps]
                        DepPkg = "$dep_uuid"

                        [sources]
                        DepPkg = {url = "$(make_file_url(dep))"$rev}
                        """
                    )
                    write(joinpath(user, "src", "DepUser$i.jl"), "module DepUser$i end")
                    git_init_and_commit(user)
                    PackageSpec(url = make_file_url(user))
                end
                Pkg.activate(joinpath(tmp, "same"))
                Pkg.add(users[1:2])
                @test Pkg.dependencies()[dep_uuid].git_revision == branch
                # and that is still different from another rev
                Pkg.activate(joinpath(tmp, "three"))
                err = @test_throws Pkg.Types.PkgError Pkg.add(users)
                @test occursin("different `[sources]`", err.value.msg)
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
