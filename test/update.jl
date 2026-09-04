module UpdateTests

using Test
using TOML, UUIDs
import ..Pkg, LibGit2
using Pkg.Types: PkgError
using Pkg.Resolve: ResolverError
using ..Utils

exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")
parsers_uuid = UUID("69de0a69-1ddd-5017-9359-2bf0b02dc9f0")
markdown_uuid = UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
test_stdlib_uuid = UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
unicode_uuid = UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5")
unregistered_uuid = UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")
simple_package_uuid = UUID("fc6b7c0f-8a2f-4256-bbf4-8c72c30df5be")

@testset "instantiate: changes to the active project" begin
    # Instantiate should preserve tree hash for regularly versioned packages.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        th = nothing
        Pkg.dependencies(exuuid) do pkg
            th = pkg.tree_hash
            @test pkg.name == "Example"
            @test pkg.version == v"0.3.0"
            @test isdir(pkg.source)
        end
        rm(joinpath(DEPOT_PATH[1], "packages"); force = true, recursive = true)
        rm(joinpath(DEPOT_PATH[1], "clones"); force = true, recursive = true)
        Pkg.instantiate()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.version == v"0.3.0"
            @test isdir(pkg.source)
            @test pkg.tree_hash == th
        end
    end
    # `instantiate` should preserve tree hash for packages tracking repos.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", rev = "v0.5.3")
        th = nothing
        Pkg.dependencies(exuuid) do pkg
            th = pkg.tree_hash
            @test pkg.name == "Example"
            @test isdir(pkg.source)
        end
        rm(joinpath(DEPOT_PATH[1], "packages"); force = true, recursive = true)
        rm(joinpath(DEPOT_PATH[1], "clones"); force = true, recursive = true)
        Pkg.instantiate()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test isdir(pkg.source)
        end
    end
    # `instantiate` should check for a consistent dependency graph.
    # Otherwise it is not clear what to instantiate.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "ExtraDirectDep")
            Pkg.activate(joinpath(tempdir, "ExtraDirectDep"))
            @test_throws PkgError Pkg.instantiate()
        end
    end
    # However, if `manifest=false`, we know to instantiate from the direct dependencies.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "ExtraDirectDep")
            Pkg.activate(joinpath(tempdir, "ExtraDirectDep"))
            Pkg.instantiate(; manifest = false)
            @test haskey(Pkg.project().dependencies, "Example")
            @test haskey(Pkg.project().dependencies, "Unicode")
        end
    end
    # `instantiate` lonely manifest
    isolate(loaded_depot = true) do
        manifest_dir = joinpath(@__DIR__, "manifest", "noproject")
        cd(manifest_dir) do
            try
                Pkg.activate(".")
                Pkg.instantiate()
                @test Base.active_project() == abspath("Project.toml")
                @test isinstalled("Example")
                @test isinstalled("x1")
            finally
                rm("Project.toml"; force = true)
            end
        end
    end
    # instantiate old manifest
    isolate(loaded_depot = true) do
        manifest_dir = joinpath(@__DIR__, "manifest", "old")
        cd(manifest_dir) do
            Pkg.activate(".")
            Pkg.instantiate()
            @test isinstalled("DelimitedFiles")
        end
    end
    # `instantiate` on a lonely manifest should detect duplicate names
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            simple_package_path = copy_test_package(tempdir, "SimplePackage")
            unregistered_example_path = copy_test_package(tempdir, "Example")
            Pkg.develop(path = simple_package_path)
            Pkg.develop(path = unregistered_example_path)
            rm(Pkg.project().path)
            # Broken, likely by a change in julia Base
            # @test_throws PkgError Pkg.instantiate()
        end
    end
    # verbose smoke test
    isolate(loaded_depot = true) do
        Pkg.instantiate(; verbose = true)
    end
end

@testset "instantiate: caching" begin
    # Instantiate should not override existing source.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        th, t1 = nothing, nothing
        Pkg.dependencies(exuuid) do pkg
            th = pkg.tree_hash
            @test pkg.name == "Example"
            @test pkg.version == v"0.3.0"
            @test isdir(pkg.source)
            t1 = mtime(pkg.source)
        end
        Pkg.instantiate()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.tree_hash == th
            @test pkg.name == "Example"
            @test pkg.version == v"0.3.0"
            @test isdir(pkg.source)
            @test mtime(pkg.source) == t1
        end
    end
    # TODO check registry updates
end

@testset "update: input checking" begin
    # Unregistered UUID in manifest
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            package_path = copy_test_package(tempdir, "UnregisteredUUID")
            Pkg.activate(package_path)
            @test_throws PkgError Pkg.update()
        end
    end
    # package does not exist in the manifest
    isolate(loaded_depot = true) do
        @test_throws PkgError Pkg.update("Example")
    end
end

@testset "update: changes to the active project" begin
    # Basic testing of UPLEVEL
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.update(; level = Pkg.UPLEVEL_FIXED)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.update(; level = Pkg.UPLEVEL_PATCH)
        @test Pkg.dependencies()[exuuid].version == v"0.3.3"
        Pkg.update(; level = Pkg.UPLEVEL_MINOR)
        @test Pkg.dependencies()[exuuid].version.minor != 3
    end
    # `update` should prune manifest
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "Unpruned")
            Pkg.activate(joinpath(tempdir, "Unpruned"))
            Pkg.update()
            @test haskey(Pkg.project().dependencies, "Example")
            Pkg.dependencies(exuuid) do pkg
                @test pkg.version > v"0.4.0"
            end
            @test !haskey(Pkg.dependencies(), unicode_uuid)
        end
    end
    # `up` should work without a manifest
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "SimplePackage")
            Pkg.activate(joinpath(tempdir, "SimplePackage"))
            Pkg.update()
            @test haskey(Pkg.project().dependencies, "Example")
            @test haskey(Pkg.project().dependencies, "Markdown")
            Pkg.dependencies(exuuid) do pkg
                @test pkg.name == "Example"
                @test pkg.is_tracking_registry
            end
        end
    end
end

@testset "update: package state changes" begin
    # basic update on old registered package
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        Pkg.update()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.version > v"0.3.0"
        end
    end
    # `update` should not update `pin`ed packages
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_pinned
            @test pkg.version == v"0.3.0"
        end
        Pkg.update()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_pinned
            @test pkg.version == v"0.3.0"
        end
    end
    # stdlib special casing
    isolate(loaded_depot = true) do
        Pkg.add("Markdown")
        Pkg.update()
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
    end
    # up should not affect `dev` packages
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            Pkg.develop(path = path)
            state = Pkg.dependencies()[simple_package_uuid]
            Pkg.update()
            @test Pkg.dependencies()[simple_package_uuid] == state
        end
    end
    # up and packages tracking repos
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
            Pkg.add(path = path)
            # test everything went ok
            Pkg.dependencies(simple_package_uuid) do pkg
                @test pkg.name == "SimplePackage"
                @test pkg.version == v"0.2.0"
                @test haskey(pkg.dependencies, "Example")
                @test haskey(pkg.dependencies, "Markdown")
                @test !haskey(pkg.dependencies, "Unicode")
            end
            simple_package_node = Pkg.dependencies()[simple_package_uuid]
            # now we bump the remote version
            mv(joinpath(path, "Project2.toml"), joinpath(path, "Project.toml"); force = true)
            new_commit = nothing
            LibGit2.with(LibGit2.GitRepo(path)) do repo
                LibGit2.add!(repo, "*")
                new_commit = string(LibGit2.commit(repo, "bump version"; author = TEST_SIG, committer = TEST_SIG))
            end
            # update with UPLEVEL != UPLEVEL_MAJOR should not update packages tracking repos
            Pkg.update(; level = Pkg.UPLEVEL_MINOR)
            @test simple_package_node == Pkg.dependencies()[simple_package_uuid]
            Pkg.update(; level = Pkg.UPLEVEL_PATCH)
            @test simple_package_node == Pkg.dependencies()[simple_package_uuid]
            Pkg.update(; level = Pkg.UPLEVEL_FIXED)
            @test simple_package_node == Pkg.dependencies()[simple_package_uuid]
            # Update should not modify pinned packages which are tracking repos
            Pkg.pin("SimplePackage")
            Pkg.update()
            Pkg.free("SimplePackage")
            @test simple_package_node == Pkg.dependencies()[simple_package_uuid]
            # update should update packages tracking repos if UPLEVEL_MAJOR
            Pkg.update()
            if !Sys.iswindows() # this test is very flaky on Windows, why?
                Pkg.dependencies(simple_package_uuid) do pkg
                    @test pkg.name == "SimplePackage"
                    @test pkg.version == v"0.3.0"
                    @test !haskey(pkg.dependencies, "Example")
                    @test haskey(pkg.dependencies, "Markdown")
                    @test haskey(pkg.dependencies, "Unicode")
                end
            end
        end
    end
    # make sure that we preserve the state of packages which are not the target
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl")
        Pkg.develop("Example")
        Pkg.add(name = "JSON", version = "0.18.0")
        Pkg.add("Markdown")
        Pkg.add("Unicode")
        Pkg.update("Unicode")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test pkg.git_revision == "master"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_tracking_path
        end
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.name == "JSON"
            @test pkg.version == v"0.18.0"
            @test pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Markdown")
        @test haskey(Pkg.project().dependencies, "Unicode")
    end
    isolate(loaded_depot = true) do
        Pkg.add([(; name = "Example", version = "0.3.0"), (; name = "JSON", version = "0.21.0"), (; name = "Parsers", version = "1.1.2")])
        Pkg.update("JSON")
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version > v"0.21.0"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.0"
        end
        Pkg.dependencies(parsers_uuid) do pkg
            @test pkg.version == v"1.1.2"
        end

        Pkg.add(name = "JSON", version = "0.21.0")
        Pkg.update("JSON"; preserve = Pkg.PRESERVE_DIRECT)
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version > v"0.21.0"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.0"
        end
        Pkg.dependencies(parsers_uuid) do pkg
            @test pkg.version == v"1.1.2"
        end

        Pkg.add(name = "JSON", version = "0.21.0")
        Pkg.rm("Parsers")

        Pkg.update("JSON"; preserve = Pkg.PRESERVE_DIRECT)
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version > v"0.21.0"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.0"
        end
        Pkg.dependencies(parsers_uuid) do pkg
            @test pkg.version > v"1.1.2"
        end

        Pkg.add([(; name = "Example", version = "0.3.0"), (; name = "JSON", version = "0.21.0"), (; name = "Parsers", version = "1.1.2")])
        Pkg.update("JSON"; preserve = Pkg.PRESERVE_NONE)
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version > v"0.21.0"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.0"
        end
        Pkg.dependencies(parsers_uuid) do pkg
            @test pkg.version > v"1.1.2"
        end
        Pkg.update()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version > v"0.3.0"
        end

        @test_throws PkgError("`repo` is a private field of PackageSpec and should not be set directly") Pkg.add([Pkg.PackageSpec(; repo = Pkg.Types.GitRepo(source = "someurl"))])
    end
end

@testset "update: caching" begin
    # `up` should detect broken local packages
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
            Pkg.add(path = path)
            rm(joinpath(path, ".git"); force = true, recursive = true)
            @test_throws PkgError Pkg.update()
        end
    end
end

@testset "pin: input checking" begin
    # a package must exist in the dep graph in order to be pinned
    isolate(loaded_depot = true) do
        @test_throws PkgError Pkg.pin("Example")
    end
    # pinning to an arbitrary version should check for unregistered packages
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl")
        @test_throws PkgError(
            "unable to pin unregistered package `Unregistered [dcb67f36]` to an arbitrary version"
        ) Pkg.pin(name = "Unregistered", version = "0.1.0")
    end
    # pinning to an arbitrary version should check version exists
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", rev = "master")
        @test_throws ResolverError Pkg.pin(name = "Example", version = "100.0.0")
    end
end

@testset "pin: package state changes" begin
    # regular registered package
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.3")
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_pinned
        end
    end
    # package tracking repo
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl")
        Pkg.pin("Unregistered")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test !pkg.is_tracking_registry
            @test pkg.is_pinned
        end
    end
    # versioned pin
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.3")
        Pkg.pin(name = "Example", version = "0.5.1")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_pinned
            @test pkg.version == v"0.5.1"
        end
    end
end

@testset "free: input checking" begin
    # free checks for existing package
    isolate(loaded_depot = true) do
        @test_throws PkgError Pkg.free("Example")
    end
    # free checks for unpinned package
    isolate(loaded_depot = true) do
        Pkg.add("Unicode")
        @test_throws PkgError(
            string(
                "expected package `Unicode [4ec0a83e]` to be",
                " pinned, tracking a path, or tracking a repository"
            )
        ) Pkg.free("Unicode")
    end
end

@testset "free: package state changes" begin
    # free pinned package
    isolate(loaded_depot = true) do
        Pkg.add("Example")
        Pkg.pin("Example")
        Pkg.free("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test !pkg.is_pinned
        end
    end
    # free package tracking repo
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", rev = "master")
        Pkg.free("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_tracking_registry
        end
    end
    # free developed package
    isolate(loaded_depot = true) do
        Pkg.develop("Example")
        Pkg.free("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_tracking_registry
        end
    end
    # free developed package when the active project is itself a package (#4686)
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("MyPkg")
            Pkg.activate("MyPkg")
            Pkg.develop("Example")
            Pkg.free("Example")
            Pkg.dependencies(exuuid) do pkg
                @test pkg.name == "Example"
                @test pkg.is_tracking_registry
            end
            @test !haskey(Pkg.project().sources, "Example")
        end
    end
    # free should error when called on packages tracking unregistered packages
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl")
        @test_throws PkgError("unable to free unregistered package `Unregistered [dcb67f36]`") Pkg.free("Unregistered")
    end
    isolate(loaded_depot = true) do
        Pkg.develop(url = "https://github.com/00vareladavid/Unregistered.jl")
        @test_throws PkgError("unable to free unregistered package `Unregistered [dcb67f36]`") Pkg.free("Unregistered")
    end
end

@testset "resolve" begin
    # resolve should ignore `extras`
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            package_path = copy_test_package(tempdir, "TestTarget")
            Pkg.activate(package_path)
            Pkg.resolve()
            @test !haskey(Pkg.dependencies(), markdown_uuid)
            @test !haskey(Pkg.dependencies(), test_stdlib_uuid)
        end
    end
    # resolve with repo-tracked package that has tree_hash in manifest (issue #4561)
    # This tests that startswith/endswith correctly handle SHA1 tree_hash types
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl", rev = "v0.5.3")
        # Remove both clones and packages so resolve needs to re-clone
        rm(joinpath(DEPOT_PATH[1], "clones"); force = true, recursive = true)
        rm(joinpath(DEPOT_PATH[1], "packages"); force = true, recursive = true)
        # This should not throw "MethodError: no method matching startswith(::Base.SHA1, ::String)"
        Pkg.resolve()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test isdir(pkg.source)
        end
    end
end

@testset "rm" begin
    # simple rm
    isolate(loaded_depot = true) do
        Pkg.add("Example")
        Pkg.rm("Example")
        @test isempty(Pkg.project().dependencies)
        @test isempty(Pkg.dependencies())
    end
    # remove should not alter other dependencies
    isolate(loaded_depot = true) do
        Pkg.add(
            [
                (; name = "Example"),
                (; name = "JSON", version = "0.18.0"),
            ]
        )
        json = Pkg.dependencies()[json_uuid]
        Pkg.rm("Example")
        @test Pkg.dependencies()[json_uuid] == json
        @test haskey(Pkg.project().dependencies, "JSON")
    end
    # rm should remove unused compat entries
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "BasicCompat")
            Pkg.activate(path)
            # TODO interface for `compat`
            @test haskey(Pkg.Types.Context().env.project.compat, "Example")
            @test haskey(Pkg.Types.Context().env.project.compat, "julia")
            Pkg.rm("Example")
            @test !haskey(Pkg.Types.Context().env.project.compat, "Example")
            @test haskey(Pkg.Types.Context().env.project.compat, "julia")
        end
    end
    # rm should not unnecessarily remove compat entries
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "CompatExtras")
            Pkg.activate(path)
            @test haskey(Pkg.Types.Context().env.project.compat, "Aqua")
            @test haskey(Pkg.Types.Context().env.project.compat, "DataFrames")
            Pkg.rm("DataFrames")
            @test !haskey(Pkg.Types.Context().env.project.compat, "DataFrames")
            @test haskey(Pkg.Types.Context().env.project.compat, "Aqua")
        end
    end
    # rm removes unused recursive dependencies
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            Pkg.develop(path = path)
            Pkg.add(name = "JSON", version = "0.18.0")
            Pkg.rm("SimplePackage")
            @test haskey(Pkg.dependencies(), markdown_uuid)
            @test !haskey(Pkg.dependencies(), simple_package_uuid)
            @test !haskey(Pkg.dependencies(), exuuid)
            @test haskey(Pkg.dependencies(), json_uuid)
        end
    end
    # rm manifest mode
    isolate(loaded_depot = true) do
        Pkg.add("Example")
        Pkg.add(name = "JSON", version = "0.18.0")
        Pkg.rm("Random"; mode = Pkg.PKGMODE_MANIFEST)
        @test haskey(Pkg.dependencies(), exuuid)
        @test !haskey(Pkg.dependencies(), json_uuid)
    end
    # rm nonexistent packages warns but does not error
    isolate(loaded_depot = true) do
        Pkg.add("Example")
        @test_logs (:warn, r"not in project, ignoring") Pkg.rm(name = "FooBar", uuid = UUIDs.UUID(0))
        @test_logs (:warn, r"not in manifest, ignoring") Pkg.rm(name = "FooBar", uuid = UUIDs.UUID(0); mode = Pkg.PKGMODE_MANIFEST)
    end
end

@testset "all" begin
    # pin all, free all, rm all packages
    isolate(loaded_depot = true) do
        Pkg.add(["Example", "JSON"])

        Pkg.pin(all_pkgs = true)
        @test length(Pkg.dependencies()) > 1
        for (uuid, pkg) in Pkg.dependencies()
            @test pkg.is_pinned
        end

        iob = IOBuffer()
        Pkg.update(io = iob)
        @test endswith(strip(String(take!(iob))), "All dependencies are pinned - nothing to update.")

        Pkg.free(all_pkgs = true)
        @test length(Pkg.dependencies()) > 1
        for (uuid, pkg) in Pkg.dependencies()
            @test !pkg.is_pinned
        end

        Pkg.pin("Example")
        Pkg.free(all_pkgs = true) # test that this doesn't error because JSON is already free
        Pkg.rm(all_pkgs = true)
        @test !haskey(Pkg.dependencies(), exuuid)

        # test that the noops don't error
        Pkg.rm(all_pkgs = true)
        Pkg.pin(all_pkgs = true)
        Pkg.free(all_pkgs = true)
    end
end

@testset "Repo caching" begin
    default_branch = LibGit2.getconfig("init.defaultBranch", "master")
    # Add by URL should not overwrite files.
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl")
        s1, t1, c1 = 0, 0, 0
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            s1 = pkg.source
            c1 = Pkg.Types.add_repo_cache_path(pkg.git_source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            t1 = mtime(pkg.source)
        end
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            @test Base.samefile(pkg.source, s1)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            @test Pkg.Types.add_repo_cache_path(pkg.git_source) == c1
            @test mtime(pkg.source) == t1
        end
    end
    # Add by URL should not overwrite files, even across projects
    isolate(loaded_depot = true) do
        # Make sure we have everything downloaded
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl")
        s1, t1, c1 = 0, 0, 0
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            s1 = pkg.source
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            c1 = Pkg.Types.add_repo_cache_path(pkg.git_source)
            t1 = mtime(pkg.source)
        end
        # Now we activate a new project and make sure it is clean.
        Pkg.activate("Foo"; shared = true)
        @test isempty(Pkg.project().dependencies)
        @test isempty(Pkg.dependencies())
        # Finally, add the same URL, we should reuse the existing directories.
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            @test Base.samefile(pkg.source, s1)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            @test Pkg.Types.add_repo_cache_path(pkg.git_source) == c1
            @test mtime(pkg.source) == t1
        end
    end
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
            Pkg.add(path = path)
            # We check that the package was installed correctly.
            cache, original_master = 0, 0
            Pkg.dependencies(empty_package) do pkg
                @test pkg.name == "EmptyPackage"
                @test isdir(pkg.source)
                @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
                cache = Pkg.Types.add_repo_cache_path(pkg.git_source)
                LibGit2.with(LibGit2.GitRepo(cache)) do repo
                    original_master = string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/$(default_branch)")))
                end
            end
            @test haskey(Pkg.project().dependencies, "EmptyPackage")
            # Now we add a commit upstream, if we fetch unnecessarily, we should be able to see it in our clone.
            write(joinpath(path, "Foo.txt"), "Hello\n")
            new_commit = nothing
            LibGit2.with(LibGit2.GitRepo(path)) do repo
                LibGit2.add!(repo, "*")
                new_commit = string(LibGit2.commit(repo, "new commit"; author = TEST_SIG, committer = TEST_SIG))
            end
            # Use clone to generate source, _without_ unnecessarily updating the clone
            rm(joinpath(DEPOT_PATH[1], "packages"); force = true, recursive = true)
            Pkg.instantiate()
            # check that `master` on the clone has not changed
            Pkg.dependencies(empty_package) do pkg
                @test pkg.name == "EmptyPackage"
                @test isdir(pkg.source)
                @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
                cache = Pkg.Types.add_repo_cache_path(pkg.git_source)
                LibGit2.with(LibGit2.GitRepo(cache)) do repo
                    @test original_master == string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/$(default_branch)")))
                end
            end
            @test haskey(Pkg.project().dependencies, "EmptyPackage")
            # Now we nuke the clones. This will force a fresh clone.
            # We should see `master` on the new clone reflect the new commit.
            rm(joinpath(DEPOT_PATH[1], "packages"); force = true, recursive = true)
            rm(joinpath(DEPOT_PATH[1], "clones"); force = true, recursive = true)
            Pkg.instantiate()
            Pkg.dependencies(empty_package) do pkg
                @test pkg.name == "EmptyPackage"
                @test isdir(pkg.source)
                @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
                cache = Pkg.Types.add_repo_cache_path(pkg.git_source)
                LibGit2.with(LibGit2.GitRepo(cache)) do repo
                    @test new_commit == string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/$(default_branch)")))
                end
            end
            @test haskey(Pkg.project().dependencies, "EmptyPackage")
        end
    end
end

@testset "manifest entry of the active project tracks its deps" begin
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("MyProject")
            Pkg.activate("MyProject")
            uuid = Pkg.Types.read_project(joinpath("MyProject", "Project.toml")).uuid
            manifest() = Pkg.Types.read_manifest(joinpath("MyProject", "Manifest.toml"))
            project_deps() = sort!(collect(keys(manifest()[uuid].deps)))
            Pkg.resolve()
            @test project_deps() == String[]
            # the entry must be updated by the same operation that adds the dep, not the next one
            Pkg.add("JSON")
            @test project_deps() == ["JSON"]
            @test "Unicode" in keys(manifest()[json_uuid].deps)
            Pkg.add("Example")
            @test project_deps() == ["Example", "JSON"]
            # promoting an indirect dep skips resolving entirely
            Pkg.add("Unicode")
            @test project_deps() == ["Example", "JSON", "Unicode"]
            # a stale entry would keep JSON reachable and thus unpruned
            Pkg.rm("JSON")
            @test project_deps() == ["Example", "Unicode"]
            @test !haskey(manifest(), json_uuid)
        end
    end
end

@testset "Issue #2931" begin
    isolate(loaded_depot = false) do
        temp_pkg_dir() do path
            name = "Example"
            version = "0.5.3"
            tree_hash = Base.SHA1("46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc")

            # Install Example.jl
            Pkg.add(; name, version)

            # Force empty version number in the manifest
            ctx = Pkg.Types.Context()
            ctx.env.manifest[exuuid].version = nothing

            # Delete directory where the package would be installed
            pkg_dir = Pkg.Operations.find_installed(name, exuuid, tree_hash)
            rm(pkg_dir; recursive = true, force = true)

            # (Re-)download sources
            Pkg.Operations.download_source(ctx)

            # Make sure the package directory is there
            @test isdir(pkg_dir)
        end
    end
end

@testset "test resolve with tree hash" begin
    isolate() do
        mktempdir() do dir
            path = copy_test_package(dir, "ResolveWithRev")
            cd(path) do
                with_current_env() do
                    @test !isfile("Manifest.toml")
                    @test !isdir(joinpath(DEPOT_PATH[1], "packages", "Example"))
                    Pkg.resolve()
                    @test isdir(joinpath(DEPOT_PATH[1], "packages", "Example"))
                    rm(joinpath(DEPOT_PATH[1], "packages", "Example"); recursive = true)
                    Pkg.resolve()
                end
            end
        end
    end
end

@testset "test instantiate with sources with only rev" begin
    isolate() do
        mktempdir() do dir
            cp(joinpath(@__DIR__, "test_packages", "sources_only_rev", "Project.toml"), joinpath(dir, "Project.toml"))
            cd(dir) do
                with_current_env() do
                    @test !isfile("Manifest.toml")
                    Pkg.instantiate()
                    uuid, info = only(Pkg.dependencies())
                    @test info.git_revision == "ba3d6704f09330ae973773496a4212f85e0ffe45"
                    @test info.git_source == "https://github.com/JuliaLang/Example.jl.git"
                end
            end
        end
    end
end

# Test the readonly functionality
@testset "Readonly Environment Tests" begin
    isolate() do
        cd_tempdir() do dir
            # Activate the environment
            Pkg.activate(".")

            # Test readonly API - should be false initially
            @test Pkg.readonly() == false

            # Add a package (should work fine)
            Pkg.add("Test")

            # Enable readonly mode using new API
            previous_state = Pkg.readonly(true)
            @test previous_state == false
            @test Pkg.readonly() == true

            # Test that status shows readonly indicator
            io = IOBuffer()
            Pkg.status(io = io)
            status_output = String(take!(io))
            @test occursin("(readonly)", status_output)

            # These operations should fail with early readonly check
            @test_throws Pkg.Types.PkgError Pkg.add("Dates")
            @test_throws Pkg.Types.PkgError Pkg.rm("Test")
            @test_throws Pkg.Types.PkgError Pkg.update()
            @test_throws Pkg.Types.PkgError Pkg.pin("Test")
            @test_throws Pkg.Types.PkgError Pkg.free("Test")
            @test_throws Pkg.Types.PkgError Pkg.develop("Example")

            # Disable readonly mode
            previous_state = Pkg.readonly(false)
            @test previous_state == true
            @test Pkg.readonly() == false

            # Test that status no longer shows readonly indicator
            io = IOBuffer()
            Pkg.status(io = io)
            status_output = String(take!(io))
            @test !occursin("(readonly)", status_output)

            # Operations should work again
            @test_nowarn Pkg.add("Random")
            @test_nowarn Pkg.rm("Random")
        end
    end
end

temp_pkg_dir() do project_path
    cd(project_path) do
        tmp = mktempdir()
        depo1 = mktempdir()
        depo2 = mktempdir()
        cd(tmp) do;
            @testset "instantiating updated repo" begin
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depo1)
                Base.append_bundled_depot_path!(DEPOT_PATH)
                LibGit2.close(LibGit2.clone("https://github.com/JuliaLang/Example.jl", "Example.jl"))
                mkdir("machine1")
                cd("machine1")
                Pkg.activate(".")
                Pkg.add(Pkg.PackageSpec(path = "../Example.jl"))
                cd("..")
                cp("machine1", "machine2")
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depo2)
                Base.append_bundled_depot_path!(DEPOT_PATH)
                cd("machine2")
                Pkg.activate(".")
                Pkg.instantiate()
                cd("..")
                cd("Example.jl")
                open("README.md", "a") do io
                    print(io, "Hello")
                end
                LibGit2.with(LibGit2.GitRepo(".")) do repo
                    LibGit2.add!(repo, "*")
                    LibGit2.commit(repo, "changes"; author = TEST_SIG, committer = TEST_SIG)
                end
                cd("../machine1")
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depo1)
                Base.append_bundled_depot_path!(DEPOT_PATH)
                Pkg.activate(".")
                Pkg.update()
                cd("..")
                cp("machine1/Manifest.toml", "machine2/Manifest.toml"; force = true)
                cd("machine2")
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depo2)
                Base.append_bundled_depot_path!(DEPOT_PATH)
                Pkg.activate(".")
                Pkg.instantiate()
            end
        end
        Base.rm.([tmp, depo1, depo2]; force = true, recursive = true)
    end
end

@testset "undo redo functionality" begin
    unicode_uuid = UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5")
    temp_pkg_dir() do project_path
        with_temp_env() do
            Pkg.activate(project_path)
            # Example
            Pkg.add(TEST_PKG.name)
            @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
            #
            Pkg.undo()
            @test !haskey(Pkg.dependencies(), TEST_PKG.uuid)
            # Example
            Pkg.redo()
            # Example, Unicode
            Pkg.add("Unicode")
            @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
            # Example
            Pkg.undo()
            @test !haskey(Pkg.dependencies(), unicode_uuid)
            #
            Pkg.undo()
            @test !haskey(Pkg.dependencies(), TEST_PKG.uuid)
            # Example, Unicode
            Pkg.redo()
            Pkg.redo()
            @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
            @test haskey(Pkg.dependencies(), unicode_uuid)
            # Should not add states since they are nops
            Pkg.add("Unicode")
            Pkg.add("Unicode")
            # Example
            Pkg.undo()
            @test !haskey(Pkg.dependencies(), unicode_uuid)
            # Example, Unicode
            Pkg.redo()
            @test haskey(Pkg.dependencies(), unicode_uuid)

            # Example
            Pkg.undo()

            prev_project = Base.active_project()
            mktempdir() do tmp
                Pkg.activate(tmp)
                Pkg.add("Example")
                Pkg.undo()
                @test !haskey(Pkg.dependencies(), TEST_PKG.uuid)
            end
            Pkg.activate(prev_project)

            # Check that undo state persists after swapping projects
            # Example, Unicode
            Pkg.redo()
            @test haskey(Pkg.dependencies(), unicode_uuid)

        end
    end
end

@testset "subdir functionality" begin
    temp_pkg_dir() do project_path
        with_temp_env() do
            mktempdir() do tmp
                repodir = git_init_package(tmp, joinpath(@__DIR__, "test_packages", "MainRepo"))
                # Add with subdir
                subdir_uuid = UUID("6fe4e069-dcb0-448a-be67-3a8bf3404c58")
                Pkg.add(url = repodir, subdir = "SubDir")
                pkgdir = abspath(joinpath(dirname(Base.find_package("SubDir")), ".."))

                # Update with subdir in manifest
                Pkg.update()
                # Test instantiate with subdir
                rm(pkgdir; recursive = true)
                Pkg.instantiate()
                @test isinstalled("SubDir")
                Pkg.rm("SubDir")

                # Dev of local path with subdir
                Pkg.develop(path = repodir, subdir = "SubDir")
                @test Pkg.dependencies()[subdir_uuid].source == joinpath(repodir, "SubDir")
            end
        end
    end
end

@testset "Issue #3147" begin
    isolate() do

        @testset "Pkg.add" begin
            Pkg.activate(temp = true)
            mktempdir() do tmp_dir
                LibGit2.close(LibGit2.clone("https://github.com/JuliaLang/Example.jl", tmp_dir))
                Pkg.develop(path = tmp_dir)
                Pkg.pin("Example")
                Pkg.add("Example")
                info = Pkg.dependencies()[TEST_PKG.uuid]
                @test info.is_pinned
                @test info.is_tracking_path
                @test !info.is_tracking_repo
                @test info.version > v"0.5.3"
            end
            Pkg.rm("Example")

            Pkg.add(url = "https://github.com/JuliaLang/Example.jl", rev = "29aa1b4")
            Pkg.pin("Example")
            Pkg.add("Example")
            info = Pkg.dependencies()[TEST_PKG.uuid]
            @test info.is_pinned
            @test !info.is_tracking_path
            @test info.is_tracking_repo
            @test info.version == v"0.5.3"
            Pkg.rm("Example")
        end

        @testset "Pkg.update" begin
            Pkg.activate(temp = true)
            mktempdir() do tmp_dir
                ver = v"0.5.3"
                repo = LibGit2.clone("https://github.com/JuliaLang/Example.jl", tmp_dir)
                tag = LibGit2.GitObject(repo, "v$ver")
                hash = string(LibGit2.target(tag))
                LibGit2.checkout!(repo, hash)
                LibGit2.close(repo)
                Pkg.develop(path = tmp_dir)
                Pkg.pin("Example")
                Pkg.update("Example")  # pkg should remain pinned
                info = Pkg.dependencies()[TEST_PKG.uuid]
                @test info.is_pinned
                @test info.is_tracking_path
                @test !info.is_tracking_repo
                @test info.version == ver

                # modify the pkg version manually, to mimic developing this pkg
                dev_ver = VersionNumber(ver.major, ver.minor, ver.patch + 1)
                fn = joinpath(tmp_dir, "Project.toml")
                toml = TOML.parse(read(fn, String))
                toml["version"] = string(dev_ver)
                open(io -> TOML.print(io, toml), fn, "w")
                Pkg.update("Example")  # noop since Pkg.is_fully_pinned(...) is true
                info = Pkg.dependencies()[TEST_PKG.uuid]
                @test info.is_pinned
                @test info.is_tracking_path
                @test !info.is_tracking_repo
                @test info.version == ver

                Pkg.pin("Example")  # pinning a 2ⁿᵈ time updates versions in the manifest
                info = Pkg.dependencies()[TEST_PKG.uuid]
                @test info.is_pinned
                @test info.is_tracking_path
                @test !info.is_tracking_repo
                @test info.version == dev_ver
            end
            Pkg.rm("Example")
        end
    end
end

end # module
