module NewTests

using  Test, UUIDs
import Pkg, LibGit2
using  Pkg.Types: PkgError
using  Pkg.Resolve: ResolverError
using  ..Utils

Pkg.DEFAULT_IO[] = IOBuffer()

general_uuid = UUID("23338594-aafe-5451-b93e-139f81909106") # UUID for `General`
exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")
markdown_uuid = UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
test_stdlib_uuid = UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
unicode_uuid = UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5")
unregistered_uuid = UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")
simple_package_uuid = UUID("fc6b7c0f-8a2f-4256-bbf4-8c72c30df5be")

#
# # Depot Changes
#
@testset "Depot setup" begin
    isolate() do
        # Lets make sure we start with a clean slate.
        rm(LOADED_DEPOT; force=true, recursive=true)
        mkdir(LOADED_DEPOT)
        # And set the loaded depot as our working depot.
        empty!(DEPOT_PATH)
        push!(DEPOT_PATH, LOADED_DEPOT)
        # Now we double check we have a clean slate.
        @test isempty(Pkg.dependencies())
        # A simple `add` should set up some things for us:
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.3"))
        # - `General` should be initiated by default.
        regs = Pkg.Registry.status(;as_api=true)
        @test length(regs) == 1
        reg = regs[1]
        @test reg.name == "General"
        @test reg.uuid == general_uuid
        # - The package should be installed correctly.
        source053, source053_time = nothing, nothing
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            source053 = pkg.source
            source053_time = mtime(pkg.source)
        end
        # - The home project was automatically created.
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
        # Now we install the same package at a different version:
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.1"))
        # - Check that the package was installed correctly.
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.5.1"
            @test isdir(pkg.source)
            # - We also check the interaction between the previously intalled version.
            @test pkg.source != source053
        end
        # Now a few more versions:
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.0"))
        Pkg.add(Pkg.PackageSpec(;name="Example"))
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.3"))
        # With similar checks
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.3"
            @test isdir(pkg.source)
        end
        # Now we try adding a second dependency.
        # We repeat the same class of tests.
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"))
        sourcej018 = nothing
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version == v"0.18.0"
            @test isdir(pkg.source)
        end
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.20.0"))
        Pkg.dependencies(json_uuid) do pkg
            @test isdir(pkg.source)
            @test pkg.source != sourcej018
        end
        # Now check packages which track repos instead of registered versions
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl", rev="v0.5.3"))
        Pkg.dependencies(exuuid) do pkg
            @test !pkg.is_tracking_registry
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        Pkg.dependencies(exuuid) do pkg
            @test !pkg.is_tracking_registry
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        # Also check that unregistered packages are installed properly.
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        Pkg.dependencies(unregistered_uuid) do pkg
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        # Check `develop`
        Pkg.develop(Pkg.PackageSpec(;name="Example"))
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source) # TODO check for full git clone, have to implement saving original URL first
        end
        Pkg.develop(Pkg.PackageSpec(;name="JSON"))
        Pkg.dependencies(json_uuid) do pkg
            @test isdir(pkg.source) # TODO check for full git clone, have to implement saving original URL first
        end
        # Check that the original installation was undisturbed.
        regs = Pkg.Registry.status(;as_api=true)
        @test length(regs) == 1
        reg = regs[1]
        @test reg.name == "General"
        @test reg.uuid == general_uuid
        @test mtime(source053) == source053_time
        # Now we clean up so that `isolate` can reuse the loaded depot properly
        rm(joinpath(LOADED_DEPOT, "environments"); force=true, recursive=true)
        rm(joinpath(LOADED_DEPOT, "clones"); force=true, recursive=true)
        rm(joinpath(LOADED_DEPOT, "logs"); force=true, recursive=true)
        rm(joinpath(LOADED_DEPOT, "dev"); force=true, recursive=true)
        for (root, dirs, files) in walkdir(LOADED_DEPOT)
            for file in files
                filepath = joinpath(root, file)
                fmode = filemode(filepath)
                try
                    chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
                catch
                end
            end
        end
    end
end

#
# # Add
#

#
# ## Input Checking
#

# Here we check against invalid input.
@testset "add: input checking" begin
    isolate(loaded_depot=true) do
        # Julia is not a valid package name.
        @test_throws PkgError("`julia` is not a valid package name") Pkg.add(Pkg.PackageSpec(;name="julia"))
        # Package names must be valid Julia identifiers.
        @test_throws PkgError("`***` is not a valid package name") Pkg.add(Pkg.PackageSpec(;name="***"))
        @test_throws PkgError("`Foo Bar` is not a valid package name") Pkg.add(Pkg.PackageSpec(;name="Foo Bar"))
        # Names which are invalid and are probably URLs or paths.
        @test_throws PkgError("""
        `https://github.com` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.add(PackageSpec(url="..."))` or `Pkg.add(PackageSpec(path="..."))`.""") Pkg.add("https://github.com")
        @test_throws PkgError("""
        `./Foobar` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.add(PackageSpec(url="..."))` or `Pkg.add(PackageSpec(path="..."))`.""") Pkg.add("./Foobar")
        # An empty spec is invalid.
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `add`"
            ) Pkg.add(Pkg.PackageSpec())
        # Versions imply that we are tracking a registered version.
        @test_throws PkgError(
            "version specification invalid when tracking a repository: `0.5.0` specified for package `Example`"
            ) Pkg.add(Pkg.PackageSpec(;name="Example", rev="master", version="0.5.0"))
        # Adding an unregistered package
        @test_throws PkgError Pkg.add("ThisIsHopefullyRandom012856014925701382")
        # Wrong UUID
        @test_throws PkgError Pkg.add(Pkg.PackageSpec("Example", UUID(UInt128(1))))
        # Missing UUID
        @test_throws PkgError Pkg.add(Pkg.PackageSpec(uuid = uuid4()))
    end
    # Unregistered UUID in manifest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        package_path = copy_test_package(tempdir, "UnregisteredUUID")
        Pkg.activate(package_path)
        @test_throws PkgError("expected package `Example [142fd7e7]` to be registered") Pkg.add("JSON")

    end end
end

#
# ## Changes to the active project
#

# Here we can use a loaded depot becuase we are only checking changes to the active project.
# We check that `add` supports basic operations on a clean project.
# The package should be added as a direct dependency.
@testset "add: changes to the active project" begin
    # Basic add
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec("Example"))
        Pkg.dependencies(exuuid) do ex
            @test ex.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Basic add by version
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.0"))
        Pkg.dependencies(exuuid) do ex
            @test ex.is_tracking_registry
            @test ex.version == v"0.5.0"
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Basic Add by VersionRange
    #= TODO
    isolate(loaded_depot=true) do
        # TODO this test is leaky. Will version="0.3.0-0.3.2" suffice?
        range = VersionRange("0.3.0-0.3.2")
        Pkg.add(Pkg.PackageSpec(TEST_PKG.name, Pkg.Types.VersionSpec(range)))
        Pkg.dependencies(exuuid) do pkg
            @test pkg.is_tracking_registry
            @test pkg.version in range
        end
        @test Pkg.dependencies()[TEST_PKG.uuid].version == v"0.3.2"
    end
    =#
    # Basic add by URL
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl", rev="v0.5.3"))
        Pkg.dependencies(exuuid) do ex
            @test !ex.is_tracking_registry
            @test ex.git_source == "https://github.com/JuliaLang/Example.jl"
            @test ex.git_revision == "v0.5.3"
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Basic add by git revision
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        Pkg.dependencies(exuuid) do ex
            @test !ex.is_tracking_registry
            @test ex.git_source == "https://github.com/JuliaLang/Example.jl.git"
            @test ex.git_revision == "master"
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Adding stdlibs should work.
    isolate(loaded_depot=true) do
        profile_uuid = UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79")
        # - Adding a stdlib by name.
        Pkg.add("Markdown")
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
        # - Adding a stdlib by UUID.
        Pkg.add(Pkg.PackageSpec(;uuid=profile_uuid))
        Pkg.dependencies(profile_uuid) do pkg
            @test pkg.name == "Profile"
        end
        # - Adding a stdlib by name/UUID.
        Pkg.add(Pkg.PackageSpec(;name="Markdown", uuid=markdown_uuid))
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
    end
    # Basic add by local path.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
        Pkg.add(Pkg.PackageSpec(;path=path))
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.git_source == realpath(path)
            # We take care to check that the project file has been parsed correctly.
            @test pkg.name == "SimplePackage"
            @test pkg.version == v"0.2.0"
            @test haskey(pkg.dependencies, "Example")
            @test haskey(pkg.dependencies, "Markdown")
        end
        @test haskey(Pkg.project().dependencies, "SimplePackage")
        @test length(Pkg.project().dependencies) == 1
    end end
end

# Here we can use a loaded depot becuase we are only checking changes to the active project.
@testset "add: package state changes" begin
    # Check that `add` on an already added stdlib works.
    # Stdlibs are special cased throughtout the codebase.
    isolate(loaded_depot=true) do
        Pkg.add("Markdown")
        Pkg.add("Markdown")
        Pkg.dependencies(markdown_uuid) do pkg
            pkg.name == "Markdown"
        end
        @test haskey(Pkg.project().dependencies, "Markdown")
    end
    # Double add should not change state, this would be an unnecessary change.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add("Example")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
    end
    # Adding a new package should not alter the version of existing packages.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add("Test")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
    end
    # Add by version should not override pinned version.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
            @test ex.ispinned
        end
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.0"))
        # We check that the package state is left unchanged.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
            @test ex.ispinned
        end
    end
    # Add by version should override add by repo.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        # First we check that we are not tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.git_revision == "master"
            @test !ex.is_tracking_registry
        end
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        # We should now be tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.git_revision === nothing
            @test ex.is_tracking_registry
        end
    end
    # Add by version should override add by repo, even for indirect dependencies.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "DependsOnExample"))
        Pkg.add(Pkg.PackageSpec(;path=path))
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        @test !Pkg.dependencies()[exuuid].is_tracking_registry
        # Now we remove the package as a direct dependency.
        # The package should still exist as an indirect dependency becuse `DependsOnExample` depends on it.
        Pkg.rm("Example")
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        # Now we check that we are tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
        end
    end end
    # Add by URL should not override pin.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        Pkg.pin(Pkg.PackageSpec(;name="Example"))
        Pkg.dependencies(exuuid) do ex
            @test ex.ispinned
            @test ex.is_tracking_registry
            @test ex.version == v"0.3.0"
        end
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        Pkg.dependencies(exuuid) do ex
            @test ex.ispinned
            @test ex.is_tracking_registry
            @test ex.version == v"0.3.0"
        end
    end
    # It should be possible to switch branches by reusing the URL.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl", rev="0.2.0"))
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            @test !pkg.is_tracking_registry
            @test pkg.git_revision == "0.2.0"
            # We check that we have the correct branch by checking its dependencies.
            @test haskey(pkg.dependencies, "Example")
        end
        # Now we refer to it by name so to check that we reuse the URL.
        Pkg.add(Pkg.PackageSpec(;name="Unregistered", rev="0.1.0"))
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            @test !pkg.is_tracking_registry
            @test pkg.git_revision == "0.1.0"
            # We check that we have the correct branch by checking its dependencies.
            @test !haskey(pkg.dependencies, "Example")
        end
    end
    # Preserve syntax
    # These tests mostly check the REPL side correctness.
    # - Normal add should not change the existing version.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `tiered` is the default option.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_TIERED)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `all` should succeed in the same way.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_ALL)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `direct` should also succeed in the same way.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_DIRECT)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `semver` should update `Example` to the highest semver compatible version.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_SEMVER)
        @test Pkg.dependencies()[exuuid].version == v"0.3.3"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    #- `none` should update `Example` to the highest compatible version.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_NONE)
        @test Pkg.dependencies()[exuuid].version == v"0.5.3"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
end

#
# ## Repo Handling
#
@testset "add: repo handling" begin
    # Dependencies added with an absolute path should be stored as absolute paths.
    # This tests shows that, packages added with an absolute path will not break
    # if the project is moved to a new position.
    # We can use the loaded depot here, it will help us avoid the original clone.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
        path = abspath(path)
        Pkg.add(Pkg.PackageSpec(;path=path))
        # Now we try to find the package.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        @test !isdir(Pkg.dependencies()[empty_package].source)
        Pkg.instantiate()
        @test isdir(Pkg.dependencies()[empty_package].source)
        # Now we move the project and should still be able to find the package.
        mktempdir() do other_dir
            cp(dirname(Base.active_project()), other_dir; force=true)
            Pkg.activate(other_dir)
            rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
            @test !isdir(Pkg.dependencies()[empty_package].source)
            Pkg.instantiate()
        end
    end end
    # Dependencies added with relative paths should be stored relative to the active project.
    # This test shows that packages added with a relative path will not break
    # as long as they maintain the same relative position to the project.
    # We can use the loaded depot here, it will help us avoid the original clone.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
        # We add the package using a relative path.
        cd(path) do
            Pkg.add(Pkg.PackageSpec(;path="."))
        end
        # Now we try to find the package.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        Pkg.instantiate()
        # Now we destroy the relative position and should not be able to find the package.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        mktempdir() do other_dir
            cp(dirname(Base.active_project()), other_dir; force=true)
            Pkg.activate(other_dir)
            @test_throws PkgError Pkg.instantiate() # TODO is there a way to pattern match on just part of the err message?
        end
    end end
    # Now we test packages added by URL.
    isolate(loaded_depot=true) do
        # Details: `master` is past `0.1.0`
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl", rev="0.1.0"))
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test isdir(pkg.source)
        end
        @test haskey(Pkg.project().dependencies, "Unregistered")
        # Now we remove the source so that we have to load it again.
        # We should reuse the existing clone in this case.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        Pkg.instantiate()
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test isdir(pkg.source)
        end
        @test haskey(Pkg.project().dependencies, "Unregistered")
        # Now we remove the source _and_ our cache, we have no choice to re-clone the remote.
        # We should still be able to find the source.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        rm(joinpath(DEPOT_PATH[1], "clones"); recursive=true)
        Pkg.instantiate()
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test isdir(pkg.source)
        end
        @test haskey(Pkg.project().dependencies, "Unregistered")
    end
end

#
# ## Resolve tiers
#
@testset "add: resolve tiers" begin
    isolate(loaded_depot=true) do; mktempdir() do tmp
        # All
        copy_test_package(tmp, "ShouldPreserveAll"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveAll"))
        parsers_uuid = UUID("69de0a69-1ddd-5017-9359-2bf0b02dc9f0")
        original_parsers_version = Pkg.dependencies()[parsers_uuid].version
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.0"))
        @test Pkg.dependencies()[parsers_uuid].version == original_parsers_version
        # Direct
        copy_test_package(tmp, "ShouldPreserveDirect"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveDirect"))
        ordered_collections = UUID("bac558e1-5e72-5ebc-8fee-abe8a469f55d")
        Pkg.add(Pkg.PackageSpec(;uuid=ordered_collections, version="1.0.1"))
        lazy_json = UUID("fc18253b-5e1b-504c-a4a2-9ece4944c004")
        data_structures = UUID("864edb3b-99cc-5e75-8d2d-829cb0a9cfe8")
        @test Pkg.dependencies()[lazy_json].version == v"0.1.0" # stayed the same
        @test Pkg.dependencies()[data_structures].version == v"0.16.1" # forced to change
        @test Pkg.dependencies()[ordered_collections].version == v"1.0.1" # sanity check
        # SEMVER
        copy_test_package(tmp, "ShouldPreserveSemver"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveSemver"))
        light_graphs = UUID("093fc24a-ae57-5d10-9952-331d41423f4d")
        meta_graphs = UUID("626554b9-1ddb-594c-aa3c-2596fe9399a5")
        light_graphs_version = Pkg.dependencies()[light_graphs].version
        Pkg.add(Pkg.PackageSpec(;uuid=meta_graphs, version="0.6.4"))
        @test Pkg.dependencies()[meta_graphs].version == v"0.6.4" # sanity check
        # did not break semver
        @test Pkg.dependencies()[light_graphs].version in Pkg.Types.semver_spec("$(light_graphs_version)") 
        # did change version
        @test Pkg.dependencies()[light_graphs].version != light_graphs_version
        # NONE
        copy_test_package(tmp, "ShouldPreserveNone"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveNone"))
        array_interface = UUID("4fba245c-0d91-5ea0-9b3e-6abc04ee57a9")
        diff_eq_diff_tools = UUID("01453d9d-ee7c-5054-8395-0335cb756afa")
        Pkg.add(Pkg.PackageSpec(;uuid=diff_eq_diff_tools, version="1.0.0"))
        @test Pkg.dependencies()[diff_eq_diff_tools].version == v"1.0.0" # sanity check
        @test Pkg.dependencies()[array_interface].version in Pkg.Types.semver_spec("1") # had to make breaking change
    end end
end

#
# ## REPL
#
@testset "add: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        # Add using UUID syntax
        api, args, opts = first(Pkg.pkg"add 7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;uuid=UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # Add using `name=UUID` syntax.
        api, args, opts = first(Pkg.pkg"add Example=7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example", uuid=UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # Add using git revision syntax.
        api, args, opts = first(Pkg.pkg"add Example#master")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example", rev="master")]
        @test isempty(opts)
        # Add using git revision syntax.
        api,args, opt = first(Pkg.pkg"add Example#v0.5.3")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example", rev="v0.5.3")]
        @test isempty(opts)
        # Add using registered version syntax.
        api, args, opts = first(Pkg.pkg"add Example@0.5.0")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example", version="0.5.0")]
        @test isempty(opts)
        # Add using direct URL syntax.
        api, args, opts = first(Pkg.pkg"add https://github.com/00vareladavid/Unregistered.jl#0.1.0")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl", rev="0.1.0")]
        @test isempty(opts)
        # Add using preserve option
        api, args, opts = first(Pkg.pkg"add --preserve=none Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_NONE)
        api, args, opts = first(Pkg.pkg"add --preserve=semver Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_SEMVER)
        api, args, opts = first(Pkg.pkg"add --preserve=tiered Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_TIERED)
        api, args, opts = first(Pkg.pkg"add --preserve=all Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_ALL)
        api, args, opts = first(Pkg.pkg"add --preserve=direct Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_DIRECT)
    end
end

#
# # Develop
#

#
# ## Input Checking
#
@testset "develop: input checking" begin
    isolate(loaded_depot=true) do
        # Julia is not a valid package name.
        @test_throws PkgError("`julia` is not a valid package name") Pkg.develop(Pkg.PackageSpec(;name="julia"))
        # Package names must be valid Julia identifiers.
        @test_throws PkgError("`***` is not a valid package name") Pkg.develop(Pkg.PackageSpec(;name="***"))
        @test_throws PkgError("`Foo Bar` is not a valid package name") Pkg.develop(Pkg.PackageSpec(;name="Foo Bar"))
        # Names which are invalid and are probably URLs or paths.
        @test_throws PkgError("""
        `https://github.com` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.develop(PackageSpec(url="..."))` or `Pkg.develop(PackageSpec(path="..."))`.""") Pkg.develop("https://github.com")
        @test_throws PkgError("""
        `./Foobar` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.develop(PackageSpec(url="..."))` or `Pkg.develop(PackageSpec(path="..."))`.""") Pkg.develop("./Foobar")
        # An empty spec is invalid.
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `develop`"
            ) Pkg.develop(Pkg.PackageSpec())
        # git revisions imply that `develop` tracks a git repo.
        @test_throws PkgError(
            "git revision specification invalid when calling `develop`: `master` specified for package `Example`"
            ) Pkg.develop(Pkg.PackageSpec(;name="Example", rev="master"))
        # Adding an unregistered package by name.
        @test_throws PkgError Pkg.develop("ThisIsHopefullyRandom012856014925701382")
        # Wrong UUID
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec("Example", UUID(UInt128(1))))
        # Missing UUID
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(uuid = uuid4()))
    end
end

#
# ## Changes to the project
#
@testset "develop: changes to the active project" begin
    # It is possible to `develop` by specifying a registered name.
    isolate(loaded_depot=true) do
        Pkg.develop("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(Pkg.devdir(), "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Develop with shared=false
    isolate(loaded_depot=true) do
        Pkg.develop("Example"; shared=false)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(dirname(Pkg.project().path), "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by specifying a registered UUID.
    isolate(loaded_depot=true) do
        Pkg.develop(Pkg.PackageSpec(;uuid=exuuid))
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(DEPOT_PATH[1], "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by specifying a URL.
    isolate(loaded_depot=true) do
        Pkg.develop(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(DEPOT_PATH[1], "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by directly specifying a path.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "SimplePackage")
        path = joinpath(tempdir, "SimplePackage")
        Pkg.develop(Pkg.PackageSpec(;path=path))
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test realpath(pkg.source) == realpath(path)
            @test !pkg.is_tracking_registry
            @test haskey(pkg.dependencies, "Example")
            @test haskey(pkg.dependencies, "Markdown")
        end
        @test haskey(Pkg.project().dependencies, "SimplePackage")
    end end
end

@testset "develop: interaction with `JULIA_PKG_DEVDIR`" begin
    # A shared `develop` should obey `JULIA_PKG_DEVDIR`.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        withenv("JULIA_PKG_DEVDIR" => tempdir) do
            Pkg.develop("Example")
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(tempdir, "Example")
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end end
    # A local `develop` should not be affected by `JULIA_PKG_DEVDIR`
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        withenv("JULIA_PKG_DEVDIR" => tempdir) do
            Pkg.develop("Example"; shared=false)
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(dirname(Pkg.project().path), "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end end
end

@testset "develop: path handling" begin
    # Relative paths
    isolate(loaded_depot=true) do
        project_path = dirname(Pkg.project().path)
        mkpath(project_path)
        copy_test_package(project_path, "SimplePackage")
        package_path = joinpath(project_path, "SimplePackage")
        # Now we `develop` using a relative path.
        cd(project_path) do
            Pkg.develop(Pkg.PackageSpec(path="SimplePackage"))
        end
        # Check that everything went ok.
        original_source = nothing
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test isdir(pkg.source)
            @test pkg.source == package_path
            original_source = pkg.source
        end
        # Now we move the project, but preserve the relative structure.
        mktempdir() do tempdir
            cp(project_path, tempdir; force=true)
            Pkg.activate(tempdir)
            # We check that we can still find the source.
            Pkg.dependencies(simple_package_uuid) do pkg
                @test isdir(pkg.source)
                @test pkg.source == realpath(joinpath(tempdir, "SimplePackage"))
            end
        end
    end
    # Absolute paths
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "SimplePackage")
        package_path = joinpath(tempdir, "SimplePackage")
        Pkg.activate(tempdir)
        Pkg.develop(Pkg.PackageSpec(;path=package_path))
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
                @test pkg.source == original_source
            end
        end
    end end
    # ### Special casing on path handling
    # "." style path
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        cd(path) do
            Pkg.pkg"develop ."
        end
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test isdir(pkg.source)
            @test pkg.isdeveloped
        end
    end end
    # ".." style path
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        cd(joinpath(path, "src")) do
            Pkg.pkg"develop .."
        end
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test isdir(pkg.source)
            @test pkg.isdeveloped
        end
    end end
    # bare directory name
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        cd(dirname(path)) do
            Pkg.pkg"develop SimplePackage"
        end
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test isdir(pkg.source)
            @test pkg.isdeveloped
        end
    end end
end

@testset "develop: package state changes" begin
    # Developing an existing package which is tracking the registry should just override.
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        Pkg.develop("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(DEPOT_PATH[1], "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # Developing an existing package which is tracking a repo should just override.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        Pkg.develop("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(DEPOT_PATH[1], "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # Develop with different target path should override old path with target path.
    isolate(loaded_depot=true) do
        Pkg.develop("Example")
        Pkg.develop("Example"; shared=false)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.source == joinpath(dirname(Pkg.project().path), "dev", "Example")
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # develop tries to resolve from the manifest
    isolate(loaded_depot=true) do
        remote_url = "https://github.com/00vareladavid/Unregistered.jl"
        Pkg.add(Pkg.PackageSpec(url=remote_url))
        Pkg.develop("Unregistered")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
        end
    end
end

#
# ## REPL
#
@testset "develop: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        # registered name
        api, args, opts = first(Pkg.pkg"develop Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test isempty(opts)
        # registered uuid
        api, args, opts = first(Pkg.pkg"develop 7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;uuid=UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # name=uuid
        api, args, opts = first(Pkg.pkg"develop Example=7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;name="Example", uuid=UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # local flag
        api, args, opts = first(Pkg.pkg"develop --local Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:shared => false)
        # shared flag
        api, args, opts = first(Pkg.pkg"develop --shared Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:shared => true)
        # URL
        api, args, opts = first(Pkg.pkg"develop https://github.com/JuliaLang/Example.jl")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl")]
        @test isempty(opts)
    end
end

#
# # Instantiate
#
@testset "instantiate: input checking" begin
    # Unregistered UUID in manifest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        package_path = copy_test_package(tempdir, "UnregisteredUUID")
        Pkg.activate(package_path)
        @test_throws PkgError("expected package `Example [142fd7e7]` to be registered") Pkg.update()
    end end
end

@testset "instantiate: changes to the active project" begin
    # Instantiate should preserve tree hash for regularly versioned packages.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        th = nothing
        Pkg.dependencies(exuuid) do pkg
            th = pkg.tree_hash
            @test pkg.name == "Example"
            @test pkg.version == v"0.3.0"
            @test isdir(pkg.source)
        end
        rm(joinpath(DEPOT_PATH[1], "packages"); force=true, recursive=true)
        rm(joinpath(DEPOT_PATH[1], "clones"); force=true, recursive=true)
        Pkg.instantiate()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.version == v"0.3.0"
            @test isdir(pkg.source)
            @test pkg.tree_hash == th
        end
    end
    # `instantiate` should preserve tree hash for packages tracking repos.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="v0.5.3"))
        th = nothing
        Pkg.dependencies(exuuid) do pkg
            th = pkg.tree_hash
            @test pkg.name == "Example"
            @test isdir(pkg.source)
        end
        rm(joinpath(DEPOT_PATH[1], "packages"); force=true, recursive=true)
        rm(joinpath(DEPOT_PATH[1], "clones"); force=true, recursive=true)
        Pkg.instantiate()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test isdir(pkg.source)
        end
    end
    # `instantiate` should check for a consistent dependency graph.
    # Otherwise it is not clear what to instantiate.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "ExtraDirectDep")
        Pkg.activate(joinpath(tempdir, "ExtraDirectDep"))
        @test_throws PkgError Pkg.instantiate()
    end end
    # However, if `manifest=false`, we know to instantiate from the direct dependencies.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "ExtraDirectDep")
        Pkg.activate(joinpath(tempdir, "ExtraDirectDep"))
        Pkg.instantiate(;manifest=false)
        @test haskey(Pkg.project().dependencies, "Example")
        @test haskey(Pkg.project().dependencies, "Unicode")
    end end
    # `instantiate` lonely manfiest
    isolate(loaded_depot=true) do
        manifest_dir = joinpath(@__DIR__, "manifest", "noproject")
        cd(manifest_dir) do
            try
                Pkg.activate(".")
                Pkg.instantiate()
                @test Base.active_project() == abspath("Project.toml")
                @test isinstalled("Example")
                @test isinstalled("x1")
            finally
                rm("Project.toml"; force=true)
            end
        end
    end
    # `instantiate` on a lonely manifest should detect duplicate names
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        simple_package_path = copy_test_package(tempdir, "SimplePackage")
        unregistered_example_path = copy_test_package(tempdir, "Example")
        Pkg.develop(Pkg.PackageSpec(;path=simple_package_path))
        Pkg.develop(Pkg.PackageSpec(;path=unregistered_example_path))
        rm(Pkg.project().path)
        @test_throws PkgError Pkg.instantiate()
    end end
    # verbose smoke test
    isolate(loaded_depot=true) do
        Pkg.instantiate(;verbose=true)
    end
end

@testset "instantiate: caching" begin
    # Instantiate should not override existing source.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
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

#
# ## REPL
#
@testset "instantiate: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"instantiate --verbose")
        @test api == Pkg.instantiate
        @test opts == Dict(:verbose => true)
        api, opts = first(Pkg.pkg"instantiate -v")
        @test api == Pkg.instantiate
        @test opts == Dict(:verbose => true)
    end
end

#
# # Update
#
@testset "update: input checking" begin
    # Unregistered UUID in manifest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        package_path = copy_test_package(tempdir, "UnregisteredUUID")
        Pkg.activate(package_path)
        @test_throws PkgError("expected package `Example [142fd7e7]` to be registered") Pkg.update()
    end end
    # package does not exist in the manifest
    isolate(loaded_depot=true) do
        @test_throws PkgError Pkg.update("Example")
    end
end

@testset "update: changes to the active project" begin
    # Basic testing of UPLEVEL
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.update(; level = Pkg.UPLEVEL_FIXED)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.update(; level = Pkg.UPLEVEL_PATCH)
        @test Pkg.dependencies()[exuuid].version == v"0.3.3"
        Pkg.update(; level = Pkg.UPLEVEL_MINOR)
        @test Pkg.dependencies()[exuuid].version.minor != 3
    end
    # `update` should prune manifest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "Unpruned")
        Pkg.activate(joinpath(tempdir, "Unpruned"))
        Pkg.update()
        @test haskey(Pkg.project().dependencies, "Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version > v"0.4.0"
        end
        @test !haskey(Pkg.dependencies(), unicode_uuid)
    end end
    # `up` should work without a manifest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "SimplePackage")
        Pkg.activate(joinpath(tempdir, "SimplePackage"))
        Pkg.update()
        @test haskey(Pkg.project().dependencies, "Example")
        @test haskey(Pkg.project().dependencies, "Markdown")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_tracking_registry
        end
    end end
end

@testset "update: package state changes" begin
    # basic update on old registered package
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        Pkg.update()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.version > v"0.3.0"
        end
    end
    # `update` should not update `pin`ed packages
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example",version="0.3.0"))
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.ispinned
            @test pkg.version == v"0.3.0"
        end
        Pkg.update()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.ispinned
            @test pkg.version == v"0.3.0"
        end
    end
    # stdlib special casing
    isolate(loaded_depot=true) do
        Pkg.add("Markdown")
        Pkg.update()
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
    end
    # up should not affect `dev` packages
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        Pkg.develop(Pkg.PackageSpec(;path=path))
        state = Pkg.dependencies()[simple_package_uuid]
        Pkg.update()
        @test Pkg.dependencies()[simple_package_uuid] == state
    end end
    # up and packages tracking repos
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
        Pkg.add(Pkg.PackageSpec(;path=path))
        # test everything went ok
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test pkg.version == v"0.2.0"
            @test haskey(pkg.dependencies, "Example")
            @test haskey(pkg.dependencies, "Markdown")
            @test !haskey(pkg.dependencies, "Unicode")
        end
        simple_package_node = Pkg.dependencies()[simple_package_uuid]
        # now we bump the remote veresion
        mv(joinpath(path, "Project2.toml"), joinpath(path, "Project.toml"); force=true)
        new_commit = nothing
        LibGit2.with(LibGit2.GitRepo(path)) do repo
            LibGit2.add!(repo, "*")
            new_commit = string(LibGit2.commit(repo, "bump version"; author=TEST_SIG, committer=TEST_SIG))
        end
        # update with UPLEVEL != UPLEVEL_MAJOR should not update packages tracking repos
        Pkg.update(; level=Pkg.UPLEVEL_MINOR)
        @test simple_package_node == Pkg.dependencies()[simple_package_uuid]
        Pkg.update(; level=Pkg.UPLEVEL_PATCH)
        @test simple_package_node == Pkg.dependencies()[simple_package_uuid]
        Pkg.update(; level=Pkg.UPLEVEL_FIXED)
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
    end end
    # make sure that we preserve the state of packages which are not the target
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        Pkg.develop("Example")
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"))
        Pkg.add("Markdown")
        Pkg.add("Unicode")
        Pkg.update("Unicode")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test pkg.git_revision == "master"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.isdeveloped
        end
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.name == "JSON"
            @test pkg.version == v"0.18.0"
            @test pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Markdown")
        @test haskey(Pkg.project().dependencies, "Unicode")
    end
end

@testset "update: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"up")
        @test api == Pkg.update
        @test isempty(opts)
    end
end

@testset "update: caching" begin
    # `up` should detect broken local packages
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
        Pkg.add(Pkg.PackageSpec(;path=path))
        rm(joinpath(path, ".git"); force=true, recursive=true)
        @test_throws PkgError Pkg.update()
    end end
end

#
# # Pin
#
@testset "pin: input checking" begin
    # a package must exist in the dep graph in order to be pinned
    isolate(loaded_depot=true) do
        @test_throws PkgError Pkg.pin("Example")
    end
    # pinning to an arbritrary version should check for unregistered packages
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        @test_throws PkgError("unable to pin unregistered package `Unregistered [dcb67f36]` to an arbritrary version"
                              ) Pkg.pin(Pkg.PackageSpec(;name="Unregistered", version="0.1.0"))
    end
    # pinning to an abritrary version should check version exists
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example",rev="master"))
        @test_throws ResolverError Pkg.pin(Pkg.PackageSpec(;name="Example",version="100.0.0"))
    end
end

@testset "pin: package state changes" begin
    # regular registered package
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(; name="Example", version="0.3.3"))
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.ispinned
        end
    end
    # packge tracking repo
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        Pkg.pin("Unregistered")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test !pkg.is_tracking_registry
            @test pkg.ispinned
        end
    end
    # versioned pin
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(; name="Example", version="0.3.3"))
        Pkg.pin(Pkg.PackageSpec(; name="Example", version="0.5.1"))
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.ispinned
        end
    end
    # pin should check for a valid version number
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        @test_throws ResolverError Pkg.pin(Pkg.PackageSpec(;name="Example",version="100.0.0")) # TODO maybe make a PkgError
    end
end

#
# # Free
#
@testset "free: input checking" begin
    # free checks for exisiting packge
    isolate(loaded_depot=true) do
        @test_throws PkgError Pkg.free("Example")
    end
    # free checks for unpinned package
    isolate(loaded_depot=true) do
        Pkg.add("Unicode")
        @test_throws PkgError(string("expected package `Unicode [4ec0a83e]` to be",
                                     " pinned, tracking a path, or tracking a repository"
                                     )) Pkg.free("Unicode")
    end
end

@testset "free: package state changes" begin
    # free pinned package
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        Pkg.pin("Example")
        Pkg.free("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test !pkg.ispinned
        end
    end
    # free package tracking repo
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(; name="Example", rev="master"))
        Pkg.free("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_tracking_registry
        end
    end
    # free developed packge
    isolate(loaded_depot=true) do
        Pkg.develop("Example")
        Pkg.free("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_tracking_registry
        end
    end
    # free should error when called on packages tracking unregistered packages
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        @test_throws PkgError("unable to free unregistered package `Unregistered [dcb67f36]`") Pkg.free("Unregistered")
    end
    isolate(loaded_depot=true) do
        Pkg.develop(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        @test_throws PkgError("unable to free unregistered package `Unregistered [dcb67f36]`") Pkg.free("Unregistered")
    end
end

#
# ## REPL commands
#
@testset "free: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"free Example")
        @test api == Pkg.free
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test isempty(opts)
    end
end

#
# # Resolve
#
@testset "resolve" begin
    # resolve should ignore `extras`
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        package_path = copy_test_package(tempdir, "TestTarget")
        Pkg.activate(package_path)
        Pkg.resolve()
        @test !haskey(Pkg.dependencies(), markdown_uuid)
        @test !haskey(Pkg.dependencies(), test_stdlib_uuid)
    end end
end

#
# # Test
#
@testset "test" begin
    # stdlib special casing
    isolate(loaded_depot=true) do
        Pkg.add("UUIDs")
        Pkg.test("UUIDs")
    end
    # test args smoketest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "TestArguments")
        Pkg.activate(joinpath(tempdir, "TestArguments"))
        # test the old code path (no test/Project.toml)
        Pkg.test("TestArguments"; test_args=`a b`, julia_args=`--quiet --check-bounds=no`)
        Pkg.test("TestArguments"; test_args=["a", "b"], julia_args=["--quiet", "--check-bounds=no"])
        # test new code path
        touch(joinpath(tempdir, "TestArguments", "test", "Project.toml"))
        Pkg.test("TestArguments"; test_args=`a b`, julia_args=`--quiet --check-bounds=no`)
        Pkg.test("TestArguments"; test_args=["a", "b"], julia_args=["--quiet", "--check-bounds=no"])
    end end
end

#
# # rm
#
@testset "rm" begin
    # simple rm
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        Pkg.rm("Example")
        @test isempty(Pkg.project().dependencies)
        @test isempty(Pkg.dependencies())
    end
    # remove should not alter other dependencies
    isolate(loaded_depot=true) do
        Pkg.add([Pkg.PackageSpec(;name="Example"),
                 Pkg.PackageSpec(;name="JSON", version="0.18.0"),])
        json = Pkg.dependencies()[json_uuid]
        Pkg.rm("Example")
        @test Pkg.dependencies()[json_uuid] == json
        @test haskey(Pkg.project().dependencies, "JSON")
    end
    # rm should remove unused compat entries
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "BasicCompat")
        Pkg.activate(path)
        # TODO interface for `compat`
        @test haskey(Pkg.Types.Context().env.project.compat, "Example")
        @test haskey(Pkg.Types.Context().env.project.compat, "julia")
        Pkg.rm("Example")
        @test !haskey(Pkg.Types.Context().env.project.compat, "Example")
        @test haskey(Pkg.Types.Context().env.project.compat, "julia")
    end end
    # rm removes unused recursive depdencies
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        Pkg.develop(Pkg.PackageSpec(;path=path))
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"))
        Pkg.rm("SimplePackage")
        @test haskey(Pkg.dependencies(), markdown_uuid)
        @test !haskey(Pkg.dependencies(), simple_package_uuid)
        @test !haskey(Pkg.dependencies(), exuuid)
        @test haskey(Pkg.dependencies(), json_uuid)
    end end
end

@testset "rm: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"rm Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"rm --project Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:mode => Pkg.PKGMODE_PROJECT)
        api, args, opts = first(Pkg.pkg"rm --manifest Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:mode => Pkg.PKGMODE_MANIFEST)
    end
end

#
# # build
#
@testset "build" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"build")
        @test api == Pkg.build
        @test isempty(args)
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"build Example")
        @test api == Pkg.build
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"build --verbose")
        @test api == Pkg.build
        @test isempty(args)
        @test opts == Dict(:verbose => true)
        api, args, opts = first(Pkg.pkg"build -v Foo Bar")
        @test api == Pkg.build
        @test args == [Pkg.PackageSpec(;name="Foo"), Pkg.PackageSpec(;name="Bar")]
        @test opts == Dict(:verbose => true)
    end
end

#
# # GC
#
@testset "gc" begin
    # REPL
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"gc")
        @test api == Pkg.gc
        @test isempty(opts)
    end
end

#
# # precompile
#
@testset "precompile" begin
    # REPL
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"precompile")
        @test api == Pkg.precompile
        @test isempty(opts)
    end
    # smoke test
    isolate() do
        Pkg.precompile()
    end
end


#
# # generate
#
@testset "generate" begin
    # REPL
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, arg, opts = first(Pkg.pkg"generate Foo")
        @test api == Pkg.generate
        @test arg == "Foo"
        @test isempty(opts)
    end
end

#
# # Caching
#
@testset "Repo caching" begin
    # Add by URL should not overwrite files.
    isolate(loaded_depot=true) do
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        s1, t1, c1 = 0, 0, 0
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            s1 = pkg.source
            c1 = Pkg.Types.add_repo_cache_path(pkg.git_source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            t1 = mtime(pkg.source)
        end
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            @test pkg.source == s1
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            @test Pkg.Types.add_repo_cache_path(pkg.git_source) == c1
            @test mtime(pkg.source) == t1
        end
    end
    # Add by URL should not overwrite files, even across projects
    isolate(loaded_depot=true) do
        # Make sure we have everything downloaded
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        s1, t1, c1 = 0, 0, 0
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            s1 = pkg.source
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            c1 = Pkg.Types.add_repo_cache_path(pkg.git_source)
            t1 = mtime(pkg.source)
        end
        # Now we activate a new project and make sure it is clean.
        Pkg.activate("Foo"; shared=true)
        @test isempty(Pkg.project().dependencies)
        @test isempty(Pkg.dependencies())
        # Finally, add the same URL, we should reuse the existing directories.
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            @test pkg.source == s1
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            @test Pkg.Types.add_repo_cache_path(pkg.git_source) == c1
            @test mtime(pkg.source) == t1
        end
    end
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
        Pkg.add(Pkg.PackageSpec(;path=path))
        # We check that the package was installed correctly.
        cache, original_master = 0, 0
        Pkg.dependencies(empty_package) do pkg
            @test pkg.name == "EmptyPackage"
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            cache = Pkg.Types.add_repo_cache_path(pkg.git_source)
            LibGit2.with(LibGit2.GitRepo(cache)) do repo
                original_master = string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/master")))
            end
        end
        @test haskey(Pkg.project().dependencies, "EmptyPackage")
        # Now we add a commit upstream, if we fetch uneccesarily, we should be able to see it in our clone.
        write(joinpath(path, "Foo.txt"), "Hello\n")
        new_commit = nothing
        LibGit2.with(LibGit2.GitRepo(path)) do repo
            LibGit2.add!(repo, "*")
            new_commit = string(LibGit2.commit(repo, "new commit"; author=TEST_SIG, committer=TEST_SIG))
        end
        # Use clone to generate source, _without_ unecessarily updating the clone
        rm(joinpath(DEPOT_PATH[1], "packages"); force=true, recursive=true)
        Pkg.instantiate()
        # check that `master` on the clone has not changed
        Pkg.dependencies(empty_package) do pkg
            @test pkg.name == "EmptyPackage"
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            cache = Pkg.Types.add_repo_cache_path(pkg.git_source)
            LibGit2.with(LibGit2.GitRepo(cache)) do repo
                @test original_master == string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/master")))
            end
        end
        @test haskey(Pkg.project().dependencies, "EmptyPackage")
        # Now we nuke the clones. This will force a fresh clone.
        # We should see `master` on the new clone reflect the new commit.
        rm(joinpath(DEPOT_PATH[1], "packages"); force=true, recursive=true)
        rm(joinpath(DEPOT_PATH[1], "clones"); force=true, recursive=true)
        Pkg.instantiate()
        Pkg.dependencies(empty_package) do pkg
            @test pkg.name == "EmptyPackage"
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            cache = Pkg.Types.add_repo_cache_path(pkg.git_source)
            LibGit2.with(LibGit2.GitRepo(cache)) do repo
                @test new_commit == string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/master")))
            end
        end
        @test haskey(Pkg.project().dependencies, "EmptyPackage")
    end end
end

#
# # Project files
#
@testset "project files" begin
    # reading corrupted project files
    isolate(loaded_depot=true) do
        dir = joinpath(@__DIR__, "project", "bad")
        for bad_project in joinpath.(dir, readdir(dir))
            @test_throws PkgError Pkg.Types.read_project(bad_project)
        end
    end
    # reading corrupted manifest files
    isolate(loaded_depot=true) do
        dir = joinpath(@__DIR__, "manifest", "bad")
        for bad_manifest in joinpath.(dir, readdir(dir))
            @test_throws PkgError Pkg.Types.read_manifest(bad_manifest)
        end
    end
    # manifest read/write
    isolate() do # TODO rewrite using IOBuffer
        manifestdir = joinpath(@__DIR__, "manifest", "good")
        temp = joinpath(mktempdir(), "x.toml")
        for testfile in joinpath.(manifestdir, readdir(manifestdir))
            a = Pkg.Types.read_manifest(testfile)
            Pkg.Types.write_manifest(a, temp)
            b = Pkg.Types.read_manifest(temp)
            for (uuid, x) in a
                y = b[uuid]
                for property in propertynames(x)
                    # `other` caches the *whole* input dictionary. its ok to mutate the fields of
                    # the input dictionary if that field will eventually be overwriten on `write_manifest`
                    property == :other && continue
                    @test getproperty(x, property) == getproperty(y, property)
                end
            end
        end
        rm(dirname(temp); recursive = true, force = true)
    end
    # project read/write
    isolate() do
        projectdir = joinpath(@__DIR__, "project", "good")
        temp = joinpath(mktempdir(), "x.toml")
        for testfile in joinpath.(projectdir, readdir(projectdir))
            a = Pkg.Types.read_project(testfile)
            Pkg.Types.write_project(a, temp)
            b = Pkg.Types.read_project(temp)
            for property in propertynames(a)
                @test getproperty(a, property) == getproperty(b, property)
            end
        end
        rm(dirname(temp); recursive = true, force = true)
    end
    # canonicalized relative paths in manifest
    isolate() do
        mktempdir() do tmp; cd(tmp) do
            write("Manifest.toml",
                """
                [[Foo]]
                path = "bar/Foo"
                uuid = "824dc81a-29a7-11e9-3958-fba342a32644"
                version = "0.1.0"
                """)
            manifest = Pkg.Types.read_manifest("Manifest.toml")
            package = manifest[Base.UUID("824dc81a-29a7-11e9-3958-fba342a32644")]
            @test package.path == (Sys.iswindows() ? "bar\\Foo" : "bar/Foo")
            Pkg.Types.write_manifest(manifest, "Manifest.toml")
            @test occursin("path = \"bar/Foo\"", read("Manifest.toml", String))
        end end
    end
    # create manifest file similar to project file
    isolate(loaded_depot=true) do
        cd_tempdir() do dir
            touch(joinpath(dir, "Project.toml"))
            Pkg.activate(".")
            Pkg.add("Example")
            @test isfile(joinpath(dir, "Manifest.toml"))
            @test !isfile(joinpath(dir, "JuliaManifest.toml"))
        end
        cd_tempdir() do dir
            touch(joinpath(dir, "JuliaProject.toml"))
            Pkg.activate(".")
            Pkg.add("Example")
            @test !isfile(joinpath(dir, "Manifest.toml"))
            @test isfile(joinpath(dir, "JuliaManifest.toml"))
        end
    end
end

#
# # Other
#
# Note: these tests should be run on clean depots
@testset "downloads" begin
    # libgit2 downloads
    isolate() do
        Pkg.add("Example"; use_libgit2_for_all_downloads=true)
        @test haskey(Pkg.dependencies(), exuuid)
        @eval import $(Symbol(TEST_PKG.name))
        @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
        Pkg.rm(TEST_PKG.name)
    end
    isolate() do
        @testset "libgit2 downloads" begin
            Pkg.add(TEST_PKG.name; use_libgit2_for_all_downloads=true)
            @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
            Pkg.rm(TEST_PKG.name)
        end
        @testset "tarball downloads" begin
            Pkg.add("JSON"; use_only_tarballs_for_downloads=true)
            @test "JSON" in [pkg.name for (uuid, pkg) in Pkg.dependencies()]
            Pkg.rm("JSON")
        end
    end
end

@testset "package name in resolver errors" begin
    isolate(loaded_depot=true) do
        try
            Pkg.add(Pkg.PackageSpec(;name="Example", version = v"55"))
        catch e
            @test occursin(TEST_PKG.name, sprint(showerror, e))
        end
    end
end

@testset "Set download concurrency" begin
    isolate() do
        withenv("JULIA_PKG_CONCURRENCY" => 1) do
            ctx = Pkg.Types.Context()
            @test ctx.num_concurrent_downloads == 1
        end
    end
end

@testset "API details" begin
    # API should not mutate
    isolate() do
        package_names = ["JSON"]
        packages = Pkg.PackageSpec.(package_names)
        Pkg.add(packages)
        @test [p.name for p in packages] == package_names
    end
    # API should accept `AbstractString` arguments
    isolate() do
        Pkg.add(strip("  Example  "))
        Pkg.rm(strip("  Example "))
    end
end

@testset "REPL error handling" begin
    isolate() do
        # PackageSpec tokens
        @test_throws PkgError Pkg.pkg"add FooBar Example#foobar#foobar"
        @test_throws PkgError Pkg.pkg"up Example#foobar@0.0.0"
        @test_throws PkgError Pkg.pkg"pin Example@0.0.0@0.0.1"
        @test_throws PkgError Pkg.pkg"up #foobar"
        @test_throws PkgError Pkg.pkg"add @0.0.1"
        @test_throws PkgError Pkg.pkg"add JSON Example#foobar#foobar LazyJSON"
        # Argument count
        @test_throws PkgError Pkg.pkg"activate one two"
        @test_throws PkgError Pkg.pkg"activate one two three"
        @test_throws PkgError Pkg.pkg"precompile Example"
        # invalid options
        @test_throws PkgError Pkg.pkg"rm --minor Example"
        @test_throws PkgError Pkg.pkg"pin --project Example"
        # conflicting options
        @test_throws PkgError Pkg.pkg"up --major --minor"
        @test_throws PkgError Pkg.pkg"rm --project --manifest"
    end
end

end #module
