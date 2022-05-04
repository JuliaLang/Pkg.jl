module NewTests

using  Test, UUIDs, Dates, TOML
import ..Pkg, LibGit2
using  Pkg.Types: PkgError
using  Pkg.Resolve: ResolverError
import Pkg.Artifacts: artifact_meta, artifact_path
import Base.BinaryPlatforms: HostPlatform, Platform, platforms_match
using  ..Utils

general_uuid = UUID("23338594-aafe-5451-b93e-139f81909106") # UUID for `General`
exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")
markdown_uuid = UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
test_stdlib_uuid = UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
unicode_uuid = UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5")
unregistered_uuid = UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")
simple_package_uuid = UUID("fc6b7c0f-8a2f-4256-bbf4-8c72c30df5be")

# Disable auto-gc for these tests
Pkg._auto_gc_enabled[] = false

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
        Pkg.add(name="Example", version="0.5.3")
        # - `General` should be initiated by default.
        regs = Pkg.Registry.reachable_registries()
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
        Pkg.add(name="Example", version="0.5.1")
        # - Check that the package was installed correctly.
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.5.1"
            @test isdir(pkg.source)
            # - We also check the interaction between the previously intalled version.
            @test pkg.source != source053
        end
        # Now a few more versions:
        Pkg.add(name="Example", version="0.5.0")
        Pkg.add(name="Example")
        Pkg.add(name="Example", version="0.3.0")
        Pkg.add(name="Example", version="0.3.3")
        # With similar checks
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.3"
            @test isdir(pkg.source)
        end
        # Now we try adding a second dependency.
        # We repeat the same class of tests.
        Pkg.add(name="JSON", version="0.18.0")
        sourcej018 = nothing
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version == v"0.18.0"
            @test isdir(pkg.source)
        end
        Pkg.add(name="JSON", version="0.20.0")
        Pkg.dependencies(json_uuid) do pkg
            @test isdir(pkg.source)
            @test pkg.source != sourcej018
        end
        # Now check packages which track repos instead of registered versions
        Pkg.add(url="https://github.com/JuliaLang/Example.jl", rev="v0.5.3")
        Pkg.dependencies(exuuid) do pkg
            @test !pkg.is_tracking_registry
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        Pkg.add(name="Example", rev="master")
        Pkg.dependencies(exuuid) do pkg
            @test !pkg.is_tracking_registry
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        # Also check that unregistered packages are installed properly.
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test isdir(pkg.source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
        end
        # Check `develop`
        Pkg.develop(name="Example")
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source) # TODO check for full git clone, have to implement saving original URL first
        end
        Pkg.develop(name="JSON")
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
# ## Sandboxing
#
inside_test_sandbox(fn, name; kwargs...) = Pkg.test(name; test_fn=fn, kwargs...)
inside_test_sandbox(fn; kwargs...)       = Pkg.test(;test_fn=fn, kwargs...)

@testset "test: printing" begin
    isolate(loaded_depot=true) do
        Pkg.add(name="Example")
        io = Base.BufferStream()
        Pkg.test("Example"; io=io)
        closewrite(io)
        output = read(io, String)
        @test occursin(r"Testing Example", output)
        @test occursin(r"Status `.+Project\.toml`", output)
        @test occursin(r"Status `.+Manifest\.toml`", output)
        @test occursin(r"Testing Running tests...", output)
        @test occursin(r"Testing Example tests passed", output)
    end
end

@testset "test: sandboxing" begin
    # explicit test dependencies and the tested project are available within the test sandbox
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        foo_uuid = UUID("02250abe-2050-11e9-017e-b301a2b5bcc4")
        path = copy_test_package(tempdir, "BasicSandbox")
        # we set realonly here to simulate the premissions in the `$DEPOT/packages` directory
        Pkg.Types.set_readonly(path)
        Pkg.develop(path=path)
        inside_test_sandbox("BasicSandbox") do
            Pkg.dependencies(foo_uuid) do pkg
                @test length(pkg.dependencies) == 1
                @test haskey(pkg.dependencies, "Random")
            end
            @test haskey(Pkg.project().dependencies, "Test")
            @test haskey(Pkg.project().dependencies, "BasicSandbox")
        end
    end end
    # the active dependency graph is transfered to the test sandbox
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "TransferSubgraph")
        Pkg.activate(path)
        active_json_version = Pkg.dependencies()[json_uuid].version
        inside_test_sandbox("Unregistered") do
            @test Pkg.dependencies()[json_uuid].version == active_json_version
        end
    end end
    # the active dep graph is transfered to test sandbox, even when tracking unregistered repos
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "TestSubgraphTrackingRepo")
        Pkg.activate(path)
        inside_test_sandbox() do
            Pkg.dependencies(unregistered_uuid) do pkg
                @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
                @test !pkg.is_tracking_registry
            end
        end
    end end
    # a test dependency can track a path
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "TestDepTrackingPath")
        Pkg.activate(path)
        inside_test_sandbox() do
            @test Pkg.dependencies()[unregistered_uuid].is_tracking_path
        end
    end end
    # a test dependency can track a repo
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "TestDepTrackingRepo")
        Pkg.activate(path)
        inside_test_sandbox() do
            Pkg.dependencies(unregistered_uuid) do pkg
                @test !pkg.is_tracking_registry
                @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            end
        end
    end end
    # `compat` for test dependencies is honored
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "TestDepCompat")
        Pkg.activate(path)
        inside_test_sandbox() do
            deps = Pkg.dependencies()
            @test deps[exuuid].version == v"0.3.0"
            @test deps[UUID("9cb9b0df-a8d1-4a6c-a371-7d2ae60a2f25")].version == v"0.1.0"
        end
    end end
end

# These tests cover the original "targets" API for specifying test dependencies
@testset "test: 'targets' based testing" begin
    # `Pkg.test` should work on dependency graphs with nodes sharing the same name but not the same UUID
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        Pkg.activate(joinpath(@__DIR__, "test_packages", "SameNameDifferentUUID"))
        inside_test_sandbox("Example") do
            Pkg.dependencies(UUID("6876af07-990d-54b4-ab0e-23690620f79a")) do pkg
                @test pkg.name == "Example"
                @test realpath(pkg.source) == realpath(joinpath(@__DIR__, "test_packages", "SameNameDifferentUUID", "dev", "Example"))
            end
        end
    end end
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        basic_test_target = UUID("50adb811-5a1f-4be4-8146-2725c7f5d900")
        path = copy_test_package(tempdir, "BasicTestTarget")
        # we set realonly here to simulate the premissions in the `$DEPOT/packages` directory
        Pkg.Types.set_readonly(path)
        Pkg.develop(path=path)
        inside_test_sandbox("BasicTestTarget") do
            @test haskey(Pkg.project().dependencies, "Markdown")
            @test haskey(Pkg.project().dependencies, "Test")
            @test haskey(Pkg.project().dependencies, "BasicTestTarget")
            Pkg.dependencies(basic_test_target) do pkg
                @test pkg.is_tracking_path == true
                @test haskey(pkg.dependencies, "UUIDs")
                @test !haskey(pkg.dependencies, "Markdown")
                @test !haskey(pkg.dependencies, "Test")
            end
        end
    end end
    # dependency of test dependency (#567)
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        for x in ["x1", "x2", "x3"]
            path = copy_test_package(tempdir, x)
            Pkg.develop(Pkg.PackageSpec(path = path))
        end
        Pkg.test("x3")
    end end
    # preserve root of active project if it is a dependency (#1423)
    isolate(loaded_depot=false) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "ActiveProjectInTestSubgraph")
        Pkg.activate(path)
        inside_test_sandbox("B") do
            deps = Pkg.dependencies()
            @test deps[UUID("c86f0f68-174e-41db-bd5e-b032223de205")].version == v"1.2.3"
        end
    end end
    # test targets should also honor compat
    isolate(loaded_depot=false) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "TestTargetCompat")
        Pkg.activate(path)
        inside_test_sandbox() do
            deps = Pkg.dependencies()
            @test deps[exuuid].version == v"0.3.0"
        end
    end end
end

@testset "test: fallback when no project file exists" begin
    isolate(loaded_depot=true) do
        Pkg.add(name="Permutations", version="0.3.2")
        if Sys.WORD_SIZE == 32
            # The Permutations.jl v0.3.2 tests are known to fail on 32-bit Julia
            @test_skip Pkg.test("Permutations")
        else
            Pkg.test("Permutations")
        end
    end
end

@testset "using a test/REQUIRE file" begin
    isolate() do
        Pkg.add(name="EnglishText", version="0.6.0")
        Pkg.test("EnglishText")
    end
end

#
# # Activate
#
@testset "activate: repl" begin
    isolate(loaded_depot=true) do
        Pkg.REPLMode.TEST_MODE[] = true
        # - activate shared env
        api, args, opts = first(Pkg.pkg"activate --shared Foo")
        @test api == Pkg.activate
        @test args == "Foo"
        @test opts == Dict(:shared => true)
        # - activate shared env using special syntax
        api, args, opts = first(Pkg.pkg"activate @Foo")
        @test api == Pkg.activate
        @test args == "Foo"
        @test opts == Dict(:shared => true)
        # - no arg activate
        api, opts = first(Pkg.pkg"activate")
        @test api == Pkg.activate
        @test isempty(opts)
        # - regular activate
        api, args, opts = first(Pkg.pkg"activate FooBar")
        @test api == Pkg.activate
        @test args == "FooBar"
        @test isempty(opts)
        # - activating a temporary project
        api, opts = first(Pkg.pkg"activate --temp")
        @test api == Pkg.activate
        @test opts == Dict(:temp => true)
        # - activating the previous project
        api, opts = first(Pkg.pkg"activate -")
        @test api == Pkg.activate
        @test opts == Dict(:prev => true)
        # github branch rewriting
        api, args, opts = first(Pkg.pkg"add https://github.com/JuliaLang/Pkg.jl/tree/aa/gitlab")
        arg = args[1]
        @test arg.url == "https://github.com/JuliaLang/Pkg.jl"
        @test arg.rev == "aa/gitlab"
    end
end

@testset "activate" begin
    isolate(loaded_depot=true) do
        io = IOBuffer()
        Pkg.activate("Foo"; io=io)
        output = String(take!(io))
        @test occursin(r"Activating.*project at.*`.*Foo`", output)
        Pkg.activate(; io=io, temp=true)
        output = String(take!(io))
        @test occursin(r"Activating new project at `.*`", output)
        prev_env = Base.active_project()

        # - activating the previous project
        Pkg.activate(; temp=true)
        @test Base.active_project() != prev_env
        Pkg.activate(; prev=true)
        @test prev_env == Base.active_project()

        Pkg.activate(; temp=true)
        @test Base.active_project() != prev_env
        Pkg.activate(; prev=true)
        @test Base.active_project() == prev_env

        Pkg.activate("")
        @test Base.active_project() != prev_env
        Pkg.activate(; prev=true)
        @test Base.active_project() == prev_env

        load_path_before = copy(LOAD_PATH)
        try
            empty!(LOAD_PATH)   # unset active env
            Pkg.activate()      # shouldn't error
            Pkg.activate(; prev=true) # shouldn't error
        finally
            append!(empty!(LOAD_PATH), load_path_before)
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
        @test_throws PkgError("`julia` is not a valid package name") Pkg.add(name="julia")
        # Package names must be valid Julia identifiers.
        @test_throws PkgError("`***` is not a valid package name") Pkg.add(name="***")
        @test_throws PkgError("`Foo Bar` is not a valid package name") Pkg.add(name="Foo Bar")
        # Names which are invalid and are probably URLs or paths.
        @test_throws PkgError("""
        `https://github.com` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.add(url="...")` or `Pkg.add(path="...")`.""") Pkg.add("https://github.com")
        @test_throws PkgError("""
        `./Foobar` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.add(url="...")` or `Pkg.add(path="...")`.""") Pkg.add("./Foobar")
        # An empty spec is invalid.
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `add`"
            ) Pkg.add(Pkg.PackageSpec())
        # Versions imply that we are tracking a registered version.
        @test_throws PkgError(
            "version specification invalid when tracking a repository: `0.5.0` specified for package `Example`"
            ) Pkg.add(name="Example", rev="master", version="0.5.0")
        # Adding with a slight typo gives suggestions
        try
            Pkg.add("Examplle")
            @test false # to fail if add doesn't error
         catch err
            @test err isa PkgError
            @test occursin("The following package names could not be resolved:", err.msg)
            @test occursin("Examplle (not found in project, manifest or registry)", err.msg)
            @test occursin("Suggestions:", err.msg)
            # @test occursin("Example", err.msg) # can't test this as each char in "Example" is individually colorized
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
            ) Pkg.add([(;name="Example"), (;name="Example",version="0.5.0")])
    end
    # Unregistered UUID in manifest
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        package_path = copy_test_package(tempdir, "UnregisteredUUID")
        Pkg.activate(package_path)
        @test_throws PkgError("expected package `Example [142fd7e7]` to be registered") Pkg.add("JSON")
    end end
    # empty git repo (no commits)
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        close(LibGit2.init(tempdir))
        try Pkg.add(path=tempdir)
            @test false # to fail if add doesn't error
        catch err
            @test err isa PkgError
            @test match(r"^invalid git HEAD", err.msg) !== nothing
        end
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
        Pkg.add(name="Example", version="0.5.0")
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
        Pkg.add(url="https://github.com/JuliaLang/Example.jl", rev="v0.5.3")
        Pkg.dependencies(exuuid) do ex
            @test !ex.is_tracking_registry
            @test ex.git_source == "https://github.com/JuliaLang/Example.jl"
            @test ex.git_revision == "v0.5.3"
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Basic add by git revision
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", rev="master")
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
        Pkg.add(uuid=profile_uuid)
        Pkg.dependencies(profile_uuid) do pkg
            @test pkg.name == "Profile"
        end
        # - Adding a stdlib by name/UUID.
        Pkg.add(name="Markdown", uuid=markdown_uuid)
        Pkg.dependencies(markdown_uuid) do pkg
            @test pkg.name == "Markdown"
        end
    end
    # Basic add by local path.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
        Pkg.add(path=path)
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
    # add when depot does not exist should create the default project in the correct location
    isolate() do; mktempdir() do tempdir
        empty!(DEPOT_PATH)
        push!(DEPOT_PATH, tempdir)
        rm(tempdir; force=true, recursive=true)
        @test !isdir(first(DEPOT_PATH))
        Pkg.add("JSON")
        @test dirname(dirname(Pkg.project().path)) == realpath(joinpath(tempdir, "environments"))
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
            @test pkg.name == "Markdown"
        end
        @test haskey(Pkg.project().dependencies, "Markdown")
    end
    # Double add should not change state, this would be an unnecessary change.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add("Example")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
    end
    # Adding a new package should not alter the version of existing packages.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add("Test")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
    end
    # Add by version should not override pinned version.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
            @test ex.is_pinned
        end
        Pkg.add(name="Example", version="0.5.0")
        # We check that the package state is left unchanged.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
            @test ex.is_pinned
        end
    end
    # Add by version should override add by repo.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", rev="master")
        # First we check that we are not tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.git_revision == "master"
            @test !ex.is_tracking_registry
        end
        Pkg.add(name="Example", version="0.3.0")
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
        Pkg.add(path=path)
        Pkg.add(name="Example", rev="master")
        @test !Pkg.dependencies()[exuuid].is_tracking_registry
        # Now we remove the package as a direct dependency.
        # The package should still exist as an indirect dependency becuse `DependsOnExample` depends on it.
        Pkg.rm("Example")
        Pkg.add(name="Example", version="0.3.0")
        # Now we check that we are tracking a registered version.
        Pkg.dependencies(exuuid) do ex
            @test ex.version == v"0.3.0"
            @test ex.is_tracking_registry
        end
    end end
    # Add by URL should not override pin.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        Pkg.pin(name="Example")
        Pkg.dependencies(exuuid) do ex
            @test ex.is_pinned
            @test ex.is_tracking_registry
            @test ex.version == v"0.3.0"
        end
        Pkg.add(url="https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do ex
            @test ex.is_pinned
            @test ex.is_tracking_registry
            @test ex.version == v"0.3.0"
        end
    end
    # It should be possible to switch branches by reusing the URL.
    isolate(loaded_depot=true) do
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl", rev="0.2.0")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            @test !pkg.is_tracking_registry
            @test pkg.git_revision == "0.2.0"
            # We check that we have the correct branch by checking its dependencies.
            @test haskey(pkg.dependencies, "Example")
        end
        # Now we refer to it by name so to check that we reuse the URL.
        Pkg.add(name="Unregistered", rev="0.1.0")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test pkg.git_source == "https://github.com/00vareladavid/Unregistered.jl"
            @test !pkg.is_tracking_registry
            @test pkg.git_revision == "0.1.0"
            # We check that we have the correct branch by checking its dependencies.
            @test !haskey(pkg.dependencies, "Example")
        end
    end
    # add should resolve the correct versions even when the manifest is out of sync with the project compat
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        Pkg.activate(copy_test_package(tempdir, "CompatOutOfSync"))
        Pkg.add("Libdl")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version == v"0.3.0"
        end
    end end
    # Preserve syntax
    # These tests mostly check the REPL side correctness.
    # - Normal add should not change the existing version.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(name="JSON", version="0.18.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `tiered` is the default option.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_TIERED)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `all` should succeed in the same way.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_ALL)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `direct` should also succeed in the same way.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_DIRECT)
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    # - `semver` should update `Example` to the highest semver compatible version.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
        @test Pkg.dependencies()[exuuid].version == v"0.3.0"
        Pkg.add(Pkg.PackageSpec(;name="JSON", version="0.18.0"); preserve=Pkg.PRESERVE_SEMVER)
        @test Pkg.dependencies()[exuuid].version == v"0.3.3"
        @test Pkg.dependencies()[json_uuid].version == v"0.18.0"
    end
    #- `none` should update `Example` to the highest compatible version.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", version="0.3.0")
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
        Pkg.add(path=path)
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
            Pkg.add(path=".")
            manifest = Pkg.Types.read_manifest(joinpath(dirname(Base.active_project()), "Manifest.toml"))
            # Test that the relative path is canonicalized.
            repo = string("../../../", basename(tempdir), "/EmptyPackage")
            @test manifest[empty_package].repo.source == repo
        end
        # Now we try to find the package.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        rm(joinpath(DEPOT_PATH[1], "clones"); recursive=true)
        Pkg.instantiate()
        # Test that Operations.is_instantiated works with relative path
        @test Pkg.Operations.is_instantiated(Pkg.Types.EnvCache())
        # Now we destroy the relative position and should not be able to find the package.
        rm(joinpath(DEPOT_PATH[1], "packages"); recursive=true)
        # Test that Operations.is_instantiated works with relative path
        @test !Pkg.Operations.is_instantiated(Pkg.Types.EnvCache())
        mktempdir() do other_dir
            cp(dirname(Base.active_project()), other_dir; force=true)
            Pkg.activate(other_dir)
            @test_throws PkgError Pkg.instantiate() # TODO is there a way to pattern match on just part of the err message?
        end
    end end
    # Now we test packages added by URL.
    isolate(loaded_depot=true) do
        # Details: `master` is past `0.1.0`
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl", rev="0.1.0")
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
        Pkg.add(name="Example", version="0.5.0")
        @test Pkg.dependencies()[parsers_uuid].version == original_parsers_version
        # Direct
        copy_test_package(tmp, "ShouldPreserveDirect"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveDirect"))
        ordered_collections = UUID("bac558e1-5e72-5ebc-8fee-abe8a469f55d")
        Pkg.add(uuid=ordered_collections, version="1.0.1")
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
        Pkg.add(uuid=meta_graphs, version="0.6.4")
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
        Pkg.add(uuid=diff_eq_diff_tools, version="1.0.0")
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
    # check casesensitive resolution of paths
    isolate() do; cd_tempdir() do dir
        Pkg.REPLMode.TEST_MODE[] = true
        mkdir("example")
        api, args, opts = first(Pkg.pkg"add Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"add example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;name="example")]
        @test isempty(opts)
        @test_throws PkgError Pkg.pkg"add ./Example"
        api, args, opts = first(Pkg.pkg"add ./example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;path="example")]
        @test isempty(opts)
        cd("example")
        api, args, opts = first(Pkg.pkg"add .")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(;path=".")]
        @test isempty(opts)
    end end
    isolate() do; cd_tempdir() do dir
        # adding a nonexistent directory
        @test_throws PkgError("`some/really/random/Dir` appears to be a local path, but directory does not exist"
                              ) Pkg.pkg"add some/really/random/Dir"
        # warn if not explicit about adding directory
        mkdir("Example")
        @test_logs (:info, r"Use `./Example` to add or develop the local directory at `.*`.") match_mode=:any Pkg.pkg"add Example"
    end end
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
        @test_throws PkgError("`julia` is not a valid package name") Pkg.develop(name="julia")
        # Package names must be valid Julia identifiers.
        @test_throws PkgError("`***` is not a valid package name") Pkg.develop(name="***")
        @test_throws PkgError("`Foo Bar` is not a valid package name") Pkg.develop(name="Foo Bar")
        # Names which are invalid and are probably URLs or paths.
        @test_throws PkgError("""
        `https://github.com` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.develop(url="...")` or `Pkg.develop(path="...")`.""") Pkg.develop("https://github.com")
        @test_throws PkgError("""
        `./Foobar` is not a valid package name
        The argument appears to be a URL or path, perhaps you meant `Pkg.develop(url="...")` or `Pkg.develop(path="...")`.""") Pkg.develop("./Foobar")
        # An empty spec is invalid.
        @test_throws PkgError(
            "name, UUID, URL, or filesystem path specification required when calling `develop`"
            ) Pkg.develop(Pkg.PackageSpec())
        # git revisions imply that `develop` tracks a git repo.
        @test_throws PkgError(
            "rev argument not supported by `develop`; consider using `add` instead"
            ) Pkg.develop(name="Example", rev="master")
        # Adding an unregistered package by name.
        @test_throws PkgError Pkg.develop("ThisIsHopefullyRandom012856014925701382")
        # Wrong UUID
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec("Example", UUID(UInt128(1))))
        # Missing UUID
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(uuid = uuid4()))
        # Two packages with the same name
        @test_throws PkgError(
            "it is invalid to specify multiple packages with the same UUID: `Example [7876af07]`"
            ) Pkg.develop([(;name="Example"), (;uuid=exuuid)])
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
            @test Base.samefile(pkg.source, joinpath(Pkg.devdir(), "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # Develop with shared=false
    isolate(loaded_depot=true) do
        Pkg.develop("Example"; shared=false)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(dirname(Pkg.project().path), "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by specifying a registered UUID.
    isolate(loaded_depot=true) do
        Pkg.develop(uuid=exuuid)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by specifying a URL.
    isolate(loaded_depot=true) do
        Pkg.develop(url="https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
    end
    # It is possible to develop by directly specifying a path.
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "SimplePackage")
        path = joinpath(tempdir, "SimplePackage")
        Pkg.develop(path=path)
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test realpath(pkg.source) == realpath(path)
            @test !pkg.is_tracking_registry
            @test haskey(pkg.dependencies, "Example")
            @test haskey(pkg.dependencies, "Markdown")
        end
        @test haskey(Pkg.project().dependencies, "SimplePackage")
    end end
    # recursive `dev`
    isolate(loaded_depot=true) do
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "A"))
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
    isolate() do; cd_tempdir() do dir
        empty!(DEPOT_PATH)
        push!(DEPOT_PATH, "temp")
        Pkg.develop("JSON")
        Pkg.dependencies(json_uuid) do pkg
            @test Base.samefile(pkg.source, abspath(joinpath("temp", "dev", "JSON")))
        end
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
            @test Base.samefile(pkg.source, joinpath(tempdir, "Example"))
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
            @test Base.samefile(pkg.source, joinpath(dirname(Pkg.project().path), "dev", "Example"))
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
            @test Base.samefile(pkg.source, package_path)
            original_source = pkg.source
        end
        # Now we move the project, but preserve the relative structure.
        mktempdir() do tempdir
            cp(project_path, tempdir; force=true)
            Pkg.activate(tempdir)
            # We check that we can still find the source.
            Pkg.dependencies(simple_package_uuid) do pkg
                @test isdir(pkg.source)
                @test Base.samefile(pkg.source, realpath(joinpath(tempdir, "SimplePackage")))
            end
        end
    end
    # Absolute paths
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        copy_test_package(tempdir, "SimplePackage")
        package_path = joinpath(tempdir, "SimplePackage")
        Pkg.activate(tempdir)
        Pkg.develop(path=package_path)
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
            @test pkg.is_tracking_path
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
            @test pkg.is_tracking_path
        end
    end end
    # Local directory name. This must be prepended by "./".
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        cd(dirname(path)) do
            Pkg.pkg"develop ./SimplePackage"
        end
        Pkg.dependencies(simple_package_uuid) do pkg
            @test pkg.name == "SimplePackage"
            @test isdir(pkg.source)
            @test pkg.is_tracking_path
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
            @test Base.samefile(pkg.source, joinpath(DEPOT_PATH[1], "dev", "Example"))
            @test !pkg.is_tracking_registry
        end
        @test haskey(Pkg.project().dependencies, "Example")
        @test length(Pkg.project().dependencies) == 1
    end
    # Developing an existing package which is tracking a repo should just override.
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", rev="master")
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
    isolate(loaded_depot=true) do
        Pkg.develop("Example")
        Pkg.develop("Example"; shared=false)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test Base.samefile(pkg.source, joinpath(dirname(Pkg.project().path), "dev", "Example"))
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
        # develop using preserve option
        api, args, opts = first(Pkg.pkg"dev --preserve=none Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(;name="Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_NONE)
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
        Pkg.add(name="Example", version="0.3.0")
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
        Pkg.add(name="Example", rev="v0.5.3")
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
    # `instantiate` lonely manifest
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
        Pkg.develop(path=simple_package_path)
        Pkg.develop(path=unregistered_example_path)
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
        Pkg.add(name="Example", version="0.3.0")
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
        Pkg.add(name="Example", version="0.3.0")
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
        Pkg.add(name="Example", version="0.3.0")
        Pkg.update()
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.version > v"0.3.0"
        end
    end
    # `update` should not update `pin`ed packages
    isolate(loaded_depot=true) do
        Pkg.add(name="Example",version="0.3.0")
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
        Pkg.develop(path=path)
        state = Pkg.dependencies()[simple_package_uuid]
        Pkg.update()
        @test Pkg.dependencies()[simple_package_uuid] == state
    end end
    # up and packages tracking repos
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "SimplePackage"))
        Pkg.add(path=path)
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
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl")
        Pkg.develop("Example")
        Pkg.add(name="JSON", version="0.18.0")
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
    # `--fixed` should prevent the target package from being updated, but update other dependencies
    isolate(loaded_depot=true) do
        Pkg.add( name="Example", version="0.3.0")
        Pkg.add( name="JSON", version="0.18.0")
        Pkg.update("JSON"; level=Pkg.UPLEVEL_FIXED)
        Pkg.dependencies(json_uuid) do pkg
            @test pkg.version == v"0.18.0"
        end
        Pkg.dependencies(exuuid) do pkg
            @test pkg.version > v"0.3.0"
        end
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
        Pkg.add(path=path)
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
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl")
        @test_throws PkgError("unable to pin unregistered package `Unregistered [dcb67f36]` to an arbritrary version"
                              ) Pkg.pin(name="Unregistered", version="0.1.0")
    end
    # pinning to an abritrary version should check version exists
    isolate(loaded_depot=true) do
        Pkg.add(name="Example",rev="master")
        @test_throws ResolverError Pkg.pin(name="Example",version="100.0.0")
    end
end

@testset "pin: package state changes" begin
    # regular registered package
    isolate(loaded_depot=true) do
        Pkg.add( name="Example", version="0.3.3")
        Pkg.pin("Example")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_pinned
        end
    end
    # packge tracking repo
    isolate(loaded_depot=true) do
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl")
        Pkg.pin("Unregistered")
        Pkg.dependencies(unregistered_uuid) do pkg
            @test !pkg.is_tracking_registry
            @test pkg.is_pinned
        end
    end
    # versioned pin
    isolate(loaded_depot=true) do
        Pkg.add( name="Example", version="0.3.3")
        Pkg.pin( name="Example", version="0.5.1")
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test pkg.is_pinned
        end
    end
    # pin should check for a valid version number
    isolate(loaded_depot=true) do
        Pkg.add(name="Example", rev="master")
        @test_throws ResolverError Pkg.pin(name="Example",version="100.0.0") # TODO maybe make a PkgError
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
            @test !pkg.is_pinned
        end
    end
    # free package tracking repo
    isolate(loaded_depot=true) do
        Pkg.add( name="Example", rev="master")
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
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl")
        @test_throws PkgError("unable to free unregistered package `Unregistered [dcb67f36]`") Pkg.free("Unregistered")
    end
    isolate(loaded_depot=true) do
        Pkg.develop(url="https://github.com/00vareladavid/Unregistered.jl")
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
        Pkg.add([(;name="Example"),
                 (;name="JSON", version="0.18.0"),])
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
    # rm should not unnecessarily remove compat entries
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "CompatExtras")
        Pkg.activate(path)
        @test haskey(Pkg.Types.Context().env.project.compat, "Aqua")
        @test haskey(Pkg.Types.Context().env.project.compat, "DataFrames")
        Pkg.rm("DataFrames")
        @test !haskey(Pkg.Types.Context().env.project.compat, "DataFrames")
        @test haskey(Pkg.Types.Context().env.project.compat, "Aqua")
    end end
    # rm removes unused recursive depdencies
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        path = copy_test_package(tempdir, "SimplePackage")
        Pkg.develop(path=path)
        Pkg.add(name="JSON", version="0.18.0")
        Pkg.rm("SimplePackage")
        @test haskey(Pkg.dependencies(), markdown_uuid)
        @test !haskey(Pkg.dependencies(), simple_package_uuid)
        @test !haskey(Pkg.dependencies(), exuuid)
        @test haskey(Pkg.dependencies(), json_uuid)
    end end
    # rm manifest mode
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        Pkg.add(name="JSON", version="0.18.0")
        Pkg.rm("Random"; mode=Pkg.PKGMODE_MANIFEST)
        @test haskey(Pkg.dependencies(), exuuid)
        @test !haskey(Pkg.dependencies(), json_uuid)
    end
    # rm nonexistent packages warns but does not error
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        @test_logs (:warn, r"not in project, ignoring") Pkg.rm(name="FooBar", uuid=UUIDs.UUID(0))
        @test_logs (:warn, r"not in manifest, ignoring") Pkg.rm(name="FooBar", uuid=UUIDs.UUID(0); mode=Pkg.PKGMODE_MANIFEST)
    end
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
# # `all` operations
#
@testset "all" begin
    # pin all, free all, rm all packages
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        Pkg.pin(all_pkgs = true)
        Pkg.free(all_pkgs = true)
        Pkg.dependencies(exuuid) do pkg
            @test pkg.name == "Example"
            @test !pkg.is_pinned
        end
        Pkg.add("Profile")
        Pkg.pin("Example")
        Pkg.free(all_pkgs = true) # test that this doesn't error because Profile is already free
        Pkg.rm(all_pkgs = true)
        @test !haskey(Pkg.dependencies(), exuuid)

        # test that the noops don't error
        Pkg.rm(all_pkgs = true)
        Pkg.pin(all_pkgs = true)
        Pkg.free(all_pkgs = true)
    end
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"pin --all")
        @test api == Pkg.pin
        @test isempty(args)
        @test opts == Dict(:all_pkgs => true)

        api, args, opts = first(Pkg.pkg"free --all")
        @test api == Pkg.free
        @test isempty(args)
        @test opts == Dict(:all_pkgs => true)

        api, args, opts = first(Pkg.pkg"rm --all")
        @test api == Pkg.rm
        @test isempty(args)
        @test opts == Dict(:all_pkgs => true)
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

    # Test package that fails build
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        package_path = copy_test_package(tempdir, "FailBuild")
        Pkg.activate(package_path)
        @test_throws PkgError Pkg.build()
    end end

    # Build log location
    isolate(loaded_depot=true) do; mktempdir() do tmp
        path = git_init_package(tmp, joinpath(@__DIR__, "test_packages", "FailBuild"))
        # Log file in the directory when it is deved
        Pkg.develop(path=path; io=devnull)
        log_file_dev = joinpath(path, "deps", "build.log")
        @test !isfile(log_file_dev)
        @test_throws PkgError Pkg.build("FailBuild"; io=devnull)
        @test isfile(log_file_dev)
        @test occursin("oops", read(log_file_dev, String))
        # Log file in scratchspace when added
        addpath = dirname(dirname(Base.find_package("FailBuild")))
        log_file_add = joinpath(path, "deps", "build.log")
        @test_throws PkgError Pkg.add(path=path; io=devnull)
        @test !isfile(joinpath(Base.find_package("FailBuild"), "..", "..", "deps", "build.log"))
        log_file_add = joinpath(DEPOT_PATH[1], "scratchspaces",
            "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "f99d57aad0e5eb2434491b47bac92bb88d463001", "build.log")
        @test isfile(log_file_add)
        @test occursin("oops", read(log_file_add, String))
    end end
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
        api, opts = first(Pkg.pkg"gc --all")
        @test api == Pkg.gc
        @test opts[:collect_delay] == Hour(0)
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

        api, arg, opts = first(Pkg.pkg"precompile Foo")
        @test api == Pkg.precompile
        @test arg == "Foo"
        @test isempty(opts)

        api, arg1, arg2, opts = first(Pkg.pkg"precompile Foo Bar")
        @test api == Pkg.precompile
        @test arg1 == "Foo"
        @test arg2 == "Bar"
        @test isempty(opts)
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
        @test api == Pkg.API.generate
        @test arg == "Foo"
        @test isempty(opts)
        mktempdir() do dir
            api, arg, opts = first(Pkg.REPLMode.pkgstr("generate $(joinpath(dir, "Foo"))"))
            @test arg == joinpath(dir, "Foo")
            # issue #1435
            if !Sys.iswindows()
                withenv("HOME" => dir) do
                    api, arg, opts = first(Pkg.REPLMode.pkgstr("generate ~/Bar"))
                    @test arg == joinpath(dir, "Bar")
                end
            end
        end
    end
end

#
# # Status
#
@testset "Pkg.status" begin
    # other
    isolate(loaded_depot=true) do
        @test_deprecated Pkg.status(Pkg.PKGMODE_MANIFEST)
        @test_logs (:warn, r"diff option only available") match_mode=:any Pkg.status(diff=true)
    end
    # State changes
    isolate(loaded_depot=true) do
        io = IOBuffer()
        # Basic Add
        Pkg.add(Pkg.PackageSpec(; name="Example", version="0.3.0"); io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] \+ Example v0\.3\.0", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] \+ Example v0\.3\.0", output)
        # Double add should not claim "Updating"
        Pkg.add(Pkg.PackageSpec(; name="Example", version="0.3.0"); io=io)
        output = String(take!(io))
        @test occursin(r"No Changes to `.+Project\.toml`", output)
        @test occursin(r"No Changes to `.+Manifest\.toml`", output)
        # From tracking registry to tracking repo
        Pkg.add(Pkg.PackageSpec(; name="Example", rev="master"); io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v0\.3\.0 ⇒ v\d\.\d\.\d `https://github\.com/JuliaLang/Example\.jl\.git#master`", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v0\.3\.0 ⇒ v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master`", output)
        # From tracking repo to tracking path
        Pkg.develop("Example"; io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github\.com/JuliaLang/Example\.jl\.git#master` ⇒ v\d\.\d\.\d `.+`", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github\.com/JuliaLang/Example\.jl\.git#master` ⇒ v\d\.\d\.\d `.+`", output)
        # From tracking path to tracking repo
        Pkg.add(Pkg.PackageSpec(; name="Example", rev="master"); io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `.+` ⇒ v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master`", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `.+` ⇒ v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master`", output)
        # From tracking repo to tracking registered version
        Pkg.free("Example"; io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v\d\.\d\.\d", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v\d\.\d\.\d", output)
        # Removing registered version
        Pkg.rm("Example"; io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] - Example v\d\.\d\.\d", output)
        @test occursin(r"Updating `.+Manifest.toml`", output)
        @test occursin(r"\[7876af07\] - Example v\d\.\d\.\d", output)

        # Pinning a registered package
        Pkg.add("Example")
        Pkg.pin("Example"; io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d ⇒ v\d\.\d\.\d ⚲", output)
        @test occursin(r"Updating `.+Manifest.toml`", output)

        # Free a pinned package
        Pkg.free("Example"; io=io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d ⚲ ⇒ v\d\.\d\.\d", output)
        @test occursin(r"Updating `.+Manifest.toml`", output)
    end
    # Project Status API
    isolate(loaded_depot=true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io=devnull) # load reg before io capturing
        io = PipeBuffer()
        ## empty project
        Pkg.status(;io=io)
        @test occursin(r"Status `.+Project.toml` \(empty project\)", readline(io))
        ## loaded project
        Pkg.add("Markdown")
        Pkg.add( name="JSON", version="0.18.0")
        Pkg.develop("Example")
        Pkg.add(url="https://github.com/00vareladavid/Unregistered.jl")
        Pkg.status(; io = io)
        @test occursin(r"Status `.+Project\.toml`", readline(io))
        @test occursin(r"\[7876af07\] Example\s*v\d\.\d\.\d\s*`.+`", readline(io))
        @test occursin(r"\[682c06a0\] JSON\s*v0.18.0", readline(io))
        @test occursin(r"\[dcb67f36\] Unregistered\s*v\d\.\d\.\d\s*`https://github\.com/00vareladavid/Unregistered\.jl#master`", readline(io))
        @test occursin(r"\[d6f4376e\] Markdown", readline(io))
    end
    ## status warns when package not installed
    isolate() do
        Pkg.Registry.add(Pkg.RegistrySpec[], io=devnull) # load reg before io capturing
        Pkg.activate(joinpath(@__DIR__, "test_packages", "Status"))
        io = PipeBuffer()
        Pkg.status(; io=io)
        @test occursin(r"Status `.+Project.toml`", readline(io))
        @test occursin(r"^→⌃ \[7876af07\] Example\s*v\d\.\d\.\d", readline(io))
        @test occursin(r"^   \[d6f4376e\] Markdown", readline(io))
        @test "Info Packages marked with → are not downloaded, use `instantiate` to download" == strip(readline(io))
        @test "Info Packages marked with ⌃ have new versions available" == strip(readline(io))
        Pkg.status(;io=io, mode=Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest.toml`", readline(io))
        @test occursin(r"^→⌃ \[7876af07\] Example\s*v\d\.\d\.\d", readline(io))
        @test occursin(r"^   \[2a0f44e3\] Base64", readline(io))
        @test occursin(r"^   \[d6f4376e\] Markdown", readline(io))
        @test "Info Packages marked with → are not downloaded, use `instantiate` to download" == strip(readline(io))
        @test "Info Packages marked with ⌃ have new versions available" == strip(readline(io))
        Pkg.instantiate(;io=devnull) # download Example
        Pkg.status(;io=io, mode=Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest.toml`", readline(io))
        @test occursin(r"^⌃ \[7876af07\] Example\s*v\d\.\d\.\d", readline(io))
        @test occursin(r"^  \[2a0f44e3\] Base64", readline(io))
        @test occursin(r"^  \[d6f4376e\] Markdown", readline(io))
        @test "Info Packages marked with ⌃ have new versions available" == strip(readline(io))
    end
    # Manifest Status API
    isolate(loaded_depot=true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io=devnull) # load reg before io capturing
        io = PipeBuffer()
        ## empty manifest
        Pkg.status(;io=io, mode=Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest\.toml` \(empty manifest\)", readline(io))
        # loaded manifest
        Pkg.add( name="Example", version="0.3.0")
        Pkg.add("Markdown")
        Pkg.status(; io=io, mode=Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest.toml`", readline(io))
        @test occursin(r"\[7876af07\] Example\s*v0\.3\.0", readline(io))
        @test occursin(r"\[2a0f44e3\] Base64", readline(io))
        @test occursin(r"\[d6f4376e\] Markdown", readline(io))
    end
    # Diff API
    isolate(loaded_depot=true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io=devnull) # load reg before io capturing
        io = PipeBuffer()
        projdir = dirname(Pkg.project().path)
        mkpath(projdir)
        git_init_and_commit(projdir)
        ## empty project + empty diff
        Pkg.status(; io=io, diff=true)
        @test occursin(r"No Changes to `.+Project\.toml`", readline(io))
        Pkg.status(; io=io, mode=Pkg.PKGMODE_MANIFEST, diff=true)
        @test occursin(r"No Changes to `.+Manifest\.toml`", readline(io))
        ### empty diff + filter
        Pkg.status("Example"; io=io, diff=true)
        @test occursin(r"No Changes to `.+Project\.toml`", readline(io))
        ## non-empty project but empty diff
        Pkg.add("Markdown")
        git_init_and_commit(dirname(Pkg.project().path))
        Pkg.status(; io=io, diff=true)
        @test occursin(r"No Changes to `.+Project\.toml`", readline(io))
        Pkg.status(; io=io, mode=Pkg.PKGMODE_MANIFEST, diff=true)
        @test occursin(r"No Changes to `.+Manifest\.toml`", readline(io))
        ### filter should still show "empty diff"
        Pkg.status("Example"; io=io, diff=true)
        @test occursin(r"No Changes to `.+Project\.toml`", readline(io))
        ## non-empty project + non-empty diff
        Pkg.rm("Markdown")
        Pkg.add(name="Example", version="0.3.0")
        ## diff project
        Pkg.status(; io=io, diff=true)
        @test occursin(r"Diff `.+Project\.toml`", readline(io))
        @test occursin(r"\[7876af07\] \+ Example\s*v0\.3\.0", readline(io))
        @test occursin(r"\[d6f4376e\] - Markdown", readline(io))
        @test occursin("Info Packages marked with ⌃ have new versions available", readline(io))
        ## diff manifest
        Pkg.status(; io=io, mode=Pkg.PKGMODE_MANIFEST, diff=true)
        @test occursin(r"Diff `.+Manifest.toml`", readline(io))
        @test occursin(r"\[7876af07\] \+ Example\s*v0\.3\.0", readline(io))
        @test occursin(r"\[2a0f44e3\] - Base64", readline(io))
        @test occursin(r"\[d6f4376e\] - Markdown", readline(io))
        @test occursin("Info Packages marked with ⌃ have new versions available", readline(io))
        ## diff project with filtering
        Pkg.status("Markdown"; io=io, diff=true)
        @test occursin(r"Diff `.+Project\.toml`", readline(io))
        @test occursin(r"\[d6f4376e\] - Markdown", readline(io))
        ## empty diff + filter
        Pkg.status("Base64"; io=io, diff=true)
        @test occursin(r"No Matches in diff for `.+Project\.toml`", readline(io))
        ## diff manifest with filtering
        Pkg.status("Base64"; io=io, mode=Pkg.PKGMODE_MANIFEST, diff=true)
        @test occursin(r"Diff `.+Manifest.toml`", readline(io))
        @test occursin(r"\[2a0f44e3\] - Base64", readline(io))
        ## manifest diff + empty filter
        Pkg.status("FooBar"; io=io, mode=Pkg.PKGMODE_MANIFEST, diff=true)
        @test occursin(r"No Matches in diff for `.+Manifest.toml`", readline(io))
    end
    # Outdated API
    isolate(loaded_depot=true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io=devnull) # load reg before io capturing
        Pkg.add("Example"; io=devnull)
        v = Pkg.dependencies()[exuuid].version
        io = IOBuffer()
        Pkg.add(Pkg.PackageSpec(name="Example", version="0.4.0"); io=devnull)
        Pkg.status(; outdated=true, io=io)
        str = String(take!(io))
        @test occursin(Regex("⌃\\s*\\[7876af07\\] Example\\s*v0.4.0\\s*\\(<v$v\\)"), str)
        open(Base.active_project(), "a") do io
            write(io, """
                  [compat]
                  Example = "0.4.1"
            """)
        end
        Pkg.status(; outdated=true, io=io)
        str = String(take!(io))
        @test occursin(Regex("⌃\\s*\\[7876af07\\] Example\\s*v0.4.0\\s*\\[<v0.4.1\\], \\(<v$v\\)"), str)
    end
end

#
# # compat
#
@testset "Pkg.compat" begin
    # State changes
    isolate(loaded_depot=true) do
        Pkg.add("Example")
        iob = IOBuffer()
        Pkg.status(compat=true, io = iob)
        output = String(take!(iob))
        @test occursin(r"Compat `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] *Example *none", output)
        @test occursin(r"julia *none", output)

        Pkg.compat("Example", "0.2,0.3")
        @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") == "0.2,0.3"
        Pkg.status(compat=true, io = iob)
        output = String(take!(iob))
        @test occursin(r"Compat `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] *Example *0.2,0.3", output)
        @test occursin(r"julia *none", output)

        Pkg.compat("Example", nothing)
        Pkg.compat("julia", "1.8")
        @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") == nothing
        @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "julia") == "1.8"
        Pkg.status(compat=true, io = iob)
        output = String(take!(iob))
        @test occursin(r"Compat `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] *Example *none", output)
        @test occursin(r"julia *1.8", output)
    end
end


#
# # Caching
#
@testset "Repo caching" begin
    default_branch = LibGit2.getconfig("init.defaultBranch", "master")
    # Add by URL should not overwrite files.
    isolate(loaded_depot=true) do
        Pkg.add(url="https://github.com/JuliaLang/Example.jl")
        s1, t1, c1 = 0, 0, 0
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            s1 = pkg.source
            c1 = Pkg.Types.add_repo_cache_path(pkg.git_source)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            t1 = mtime(pkg.source)
        end
        Pkg.add(url="https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            @test Base.samefile(pkg.source, s1)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            @test Pkg.Types.add_repo_cache_path(pkg.git_source) == c1
            @test mtime(pkg.source) == t1
        end
    end
    # Add by URL should not overwrite files, even across projects
    isolate(loaded_depot=true) do
        # Make sure we have everything downloaded
        Pkg.add(url="https://github.com/JuliaLang/Example.jl")
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
        Pkg.add(url="https://github.com/JuliaLang/Example.jl")
        Pkg.dependencies(exuuid) do pkg
            @test isdir(pkg.source)
            @test Base.samefile(pkg.source, s1)
            @test isdir(Pkg.Types.add_repo_cache_path(pkg.git_source))
            @test Pkg.Types.add_repo_cache_path(pkg.git_source) == c1
            @test mtime(pkg.source) == t1
        end
    end
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        empty_package = UUID("26187899-7657-4a90-a2f6-e79e0214bedc")
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "EmptyPackage"))
        Pkg.add(path=path)
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
                @test original_master == string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/$(default_branch)")))
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
                @test new_commit == string(LibGit2.GitHash(LibGit2.GitObject(repo, "refs/heads/$(default_branch)")))
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
    # pruning manifest
    dir = joinpath(@__DIR__, "manifest", "unpruned")
    isolate(loaded_depot=true) do
        mktempdir() do tmp
            cp(dir, joinpath(tmp, "unpruned"))
            Pkg.activate(joinpath(tmp, "unpruned"))
            Pkg.resolve()
            @test !occursin("Crayons", read(joinpath(tmp, "unpruned", "Manifest.toml"), String))
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
            @test a == b
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

@testset "cycles" begin
    isolate(loaded_depot=true) do
        cd_tempdir() do dir
            Pkg.generate("Cycle_A")
            cycle_a_uuid = Pkg.Types.read_project("Cycle_A/Project.toml").uuid
            Pkg.generate("Cycle_B")
            cycle_b_uuid = Pkg.Types.read_project("Cycle_A/Project.toml").uuid
            Pkg.activate("Cycle_A")
            Pkg.develop(Pkg.PackageSpec(path="Cycle_B"))
            Pkg.activate("Cycle_B")
            Pkg.develop(Pkg.PackageSpec(path="Cycle_A"))
            manifest_b = Pkg.Types.read_manifest("Cycle_B/Manifest.toml")
            @test cycle_a_uuid in keys(manifest_b)
            @test_broken !(cycle_b_uuid in keys(manifest_b))
        end
    end
end
#
# # Other
#
# Note: these tests should be run on clean depots
@testset "downloads" begin
    for v in (nothing, "true")
        withenv("JULIA_PKG_USE_CLI_GIT" => v) do
            # libgit2 downloads
            isolate() do
                Pkg.add("Example"; use_git_for_all_downloads=true)
                @test haskey(Pkg.dependencies(), exuuid)
                @eval import $(Symbol(TEST_PKG.name))
                @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
                Pkg.rm(TEST_PKG.name)
            end
            isolate() do
                @testset "libgit2 downloads" begin
                    Pkg.add(TEST_PKG.name; use_git_for_all_downloads=true)
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
    end
end

@testset "package name in resolver errors" begin
    isolate(loaded_depot=true) do
        try
            Pkg.add(name="Example", version = v"55")
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
        # invalid options
        @test_throws PkgError Pkg.pkg"rm --minor Example"
        @test_throws PkgError Pkg.pkg"pin --project Example"
        # conflicting options
        @test_throws PkgError Pkg.pkg"up --major --minor"
        @test_throws PkgError Pkg.pkg"rm --project --manifest"
    end
end

tree_hash(root::AbstractString; kwargs...) = bytes2hex(@inferred Pkg.GitTools.tree_hash(root; kwargs...))

@testset "git tree hash computation" begin
    mktempdir() do dir
        # test "well known" empty tree hash
        @test "4b825dc642cb6eb9a060e54bf8d69288fbee4904" == tree_hash(dir)
        # create a text file
        file = joinpath(dir, "hello.txt")
        open(file, write=true) do io
            println(io, "Hello, world.")
        end
        chmod(file, 0o644)
        # reference hash generated with command-line git
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == tree_hash(dir)
        # test with various executable bits set
        chmod(file, 0o645) # other x bit doesn't matter
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == tree_hash(dir)
        chmod(file, 0o654) # group x bit doesn't matter
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == tree_hash(dir)
        chmod(file, 0o744) # user x bit matters
        @test "952cfce0fb589c02736482fa75f9f9bb492242f8" == tree_hash(dir)
    end

    # Test for empty directory hashing
    mktempdir() do dir
        @test "4b825dc642cb6eb9a060e54bf8d69288fbee4904" == tree_hash(dir)

        # Directories containing other empty directories are also empty
        mkdir(joinpath(dir, "foo"))
        mkdir(joinpath(dir, "foo", "bar"))
        @test "4b825dc642cb6eb9a060e54bf8d69288fbee4904" == tree_hash(dir)

        # Directories containing symlinks (even if they point to other directories)
        # are NOT empty:
        if !Sys.iswindows()
            symlink("bar", joinpath(dir, "foo", "bar_link"))
            @test "8bc80be82b2ae4bd69f50a1a077a81b8678c9024" == tree_hash(dir)
        end
    end

    # Test for directory with .git hashing
    mktempdir() do dir
        mkdir(joinpath(dir, "Foo"))
        mkdir(joinpath(dir, "FooGit"))
        mkdir(joinpath(dir, "FooGit", ".git"))
        write(joinpath(dir, "Foo", "foo"), "foo")
        chmod(joinpath(dir, "Foo", "foo"), 0o644)
        write(joinpath(dir, "FooGit", "foo"), "foo")
        chmod(joinpath(dir, "FooGit", "foo"), 0o644)
        write(joinpath(dir, "FooGit", ".git", "foo"), "foo")
        chmod(joinpath(dir, "FooGit", ".git", "foo"), 0o644)
        @test tree_hash(joinpath(dir, "Foo")) ==
              tree_hash(joinpath(dir, "FooGit")) ==
              "2f42e2c1c1afd4ef8c66a2aaba5d5e1baddcab33"
    end

    # Test for symlinks that are a prefix of another directory, causing sorting issues
    if !Sys.iswindows()
        mktempdir() do dir
            mkdir(joinpath(dir, "5.28.1"))
            write(joinpath(dir, "5.28.1", "foo"), "")
            chmod(joinpath(dir, "5.28.1", "foo"), 0o644)
            symlink("5.28.1", joinpath(dir, "5.28"))

            @test tree_hash(dir) == "5e50a4254773a7c689bebca79e2954630cab9c04"
       end
   end
end

@testset "multiple registries overlapping version ranges for different versions" begin
    isolate(loaded_depot=true) do
        # Add a new registry
        dp = DEPOT_PATH[1]
        newreg = joinpath(dp, "registries", "NewReg")
        mkpath(newreg)
        write(joinpath(newreg, "Registry.toml"), """
        name = "NewReg"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "whydoineedthis?"

        [packages]
        7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
        """)
        example_path = joinpath(newreg, "E", "Example")
        mkpath(example_path)
        write(joinpath(example_path, "Package.toml"), """
        name = "Example"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        repo = "https://github.com/JuliaLang/Example.jl.git"
        """)

        write(joinpath(example_path, "Versions.toml"), """
        ["0.99.99"]
        git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
        """)

        write(joinpath(example_path, "Compat.toml"), """
        ["0"]
        julia = "0.0"
        """)

        # This shouldn't cause a resolver error
        Pkg.add("Example")
    end
end

@testset "not collecting multiple package instances #1570" begin
    isolate(loaded_depot=true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            Pkg.generate("B")
            Pkg.activate("B")
            Pkg.develop(Pkg.PackageSpec(path="A"))
            Pkg.activate(".")
            Pkg.develop(Pkg.PackageSpec(path="A"))
            Pkg.develop(Pkg.PackageSpec(path="B"))
        end
    end
end

@testset "cyclic dependency graph" begin
    isolate(loaded_depot=true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            Pkg.generate("B")
            Pkg.activate("A")
            Pkg.develop(path="B")
            git_init_and_commit("A")
            Pkg.activate("B")
            # This shouldn't error even though A has a dependency on B
            Pkg.add(path="A")
        end
    end
    # test #2302
    isolate(loaded_depot=true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            Pkg.generate("B")
            git_init_and_commit("B")
            Pkg.develop(path="B")
            Pkg.activate("A")
            Pkg.add(path="B")
            git_init_and_commit("A")
            Pkg.activate("B")
            # This shouldn't error even though A has a dependency on B
            Pkg.add(path="A")
        end
    end
end

@testset "Offline mode" begin
    isolate(loaded_depot=false) do
        # cache this version
        Pkg.add(Pkg.PackageSpec(uuid=exuuid, version=v"0.5.1"))
        @test Pkg.dependencies()[exuuid].version == v"0.5.1"
        Pkg.offline()
        # Pkg.update() should not error/warn and keep Example at 0.5.1
        @test_logs Pkg.update()
        @test Pkg.dependencies()[exuuid].version == v"0.5.1"
        try
            Pkg.add(Pkg.PackageSpec(uuid=exuuid, version=v"0.5.3"))
        catch e
            @test e isa ResolverError
            # `\S*` in regex below will allow for ANSI color escape codes in the logs
            @test occursin(r"possible versions are: \S*0\.5\.1\S* or uninstalled", e.msg)
        end
        Pkg.offline(false)
    end
end

@testset "relative depot path" begin
    isolate(loaded_depot=false) do
        mktempdir() do tmp
            ENV["JULIA_DEPOT_PATH"] = "tmp"
            Base.init_depot_path()
            Pkg.Registry.DEFAULT_REGISTRIES[1].url = Utils.REGISTRY_DIR
            Pkg.Registry.DEFAULT_REGISTRIES[1].path = nothing
            cp(joinpath(@__DIR__, "test_packages", "BasicSandbox"), joinpath(tmp, "BasicSandbox"))
            git_init_and_commit(joinpath(tmp, "BasicSandbox"))
            cd(tmp) do
                Pkg.add(path="BasicSandbox")
            end
        end
    end
end

using Pkg.Types: is_stdlib
@testset "is_stdlib() across versions" begin
    networkoptions_uuid = UUID("ca575930-c2e3-43a9-ace4-1e988b2c1908")
    pkg_uuid = UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")

    # Assume we're running on v1.6+
    @test is_stdlib(networkoptions_uuid)
    @test is_stdlib(networkoptions_uuid, v"1.6")
    @test !is_stdlib(networkoptions_uuid, v"1.5")
    @test !is_stdlib(networkoptions_uuid, v"1.0.0")
    @test !is_stdlib(networkoptions_uuid, v"0.7")
    @test !is_stdlib(networkoptions_uuid, nothing)

    # Pkg is an unregistered stdlib
    @test is_stdlib(pkg_uuid)
    @test is_stdlib(pkg_uuid, v"1.0")
    @test is_stdlib(pkg_uuid, v"1.6")
    @test is_stdlib(pkg_uuid, v"999.999.999")
    @test is_stdlib(pkg_uuid, v"0.7")
    @test is_stdlib(pkg_uuid, nothing)
end

@testset "Pkg.add() with julia_version" begin
    # A package with artifacts that went from normal package -> stdlib
    gmp_jll_uuid = "781609d7-10c4-51f6-84f2-b8444358ff6d"
    # A package that has always only ever been an stdlib
    linalg_uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
    # A package that went from normal package - >stdlib
    networkoptions_uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"

    function get_manifest_block(name)
        manifest_path = joinpath(dirname(Base.active_project()), "Manifest.toml")
        @test isfile(manifest_path)
        deps = Base.get_deps(TOML.parsefile(manifest_path))
        @test haskey(deps, name)
        return only(deps[name])
    end

    isolate(loaded_depot=true) do
        # Next, test that if we ask for `v1.5` it DOES have a version, and that GMP_jll installs v6.1.X
        Pkg.add(["NetworkOptions", "GMP_jll"]; julia_version=v"1.5")
        no_block = get_manifest_block("NetworkOptions")
        @test haskey(no_block, "uuid")
        @test no_block["uuid"] == networkoptions_uuid
        @test haskey(no_block, "version")

        gmp_block = get_manifest_block("GMP_jll")
        @test haskey(gmp_block, "uuid")
        @test gmp_block["uuid"] == gmp_jll_uuid
        @test haskey(gmp_block, "version")
        @test startswith(gmp_block["version"], "6.1.2")

        # Test that the artifact of GMP_jll contains the right library
        @test haskey(gmp_block, "git-tree-sha1")
        gmp_jll_dir = Pkg.Operations.find_installed("GMP_jll", Base.UUID(gmp_jll_uuid), Base.SHA1(gmp_block["git-tree-sha1"]))
        @test isdir(gmp_jll_dir)
        artifacts_toml = joinpath(gmp_jll_dir, "Artifacts.toml")
        @test isfile(artifacts_toml)
        meta = artifact_meta("GMP", artifacts_toml)

        # `meta` can be `nothing` on some of our newer platforms; we _know_ this should
        # not be the case on the following platforms, so we check these explicitly to
        # ensure that we haven't accidentally broken something, and then we gate some
        # following tests on whether or not `meta` is `nothing`:
        for arch in ("x86_64", "i686"), os in ("linux", "mac", "windows")
            if platforms_match(HostPlatform(), Platform(arch, os))
                @test meta !== nothing
            end
        end

        # These tests require a matching platform artifact for this old version of GMP_jll,
        # which is not the case on some of our newer platforms.
        if meta !== nothing
            gmp_artifact_path = artifact_path(Base.SHA1(meta["git-tree-sha1"]))
            @test isdir(gmp_artifact_path)

            # On linux, we can check the filename to ensure it's grabbing the correct library
            if Sys.islinux()
                libgmp_filename = joinpath(gmp_artifact_path, "lib", "libgmp.so.10.3.2")
                @test isfile(libgmp_filename)
            end
        end
    end

    # Next, test that if we ask for `v1.6`, GMP_jll gets `v6.2.0`, and for `v1.7`, it gets `v6.2.1`
    function do_gmp_test(julia_version, gmp_version)
        isolate(loaded_depot=true) do
            Pkg.add("GMP_jll"; julia_version)
            gmp_block = get_manifest_block("GMP_jll")
            @test haskey(gmp_block, "uuid")
            @test gmp_block["uuid"] == gmp_jll_uuid
            @test haskey(gmp_block, "version")
            @test startswith(gmp_block["version"], string(gmp_version))
        end
    end
    do_gmp_test(v"1.6", v"6.2.0")
    do_gmp_test(v"1.7", v"6.2.1")

    isolate(loaded_depot=true) do
        # Next, test that if we ask for `nothing`, NetworkOptions has a `version` but `LinearAlgebra` does not.
        Pkg.add(["LinearAlgebra", "NetworkOptions"]; julia_version=nothing)
        no_block = get_manifest_block("NetworkOptions")
        @test haskey(no_block, "uuid")
        @test no_block["uuid"] == networkoptions_uuid
        @test haskey(no_block, "version")
        linalg_block = get_manifest_block("LinearAlgebra")
        @test haskey(linalg_block, "uuid")
        @test linalg_block["uuid"] == linalg_uuid
        @test !haskey(linalg_block, "version")
    end

    isolate(loaded_depot=true) do
        # Next, test that stdlibs do not get dependencies from the registry
        # NOTE: this test depends on the fact that in Julia v1.6+ we added
        # "fake" JLLs that do not depend on Pkg while the "normal" p7zip_jll does.
        # A future p7zip_jll in the registry may not depend on Pkg, so be sure
        # to verify your assumptions when updating this test.
        Pkg.add("p7zip_jll")
        p7zip_jll_uuid = UUID("3f19e933-33d8-53b3-aaab-bd5110c3b7a0")
        @test !("Pkg" in keys(Pkg.dependencies()[p7zip_jll_uuid].dependencies))
    end
end

@testset "Issue #2931" begin
    isolate(loaded_depot=false) do
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
            rm(pkg_dir; recursive=true, force=true)

            # (Re-)download sources
            Pkg.Operations.download_source(ctx)

            # Make sure the package directory is there
            @test isdir(pkg_dir)
        end
    end
end

if :version in fieldnames(Base.PkgOrigin)
@testset "sysimage functionality" begin
    old_sysimage_modules = copy(Base._sysimage_modules)
    old_pkgorigins = copy(Base.pkgorigins)
    try
        # Fake having a packages in the sysimage.
        json_pkgid = Base.PkgId(json_uuid, "JSON")
        push!(Base._sysimage_modules, json_pkgid)
        Base.pkgorigins[json_pkgid] = Base.PkgOrigin(nothing, nothing, v"0.20.1")
        isolate(loaded_depot=true) do
            Pkg.add("JSON"; io=devnull)
            Pkg.dependencies(json_uuid) do pkg
                pkg.version == v"0.20.1"
            end
            io = IOBuffer()
            Pkg.status(; outdated=true, io=io)
            str = String(take!(io))
            @test occursin("⌅ [682c06a0] JSON v0.20.1", str)
            @test occursin("[sysimage]", str)

            @test_throws PkgError Pkg.add(name="JSON", rev="master"; io=devnull)
            @test_throws PkgError Pkg.develop("JSON"; io=devnull)

            Pkg.respect_sysimage_versions(false)
            Pkg.add("JSON"; io=devnull)
            Pkg.dependencies(json_uuid) do pkg
                pkg.version != v"0.20.1"
            end
        end
    finally
        copy!(Base._sysimage_modules, old_sysimage_modules)
        copy!(Base.pkgorigins, old_pkgorigins)
        Pkg.respect_sysimage_versions(true)
    end
end
end

end #module
