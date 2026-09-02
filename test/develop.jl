module DevelopTests

using Test, UUIDs
import ..Pkg
using Pkg.Types: PkgError
using ..Utils

exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")
unregistered_uuid = UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")
simple_package_uuid = UUID("fc6b7c0f-8a2f-4256-bbf4-8c72c30df5be")

@testset "develop: input checking" begin
    isolate(loaded_depot = true) do
        # Julia is not a valid package name.
        @test_throws PkgError("`julia` is not a valid package name") Pkg.develop(name = "julia")
        # Package names must be valid Julia identifiers.
        @test_throws PkgError("`***` is not a valid package name") Pkg.develop(name = "***")
        @test_throws PkgError("`Foo Bar` is not a valid package name") Pkg.develop(name = "Foo Bar")
        # Names which are invalid and are probably URLs or paths.
        @test_throws PkgError(
            """
            `https://github.com` is not a valid package name
            The argument appears to be a URL or path, perhaps you meant `Pkg.develop(url="...")` or `Pkg.develop(path="...")`."""
        ) Pkg.develop("https://github.com")
        @test_throws PkgError(
            """
            `./Foobar` is not a valid package name
            The argument appears to be a URL or path, perhaps you meant `Pkg.develop(url="...")` or `Pkg.develop(path="...")`."""
        ) Pkg.develop("./Foobar")
        # An empty spec is invalid.
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `develop`"
        ) Pkg.develop(Pkg.PackageSpec())
        # git revisions imply that `develop` tracks a git repo.
        @test_throws PkgError(
            "rev argument not supported by `develop`; consider using `add` instead"
        ) Pkg.develop(name = "Example", rev = "master")
        # Adding an unregistered package by name.
        @test_throws PkgError Pkg.develop("ThisIsHopefullyRandom012856014925701382")
        # Wrong UUID
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec("Example", UUID(UInt128(1))))
        # Missing UUID
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(uuid = uuid4()))
        # Two packages with the same name
        @test_throws PkgError(
            "it is invalid to specify multiple packages with the same UUID: `Example [7876af07]`"
        ) Pkg.develop([(; name = "Example"), (; uuid = exuuid)])
    end
end

@testset "develop: changes to the active project" begin
    # It is possible to `develop` by specifying a registered name.
    isolate(loaded_depot = true) do
        Pkg.develop("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(Pkg.devdir(), "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Develop with shared=false
    isolate(loaded_depot = true) do
        Pkg.develop("Example"; shared = false)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(dirname(Pkg.project().path), "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by specifying a registered UUID.
    isolate(loaded_depot = true) do
        Pkg.develop(uuid = exuuid)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by specifying a URL.
    isolate(loaded_depot = true) do
        Pkg.develop(url = "https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by directly specifying a path.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "SimplePackage")
            path = joinpath(tempdir, "SimplePackage")
            Pkg.develop(path = path)
            Pkg.dependencies(simple_package_uuid) do pkg
                @test pkg.name == "SimplePackage"
                @test realpath(pkg.source) == realpath(path)
                @test !pkg.is_tracking_registry
                @test haskey(pkg.dependencies, "Example")
                @test haskey(pkg.dependencies, "Markdown")
            end
            @test haskey(Pkg.project().dependencies, "SimplePackage")
        end
    end
    # recursive `dev`
    isolate(loaded_depot = true) do
        Pkg.develop(path = joinpath(@__DIR__, "test_packages", "A"))
        Pkg.dependencies(UUID("0829fd7c-1e7e-4927-9afa-b8c61d5e0e42")) do pkg # dep A
            @test haskey(pkg.dependencies, "B")
            @test haskey(pkg.dependencies, "C")
            @test Base.samefile(pkg.source, joinpath(@__DIR__, "test_packages", "A"))
        end
        Pkg.dependencies(UUID("4ee78ca3-4e78-462f-a078-747ed543fa85")) do pkg # dep C
            @test haskey(pkg.dependencies, "D")
            @test Base.samefile(pkg.source, joinpath(@__DIR__, "test_packages", "A", "dev", "C"))
        end
        Pkg.dependencies(UUID("dd0d8fba-d7c4-4f8e-a2bb-3a090b3e34f1")) do pkg # dep B
            @test Base.samefile(pkg.source, joinpath(@__DIR__, "test_packages", "A", "dev", "B"))
        end
        Pkg.dependencies(UUID("bf733257-898a-45a0-b2f2-c1c188bdd879")) do pkg # dep D
            @test Base.samefile(pkg.source, joinpath(@__DIR__, "test_packages", "A", "dev", "D"))
        end
    end
    # primary depot is a relative path
    isolate() do;
        cd_tempdir() do dir
            empty!(DEPOT_PATH)
            push!(DEPOT_PATH, "temp")
            Base.append_bundled_depot_path!(DEPOT_PATH)
            Pkg.develop("JSON")
            Pkg.dependencies(json_uuid) do pkg
                @test Base.samefile(pkg.source, abspath(joinpath("temp", "dev", "JSON")))
            end
        end
    end
end

@testset "develop: interaction with `JULIA_PKG_DEVDIR`" begin
    # A shared `develop` should obey `JULIA_PKG_DEVDIR`.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            withenv("JULIA_PKG_DEVDIR" => tempdir) do
                Pkg.develop("Example")
            end
            Pkg.dependencies(exuuid) do pkg
                @test pkg.name == "Example"
                @test Base.samefile(pkg.source, joinpath(tempdir, "Example"))
            end
            @test haskey(Pkg.project().dependencies, "Example")
        end
    end
    # A local `develop` should not be affected by `JULIA_PKG_DEVDIR`
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            withenv("JULIA_PKG_DEVDIR" => tempdir) do
                Pkg.develop("Example"; shared = false)
            end
            Pkg.dependencies(exuuid) do pkg
                @test pkg.name == "Example"
                @test Base.samefile(pkg.source, joinpath(dirname(Pkg.project().path), "dev", "Example"))
                @test !pkg.is_tracking_registry
            end
            @test haskey(Pkg.project().dependencies, "Example")
        end
    end
end

@testset "develop: path handling" begin
    # Relative paths
    isolate(loaded_depot = true) do
        project_path = dirname(Pkg.project().path)
        mkpath(project_path)
        copy_test_package(project_path, "SimplePackage")
        package_path = joinpath(project_path, "SimplePackage")
        # Now we `develop` using a relative path.
        cd(project_path) do
            Pkg.develop(Pkg.PackageSpec(path = "SimplePackage"))
        end
        # Check that everything went ok.
        original_source = nothing
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test isdir(pkg.source)
            @test Base.samefile(pkg.source, package_path)
            original_source = pkg.source
        end
        # Now we move the project, but preserve the relative structure.
        mktempdir() do tempdir
            cp(project_path, tempdir; force = true)
            Pkg.activate(tempdir)
            # We check that we can still find the source.
            Pkg.dependencies(simple_package_uuid) do pkg
                @test isdir(pkg.source)
                @test Base.samefile(pkg.source, realpath(joinpath(tempdir, "SimplePackage")))
            end
        end
    end
    # Absolute paths
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            copy_test_package(tempdir, "SimplePackage")
            package_path = joinpath(tempdir, "SimplePackage")
            Pkg.activate(tempdir)
            Pkg.develop(path = package_path)
            original_source = nothing
            Pkg.dependencies(simple_package_uuid) do pkg
                @test pkg.name == "SimplePackage"
                @test isdir(pkg.source)
                @test realpath(pkg.source) == realpath(package_path)
                original_source = pkg.source
            end
            mktempdir() do tempdir2
                cp(joinpath(tempdir, "Project.toml"), joinpath(tempdir2, "Project.toml"))
                cp(joinpath(tempdir, "Manifest.toml"), joinpath(tempdir2, "Manifest.toml"))
                Pkg.activate(tempdir2)
                Pkg.dependencies(simple_package_uuid) do pkg
                    @test isdir(pkg.source)
                    @test Base.samefile(pkg.source, original_source)
                end
            end
        end
    end
    # ### Special casing on path handling
    # "." style path
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            cd(path) do
                Pkg.pkg"develop ."
            end
            Pkg.dependencies(simple_package_uuid) do pkg
                @test pkg.name == "SimplePackage"
                @test isdir(pkg.source)
                @test pkg.is_tracking_path
            end
        end
    end
    # ".." style path
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            cd(joinpath(path, "src")) do
                Pkg.pkg"develop .."
            end
            Pkg.dependencies(simple_package_uuid) do pkg
                @test pkg.name == "SimplePackage"
                @test isdir(pkg.source)
                @test pkg.is_tracking_path
            end
        end
    end
    # Local directory name. This must be prepended by "./".
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            cd(dirname(path)) do
                Pkg.pkg"develop ./SimplePackage"
            end
            Pkg.dependencies(simple_package_uuid) do pkg
                @test pkg.name == "SimplePackage"
                @test isdir(pkg.source)
                @test pkg.is_tracking_path
            end
        end
    end
end

@testset "develop: package state changes" begin
    # Developing an existing package which is tracking the registry should just override.
    isolate(loaded_depot = true) do
        Pkg.add("Example")
        Pkg.develop("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # Developing an existing package which is tracking a repo should just override.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", rev = "master")
        Pkg.develop("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # Develop with different target path should override old path with target path.
    isolate(loaded_depot = true) do
        Pkg.develop("Example")
        Pkg.develop("Example"; shared = false)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(dirname(Pkg.project().path), "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # develop tries to resolve from the manifest
    isolate(loaded_depot = true) do
        remote_url = "https://github.com/00vareladavid/Unregistered.jl"
        Pkg.add(Pkg.PackageSpec(url = remote_url))
        Pkg.develop("Unregistered")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
        end
    end
end

@testset "cycles" begin
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("Cycle_A")
            cycle_a_uuid = Pkg.Types.read_project("Cycle_A/Project.toml").uuid
            Pkg.generate("Cycle_B")
            cycle_b_uuid = Pkg.Types.read_project("Cycle_A/Project.toml").uuid
            Pkg.activate("Cycle_A")
            Pkg.develop(Pkg.PackageSpec(path = "Cycle_B"))
            Pkg.activate("Cycle_B")
            Pkg.develop(Pkg.PackageSpec(path = "Cycle_A"))
            manifest_b = Pkg.Types.read_manifest("Cycle_B/Manifest.toml")
            @test cycle_a_uuid in keys(manifest_b)
            @test_broken !(cycle_b_uuid in keys(manifest_b))
        end
    end
end

@testset "not collecting multiple package instances #1570" begin
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            Pkg.generate("B")
            Pkg.activate("B")
            Pkg.develop(Pkg.PackageSpec(path = "A"))
            Pkg.activate(".")
            Pkg.develop(Pkg.PackageSpec(path = "A"))
            Pkg.develop(Pkg.PackageSpec(path = "B"))
        end
    end
end

@testset "cyclic dependency graph" begin
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            Pkg.generate("B")
            Pkg.activate("A")
            Pkg.develop(path = "B")
            git_init_and_commit("A")
            Pkg.activate("B")
            # This shouldn't error even though A has a dependency on B
            Pkg.add(path = "A")
        end
    end
    # test #2302
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            Pkg.generate("B")
            git_init_and_commit("B")
            Pkg.develop(path = "B")
            Pkg.activate("A")
            Pkg.add(path = "B")
            git_init_and_commit("A")
            Pkg.activate("B")
            # This shouldn't error even though A has a dependency on B
            Pkg.add(path = "A")
        end
    end
end

end # module
