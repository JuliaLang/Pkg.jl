module AddTests

using Test, UUIDs
import ..Pkg, LibGit2
using Pkg.Types: PkgError
using Pkg.Resolve: ResolverError
using ..Utils
using Logging

general_uuid = UUID("23338594-aafe-5451-b93e-139f81909106") # UUID for `General`
exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")
parsers_uuid = UUID("69de0a69-1ddd-5017-9359-2bf0b02dc9f0")
markdown_uuid = UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
unregistered_uuid = UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")
simple_package_uuid = UUID("fc6b7c0f-8a2f-4256-bbf4-8c72c30df5be")
pngjll_uuid = UUID("b53b4c65-9356-5827-b1ea-8c7a1a84506f")

@testset "Depot setup" begin
    # This runs against `isolate`'s private target depot: the shared loaded
    # depot used by `isolate(loaded_depot = true)` is populated up front by
    # `Utils.populate_loaded_depot!` in the test runner instead.
    isolate() do
        depot = first(DEPOT_PATH)
        # Now we double check we have a clean slate.
        @test isempty(Pkg.dependencies())
        # A simple `add` should set up some things for us:
        Pkg.add(name = "Example", version = "0.5.3")
        # - `General` should be initiated by default.
        regs = Pkg.Registry.reachable_registries()
        @test length(regs) == 1
        reg = regs[1]
        @test reg.name == "General"
        @test reg.uuid == general_uuid
        # - Check that CACHEDIR.TAG files exist in cache directories
        @test isfile(joinpath(depot, "registries", "CACHEDIR.TAG"))
        @test isfile(joinpath(depot, "packages", "CACHEDIR.TAG"))
        # - The package should be installed correctly.
        source053, source053_time = nothing, nothing
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            source053 = pkg.source
            source053_time = mtime(pkg.source)
        end
        # - The active project was automatically created.
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
        # Now we install the same package at a different version:
        Pkg.add(name = "Example", version = "0.5.1")
        # - Check that the package was installed correctly.
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.5.1"
            @test isdir(pkg.source)
            # - We also check the interaction between the previously installed version.
            @test pkg.source != source053
        end
        # Now a few more versions:
        Pkg.add(name = "Example", version = "0.5.0")
        Pkg.add(name = "Example")
        Pkg.add(name = "Example", version = "0.3.0")
        Pkg.add(name = "Example", version = "0.3.3")
        # With similar checks
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.3"
            @test isdir(pkg.source)
        end
        # Now we try adding a second dependency.
        # We repeat the same class of tests.
        Pkg.add(name = "JSON", version = "0.18.0")
        sourcej018 = nothing
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version == v"0.18.0"
            @test isdir(pkg.source)
        end
        Pkg.add(name = "JSON", version = "0.20.0")
        Pkg.dependencies(json_uuid) do pkg
            @test isdir(pkg.source)
            @test pkg.source != sourcej018
        end
        # Now check packages which track repos instead of registered versions
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl", rev = "v0.5.3")
        @test isfile(joinpath(depot, "clones", "CACHEDIR.TAG"))
        Pkg.dependencies(exuuid) do pkg
            @test !pkg.is_tracking_registry
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        Pkg.add(name = "Example", rev = "master")
        Pkg.dependencies(exuuid) do pkg
            @test !pkg.is_tracking_registry
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        # Also check that unregistered packages are installed properly.
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        # Check `develop`
        Pkg.develop(name = "Example")
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source) # TODO check for full git clone, have to implement saving original URL first
        end
        Pkg.develop(name = "JSON")
        Pkg.dependencies(json_uuid) do pkg
            @test isdir(pkg.source) # TODO check for full git clone, have to implement saving original URL first
        end
        # Check that the original installation was undisturbed.
        regs = Pkg.Registry.reachable_registries()
        @test length(regs) == 1
        reg = regs[1]
        @test reg.name == "General"
        @test reg.uuid == general_uuid
        @test mtime(source053) == source053_time
    end
end

@testset "activate" begin
    isolate(loaded_depot = true) do
        io = IOBuffer()
        Pkg.activate("Foo"; io = io)
        output = String(take!(io))
        @test occursin(r"Activating.*project at.*`.*Foo`", output)
        Pkg.activate(; io = io, temp = true)
        output = String(take!(io))
        @test occursin(r"Activating new project at `.*`", output)
        prev_env = Base.active_project()

        # - activating the previous project
        Pkg.activate(; temp = true)
        @test Base.active_project() != prev_env
        Pkg.activate(; prev = true)
        @test prev_env == Base.active_project()

        Pkg.activate(; temp = true)
        @test Base.active_project() != prev_env
        Pkg.activate(; prev = true)
        @test Base.active_project() == prev_env

        Pkg.activate("")
        @test Base.active_project() != prev_env
        Pkg.activate(; prev = true)
        @test Base.active_project() == prev_env

        load_path_before = copy(LOAD_PATH)
        try
            empty!(LOAD_PATH)   # unset active env
            Pkg.activate()      # shouldn't error
            Pkg.activate(; prev = true) # shouldn't error
        finally
            append!(empty!(LOAD_PATH), load_path_before)
        end
    end
end

# Here we check against invalid input.
@testset "add: input checking" begin
    isolate(loaded_depot = true) do
        # Julia is not a valid package name.
        @test_throws PkgError("`julia` is not a valid package name") Pkg.add(name = "julia")
        # Package names must be valid Julia identifiers.
        @test_throws PkgError("`***` is not a valid package name") Pkg.add(name = "***")
        @test_throws PkgError("`Foo Bar` is not a valid package name") Pkg.add(name = "Foo Bar")
        # Names which are invalid and are probably URLs or paths.
        @test_throws PkgError(
            """
            `https://github.com` is not a valid package name
            The argument appears to be a URL or path, perhaps you meant `Pkg.add(url="...")` or `Pkg.add(path="...")`."""
        ) Pkg.add("https://github.com")
        @test_throws PkgError(
            """
            `./Foobar` is not a valid package name
            The argument appears to be a URL or path, perhaps you meant `Pkg.add(url="...")` or `Pkg.add(path="...")`."""
        ) Pkg.add("./Foobar")
        # An empty spec is invalid.
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `add`"
        ) Pkg.add(Pkg.PackageSpec())
        # Versions imply that we are tracking a registered version.
        @test_throws PkgError(
            "version specification invalid when tracking a repository: `0.5.0` specified for package `Example`"
        ) Pkg.add(name = "Example", rev = "master", version = "0.5.0")
        # Adding with a slight typo gives suggestions
        try
            io = IOBuffer()
            Pkg.add("Examplle"; io)
            @test false # to fail if add doesn't error
        catch err
            @test err isa PkgError
            @test occursin("The following package names could not be resolved:", err.msg)
            @test occursin("Examplle (not found in project, manifest or registry)", err.msg)
            @test occursin("Suggestions: Example", err.msg)
        end
        # Adding with lowercase suggests uppercase
        try
            io = IOBuffer()
            Pkg.add("http"; io)
            @test false # to fail if add doesn't error
        catch err
            @test err isa PkgError
            @test occursin("Suggestions: HTTP", err.msg)
        end
        try
            io = IOBuffer()
            Pkg.add("Flix"; io)
            @test false # to fail if add doesn't error
        catch err
            @test err isa PkgError
            @test occursin("Suggestions: Flux", err.msg)
        end
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `add`"
        ) Pkg.add(Pkg.PackageSpec())
        # Adding an unregistered package
        @test_throws PkgError Pkg.add("ThisIsHopefullyRandom012856014925701382")
        # Wrong UUID
        @test_throws PkgError Pkg.add(Pkg.PackageSpec("Example", UUID(UInt128(1))))
        # Missing UUID
        @test_throws PkgError Pkg.add(Pkg.PackageSpec(uuid = uuid4()))
        # Two packages with the same name
        @test_throws PkgError(
            "it is invalid to specify multiple packages with the same name: `Example`"
        ) Pkg.add([(; name = "Example"), (; name = "Example", version = "0.5.0")])
    end
    # empty git repo (no commits)
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            close(LibGit2.init(tempdir))
            try
                Pkg.add(path = tempdir)
                @test false # to fail if add doesn't error
            catch err
                @test err isa PkgError
                @test match(r"^invalid git HEAD", err.msg) !== nothing
            end
        end
    end
end

# Here we can use a loaded depot because we are only checking changes to the active project.
# We check that `add` supports basic operations on a clean project.
# The package should be added as a direct dependency.
@testset "add: changes to the active project" begin
    # Basic add
    isolate(loaded_depot = true) do
        Pkg.add(Pkg.PackageSpec("Example"))
        Pkg.dependencies(exuuid) do ex
            @test ex.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Basic add by version
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.5.0")
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
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl", rev = "v0.5.3")
        Pkg.dependencies(exuuid) do ex
            @test !ex.is_tracking_registry
            @test ex.git_source == "https://github.com/JuliaLang/Example.jl"
            @test ex.git_revision == "v0.5.3"
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Basic add by git revision
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", rev = "master")
        Pkg.dependencies(exuuid) do ex
            @test !ex.is_tracking_registry
            @test ex.git_source == "https://github.com/JuliaLang/Example.jl.git"
            @test ex.git_revision == "master"
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Adding stdlibs should work.
    isolate(loaded_depot = true) do
        profile_uuid = UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79")
        # - Adding a stdlib by name.
        Pkg.add("Markdown")
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
        # - Adding a stdlib by UUID.
        Pkg.add(uuid = profile_uuid)
        Pkg.dependencies(profile_uuid) do pkg
            @test pkg.name == "Profile"
        end
        # - Adding a stdlib by name/UUID.
        Pkg.add(name = "Markdown", uuid = markdown_uuid)
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
    end
    # Basic add by local path.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
            Pkg.add(path = path)
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
        end
    end
    # add when depot does not exist should create the default project in the correct location
    isolate() do;
        mktempdir() do tempdir
            empty!(DEPOT_PATH)
            push!(DEPOT_PATH, tempdir)
            Base.append_bundled_depot_path!(DEPOT_PATH)
            rm(tempdir; force = true, recursive = true)
            @test !isdir(first(DEPOT_PATH))
            Pkg.add("JSON")
            @test dirname(dirname(Pkg.project().path)) == realpath(joinpath(tempdir, "environments"))
        end
    end
end

# Here we can use a loaded depot because we are only checking changes to the active project.
@testset "add: package state changes" begin
    # Check that `add` on an already added stdlib works.
    # Stdlibs are special cased throughout the codebase.
    isolate(loaded_depot = true) do
        Pkg.add("Markdown")
        Pkg.add("Markdown")
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
        @test haskey(Pkg.project().dependencies, "Markdown")
    end
    # Double add should not change state, this would be an unnecessary change.
    isolate(loaded_depot = true) do
        @test !haskey(Pkg.Types.Context().env.project.compat, "Example")
        Pkg.add(name = "Example", version = "0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test !haskey(Pkg.Types.Context().env.project.compat, "Example")
        Pkg.add("Example")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test !haskey(Pkg.Types.Context().env.project.compat, "Example")
    end
    # Adding a new package should not alter the version of existing packages.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add("Test")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
    end
    # Add by version should not override pinned version.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
            @test ex.is_pinned
        end
        Pkg.add(name = "Example", version = "0.5.0")
        # We check that the package state is left unchanged.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
            @test ex.is_pinned
        end
    end
    # Add by version should override add by repo.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", rev = "master")
        # First we check that we are not tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.git_revision == "master"
            @test !ex.is_tracking_registry
        end
        Pkg.add(name = "Example", version = "0.3.0")
        # We should now be tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.git_revision === nothing
            @test ex.is_tracking_registry
        end
    end
    # Add by version should override add by repo, even for indirect dependencies.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "DependsOnExample"))
            Pkg.add(path = path)
            Pkg.add(name = "Example", rev = "master")
            @test !Pkg.dependencies()[exuuid].is_tracking_registry
            # Now we remove the package as a direct dependency.
            # The package should still exist as an indirect dependency because `DependsOnExample` depends on it.
            Pkg.rm("Example")
            Pkg.add(name = "Example", version = "0.3.0")
            # Now we check that we are tracking a registered version.
            Pkg.dependencies(exuuid) do ex
                @test ex.version == v"0.3.0"
                @test ex.is_tracking_registry
            end
        end
    end
    # Add by URL should not override pin.
    isolate(loaded_depot = true) do
        Pkg.add(name = "Example", version = "0.3.0")
        Pkg.pin(name = "Example")
        Pkg.dependencies(exuuid) do ex
            @test ex.is_pinned
            @test ex.is_tracking_registry
            @test ex.version == v"0.3.0"
        end
        Pkg.add(url = "https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do ex
            @test ex.is_pinned
            @test ex.is_tracking_registry
            @test ex.version == v"0.3.0"
        end
    end
    # It should be possible to switch branches by reusing the URL.
    isolate(loaded_depot = true) do
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl", rev = "0.2.0")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            @test !pkg.is_tracking_registry
            @test pkg.git_revision == "0.2.0"
            # We check that we have the correct branch by checking its dependencies.
            @test haskey(pkg.dependencies, "Example")
        end
        # Now we refer to it by name so to check that we reuse the URL.
        Pkg.add(name = "Unregistered", rev = "0.1.0")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            @test !pkg.is_tracking_registry
            @test pkg.git_revision == "0.1.0"
            # We check that we have the correct branch by checking its dependencies.
            @test !haskey(pkg.dependencies, "Example")
        end
    end
    # add should resolve the correct versions even when the manifest is out of sync with the project compat
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            Pkg.activate(copy_test_package(tempdir, "CompatOutOfSync"))
            Pkg.add("Libdl")
            Pkg.dependencies(exuuid) do pkg
                @test pkg.version == v"0.3.0"
            end
        end
    end
    # Preserve syntax
    # These tests mostly check the REPL side correctness.

    # make sure the default behavior is invoked
    withenv("JULIA_PKG_PRESERVE_TIERED_INSTALLED" => false) do

        # - Normal add should not change the existing version.
        isolate(loaded_depot = true) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(name = "JSON", version = "0.18.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
        end
        # - `tiered_installed`.
        isolate(loaded_depot = false) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"

            @test_logs(
                (:debug, "tiered_resolve: trying PRESERVE_ALL_INSTALLED"),
                (:debug, "tiered_resolve: trying PRESERVE_ALL"),
                min_level = Logging.Debug,
                match_mode = :any,
                Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_TIERED_INSTALLED)
            )
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"

            Pkg.activate(temp = true)
            @test_logs(
                (:debug, "tiered_resolve: trying PRESERVE_ALL_INSTALLED"),
                min_level = Logging.Debug,
                match_mode = :any,
                Pkg.add("Example"; preserve = Pkg.PRESERVE_TIERED_INSTALLED) # should only add v0.3.0 as it was installed earlier
            )
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"

            withenv("JULIA_PKG_PRESERVE_TIERED_INSTALLED" => true) do
                Pkg.activate(temp = true)
                @test_logs(
                    (:debug, "tiered_resolve: trying PRESERVE_ALL_INSTALLED"),
                    min_level = Logging.Debug,
                    match_mode = :any,
                    Pkg.add(name = "Example")
                )
                @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            end

            Pkg.activate(temp = true)
            @test_logs(
                (:debug, "tiered_resolve: trying PRESERVE_ALL"),
                min_level = Logging.Debug,
                match_mode = :any,
                Pkg.add(name = "Example") # default 'add' should serve a newer version
            )
            @test Pkg.dependencies()[exuuid].version > v"0.3.0"
        end
        # - `tiered` is the default option.
        isolate(loaded_depot = false) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_TIERED)
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
        end
        # - `installed`.
        isolate(loaded_depot = false) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            @test_throws Pkg.Resolve.ResolverError Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_ALL_INSTALLED) # no installed version
        end
        # - `all` should succeed in the same way as `tiered`.
        isolate(loaded_depot = false) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_ALL)
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"

            Pkg.rm("JSON")
            Pkg.add(Pkg.PackageSpec(; name = "JSON"); preserve = Pkg.PRESERVE_ALL_INSTALLED)
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
        end
        # - `direct` should also succeed in the same way.
        isolate(loaded_depot = true) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_DIRECT)
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
        end
        # - `semver` should update `Example` and the jll to the highest semver compatible version.
        isolate(loaded_depot = true) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_SEMVER)
            @test Pkg.dependencies()[exuuid].version == v"0.3.3"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version > v"1.6.37+4"
        end
        #- `none` should update `Example` and the jll to the highest compatible version.
        isolate(loaded_depot = true) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+4")
            Pkg.add(name = "Example", version = "0.3.0")
            @test Pkg.dependencies()[exuuid].version == v"0.3.0"
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+4"
            Pkg.add(Pkg.PackageSpec(; name = "JSON", version = "0.18.0"); preserve = Pkg.PRESERVE_NONE)
            @test Pkg.dependencies()[exuuid].version > v"0.3.0"
            @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
            @test Pkg.dependencies()[pngjll_uuid].version > v"1.6.37+4"
        end
        isolate(loaded_depot = true) do
            Pkg.add(name = "libpng_jll", version = v"1.6.37+5")
            @test Pkg.dependencies()[pngjll_uuid].version == v"1.6.37+5"
        end
        # Adding a new package to a package should add compat entries
        isolate(loaded_depot = true) do
            mktempdir() do tempdir
                Pkg.activate(tempdir)
                mkpath(joinpath(tempdir, "src"))
                touch(joinpath(tempdir, "src", "Foo.jl"))
                ctx = Pkg.Types.Context()
                ctx.env.project.name = "Foo"
                ctx.env.project.uuid = UUIDs.UUID(0)
                Pkg.Types.write_project(ctx.env)
                Pkg.add(name = "Example", version = "0.3.0")
                @test Pkg.dependencies()[exuuid].version == v"0.3.0"
                @test Pkg.Types.Context().env.project.compat["Example"] == Pkg.Types.Compat(Pkg.Types.VersionSpec("0.3"), "0.3.0")
                Pkg.add(name = "Example", version = "0.3.1")
                @test Pkg.Types.Context().env.project.compat["Example"] == Pkg.Types.Compat(Pkg.Types.VersionSpec("0.3"), "0.3.0")
            end
        end
    end # withenv
end

@testset "add: repo handling" begin
    # Dependencies added with an absolute path should be stored as absolute paths.
    # This tests shows that, packages added with an absolute path will not break
    # if the project is moved to a new position.
    # We can use the loaded depot here, it will help us avoid the original clone.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
            path = abspath(path)
            Pkg.add(path = path)
            # Now we try to find the package.
            rm(joinpath(DEPOT_PATH[1], "packages"); recursive = true)
            @test !isdir(Pkg.dependencies()[empty_package].source)
            Pkg.instantiate()
            @test isdir(Pkg.dependencies()[empty_package].source)
            # Now we move the project and should still be able to find the package.
            mktempdir() do other_dir
                cp(dirname(Base.active_project()), other_dir; force = true)
                Pkg.activate(other_dir)
                rm(joinpath(DEPOT_PATH[1], "packages"); recursive = true)
                @test !isdir(Pkg.dependencies()[empty_package].source)
                Pkg.instantiate()
            end
        end
    end
    # Dependencies added with relative paths should be stored relative to the active project.
    # This test shows that packages added with a relative path will not break
    # as long as they maintain the same relative position to the project.
    # We can use the loaded depot here, it will help us avoid the original clone.
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
            path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
            # We add the package using a relative path.
            cd(path) do
                Pkg.add(path = ".")
                manifest = Pkg.Types.read_manifest(joinpath(dirname(Base.active_project()), "Manifest.toml"))
                # Test that the relative path is canonicalized.
                repo = string("../../../", basename(tempdir), "/EmptyPackage")
                @test manifest[empty_package].repo.source == repo
            end
            # Now we try to find the package.
            rm(joinpath(DEPOT_PATH[1], "packages"); recursive = true)
            rm(joinpath(DEPOT_PATH[1], "clones"); recursive = true)
            Pkg.instantiate()
            # Test that Operations.is_instantiated works with relative path
            @test Pkg.Operations.is_instantiated(Pkg.Types.EnvCache())
            # Now we destroy the relative position and should not be able to find the package.
            rm(joinpath(DEPOT_PATH[1], "packages"); recursive = true)
            # Test that Operations.is_instantiated works with relative path
            @test !Pkg.Operations.is_instantiated(Pkg.Types.EnvCache())
            mktempdir() do other_dir
                cp(dirname(Base.active_project()), other_dir; force = true)
                Pkg.activate(other_dir)
                @test_throws PkgError Pkg.instantiate() # TODO is there a way to pattern match on just part of the err message?
            end
        end
    end
    # Now we test packages added by URL.
    isolate(loaded_depot = true) do
        # Details: `master` is past `0.1.0`
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl", rev = "0.1.0")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test isdir(pkg.source)
        end
        @test haskey(Pkg.project().dependencies, "Unregistered")
        # Now we remove the source so that we have to load it again.
        # We should reuse the existing clone in this case.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive = true)
        Pkg.instantiate()
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test isdir(pkg.source)
        end
        @test haskey(Pkg.project().dependencies, "Unregistered")
        # Now we remove the source _and_ our cache, we have no choice to re-clone the remote.
        # We should still be able to find the source.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive = true)
        rm(joinpath(DEPOT_PATH[1], "clones"); recursive = true)
        Pkg.instantiate()
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.name == "Unregistered"
            @test isdir(pkg.source)
        end
        @test haskey(Pkg.project().dependencies, "Unregistered")
    end
end

@testset "add: resolve tiers" begin
    # The MetaGraphs version tested below relied on a JLD2 version
    # that couldn't actually be loaded on julia 1.9+ so General
    # will be patched. This checks out a commit before then to maintain
    # these tests.
    registry_url = "https://github.com/JuliaRegistries/General.git"
    registry_commit = "030d6dae0df2ad6c3b2f90d41749df3eedb8d1b1"
    Utils.isolate_and_pin_registry(; registry_url, registry_commit) do;
        mktempdir() do tmp
            # All
            copy_test_package(tmp, "ShouldPreserveAll"; use_pkg = false)
            Pkg.activate(joinpath(tmp, "ShouldPreserveAll"))
            parsers_uuid = UUID("69de0a69-1ddd-5017-9359-2bf0b02dc9f0")
            original_parsers_version = Pkg.dependencies()[parsers_uuid].version
            Pkg.add(name = "Example", version = "0.5.0")
            @test Pkg.dependencies()[parsers_uuid].version == original_parsers_version
            # Direct
            copy_test_package(tmp, "ShouldPreserveDirect"; use_pkg = false)
            Pkg.activate(joinpath(tmp, "ShouldPreserveDirect"))
            ordered_collections = UUID("bac558e1-5e72-5ebc-8fee-abe8a469f55d")
            Pkg.add(uuid = ordered_collections, version = "1.0.1")
            lazy_json = UUID("fc18253b-5e1b-504c-a4a2-9ece4944c004")
            data_structures = UUID("864edb3b-99cc-5e75-8d2d-829cb0a9cfe8")
            @test Pkg.dependencies()[lazy_json].version == v"0.1.0" # stayed the same
            @test Pkg.dependencies()[data_structures].version == v"0.16.1" # forced to change
            @test Pkg.dependencies()[ordered_collections].version == v"1.0.1" # sanity check
            # SEMVER
            copy_test_package(tmp, "ShouldPreserveSemver"; use_pkg = false)

            # Support julia versions before & after the MbedTLS > OpenSSL switch
            OpenSSL_pkgid = Base.PkgId(Base.UUID("458c3c95-2e84-50aa-8efc-19380b2a3a95"), "OpenSSL_jll")
            manifest_to_use = if Base.is_stdlib(OpenSSL_pkgid)
                joinpath(tmp, "ShouldPreserveSemver", "Manifest_OpenSSL.toml")
            else
                joinpath(tmp, "ShouldPreserveSemver", "Manifest_MbedTLS.toml")
            end
            mv(manifest_to_use, joinpath(tmp, "ShouldPreserveSemver", "Manifest.toml"))

            Pkg.activate(joinpath(tmp, "ShouldPreserveSemver"))
            light_graphs = UUID("093fc24a-ae57-5d10-9952-331d41423f4d")
            meta_graphs = UUID("626554b9-1ddb-594c-aa3c-2596fe9399a5")
            light_graphs_version = Pkg.dependencies()[light_graphs].version
            Pkg.add(uuid = meta_graphs, version = "0.6.4")
            @test Pkg.dependencies()[meta_graphs].version == v"0.6.4" # sanity check
            # did not break semver
            @test Pkg.dependencies()[light_graphs].version in Pkg.Types.semver_spec("$(light_graphs_version)")
            # did change version
            @test Pkg.dependencies()[light_graphs].version != light_graphs_version
            # NONE
            copy_test_package(tmp, "ShouldPreserveNone"; use_pkg = false)
            Pkg.activate(joinpath(tmp, "ShouldPreserveNone"))
            array_interface = UUID("4fba245c-0d91-5ea0-9b3e-6abc04ee57a9")
            diff_eq_diff_tools = UUID("01453d9d-ee7c-5054-8395-0335cb756afa")
            Pkg.add(uuid = diff_eq_diff_tools, version = "1.0.0")
            @test Pkg.dependencies()[diff_eq_diff_tools].version == v"1.0.0" # sanity check
            @test Pkg.dependencies()[array_interface].version in Pkg.Types.semver_spec("1") # had to make breaking change
        end
    end
end

@testset "package name in resolver errors" begin
    isolate(loaded_depot = true) do
        try
            Pkg.add(name = "Example", version = v"55")
        catch e
            @test occursin(TEST_PKG.name, sprint(showerror, e))
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

@testset "multiple registries overlapping version ranges for different versions" begin
    isolate(loaded_depot = true) do
        # Add a new registry
        dp = DEPOT_PATH[1]
        newreg = joinpath(dp, "registries", "NewReg")
        mkpath(newreg)
        write(
            joinpath(newreg, "Registry.toml"), """
            name = "NewReg"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "whydoineedthis?"

            [packages]
            7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
            """
        )
        example_path = joinpath(newreg, "E", "Example")
        mkpath(example_path)
        write(
            joinpath(example_path, "Package.toml"), """
            name = "Example"
            uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
            repo = "https://github.com/JuliaLang/Example.jl.git"
            """
        )

        write(
            joinpath(example_path, "Versions.toml"), """
            ["0.99.99"]
            git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
            """
        )

        write(
            joinpath(example_path, "Compat.toml"), """
            ["0"]
            julia = "0.0"
            """
        )

        # This shouldn't cause a resolver error
        Pkg.add("Example")
    end
end

@testset "Offline mode" begin
    isolate(loaded_depot = false) do
        # cache this version
        Pkg.add(Pkg.PackageSpec(uuid = exuuid, version = v"0.5.1"))
        @test Pkg.dependencies()[exuuid].version == v"0.5.1"
        Pkg.offline()
        # Pkg.update() should not error/warn and keep Example at 0.5.1
        @test_logs Pkg.update()
        @test Pkg.dependencies()[exuuid].version == v"0.5.1"
        try
            Pkg.add(Pkg.PackageSpec(uuid = exuuid, version = v"0.5.3"))
        catch e
            @test e isa ResolverError
            # `\S*` in regex below will allow for ANSI color escape codes in the logs
            @test occursin(r"possible versions are: \S*0\.5\.1\S* or uninstalled", e.msg)
        end
        Pkg.offline(false)
    end
end

@testset "Issue #4345: pidfile in writable location when depot is readonly" begin
    isolate(loaded_depot = false) do
        mktempdir() do readonly_depot
            mktempdir() do writable_depot
                # Set up initial depot with a package
                old_depot_path = copy(DEPOT_PATH)
                try
                    empty!(DEPOT_PATH)
                    push!(DEPOT_PATH, readonly_depot)
                    Base.append_bundled_depot_path!(DEPOT_PATH)

                    Pkg.activate(temp = true)
                    # Install Example.jl in the initial depot
                    Pkg.add(name = "Example", version = "0.5.3")

                    # Make the depot read-only
                    run(`chmod -R -w $readonly_depot`)

                    # Add writable depot to front of DEPOT_PATH
                    pushfirst!(DEPOT_PATH, writable_depot)

                    # Create a new temporary environment and try to add a package
                    # that depends on something in the readonly depot
                    Pkg.activate(temp = true)
                    # This should not fail with permission denied on pidfile creation
                    # The fix ensures pidfiles are created in writable locations
                    @test_nowarn Pkg.add(name = "Example", version = "0.5.3")
                finally
                    # Restore depot path and make readonly depot writable again for cleanup
                    empty!(DEPOT_PATH)
                    append!(DEPOT_PATH, old_depot_path)
                    run(`chmod -R +w $readonly_depot`)
                end
            end
        end
    end
end

@test allunique(unique([Pkg.PackageSpec(path = "foo"), Pkg.PackageSpec(path = "foo")]))

@testset "Pkg.add prefers loaded dependency versions" begin
    isolate(loaded_depot = true) do
        script = """
        using Pkg, Test
        Pkg.activate(; temp = true)
        io = IOBuffer()
        Pkg.add(name = "Example", version = v"0.5.4", io = io)
        add_output = String(take!(io))
        @test occursin("[7876af07] + Example v0.5.4", add_output)
        using Example
        Pkg.activate(; temp = true)
        Pkg.add("Example", io = io) # v0.5.5 exists, but v0.5.4 is loaded
        add_output = String(take!(io))
        @test occursin("[7876af07] + Example v0.5.5", add_output)
        Pkg.activate(; temp = true)
        Pkg.add("Example", io = io, prefer_loaded_versions = true) # v0.5.5 exists, but v0.5.4 is loaded
        add_output = String(take!(io))
        @test occursin("was able to add the version of Example that is already loaded", add_output)
        @test occursin("[7876af07] + Example v0.5.4", add_output)
        Pkg.activate(; temp = true)
        # REPL mode default: should prefer loaded version without explicit kwarg
        Base.ScopedValues.@with Pkg.IN_REPL_MODE => true begin
            Pkg.add("Example", io = io)
        end
        add_output = String(take!(io))
        @test occursin("was able to add the version of Example that is already loaded", add_output)
        @test occursin("[7876af07] + Example v0.5.4", add_output)
        """
        cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $script`,
            "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ";" : ":")
        )
        @test Utils.show_output_if_command_errors(cmd)
    end
end

end # module
