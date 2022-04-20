module SandboxTests
import ..Pkg # ensure we are using the correct Pkg

# Order-dependence in the tests, so we delay this until we need it
if Base.find_package("Preferences") === nothing
    @info "Installing Preferences for Pkg tests"
    Pkg.add("Preferences") # Needed for sandbox and artifacts tests
end

using Test
using UUIDs
using Pkg
using Preferences

using ..Utils
test_test(fn, name; kwargs...) = Pkg.test(name; test_fn=fn, kwargs...)
test_test(fn; kwargs...)       = Pkg.test(;test_fn=fn, kwargs...)

@testset "Basic `test` sandboxing" begin
    # also indirectly checks that test `compat` is obeyed
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "SandboxFallback2")
        proj = joinpath(tmp, "SandboxFallback2")
        Pkg.activate(proj)
        withenv("JULIA_PROJECT" => proj) do; test_test("Unregistered") do
            json = get(Pkg.Types.Context().env.manifest, UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6"), nothing)
            @test json !== nothing
            @test json.version == v"0.20.0"
            # test that the active project is the tmp one even though
            # JULIA_PROJECT might be set
            @test !haskey(ENV, "JULIA_PROJECT")
            @test Base.active_project() != proj
            @test Base.LOAD_PATH[1] == "@"
            @test startswith(Base.active_project(), Base.LOAD_PATH[2])
        end end
    end end
    # test dependencies should be preserved, when possible
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "Sandbox_PreserveTestDeps")
        Pkg.activate(joinpath(tmp, "Sandbox_PreserveTestDeps"))
        test_test("Foo") do
            x = get(Pkg.Types.Context().env.manifest, UUID("7876af07-990d-54b4-ab0e-23690620f79a"), nothing)
            @test x !== nothing
            @test x.version == v"0.4.0"
        end
    end end
end

@testset "Preferences sandboxing without test/Project.toml" begin
    # Preferences should be copied over into sandbox
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "Sandbox_PreservePreferences")
        Pkg.activate(joinpath(tmp, "Sandbox_PreservePreferences"))
        test_test() do
            uuid =  UUID("3872bf94-3adb-11e9-01dc-bf80c7641364")
            @test !Preferences.has_preference(uuid, "does_not_exist")
            @test Preferences.load_preference(uuid, "tree") == "birch"
            @test Preferences.load_preference(uuid, "default") === nothing
        end
    end end
end

@testset "Preferences sandboxing with test/Project.toml" begin
    # Preferences should be copied over into sandbox
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "Sandbox_PreservePreferences")
        spp_uuid = UUID("3872bf94-3adb-11e9-01dc-bf80c7641364")
        Pkg.activate(joinpath(tmp, "Sandbox_PreservePreferences"))

        # Create fake test/Project.toml and test/LocalPreferences.toml
        open(joinpath(tmp, "Sandbox_PreservePreferences", "test", "Project.toml"), write=true) do io
            print(io, """
            [deps]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            """)
        end
        Preferences.set_preferences!(
            joinpath(tmp, "Sandbox_PreservePreferences", "test", "LocalPreferences.toml"),
            "Sandbox_PreservePreferences",
            "scent" => "juniper",
        )

        # This test should have a set of preferences that have nothing to do with those
        # exported within `Sandbox_PreservePreferences/Project.toml`
        test_test() do
            @test !Preferences.has_preference(spp_uuid, "does_not_exist")
            # Because we are testing with the project set as the active project, we inherit
            # preferences set in the SPP project
            @test Preferences.load_preference(spp_uuid, "tree") === "birch"
            @test Preferences.load_preference(spp_uuid, "scent") == "juniper"
            @test Preferences.load_preference(spp_uuid, "default") === nothing
        end

        # Test that `Pkg.test()` layers the test project onto the `LOAD_PATH`,
        # so that preferences set in the calling environment can leak through.
        mktempdir() do outer_layer
            # Create a fake project that references SPP
            open(joinpath(outer_layer, "Project.toml"), write=true) do io
                println(io, """
                    [deps]
                    Sandbox_PreservePreferences = "$(spp_uuid)"

                    [preferences.Sandbox_PreservePreferences]
                    tree = "pine"
                    scent = "shadowed"
                """)
            end

            # Use `/` on windows as well
            spp_path = joinpath(tmp, "Sandbox_PreservePreferences")
            if Sys.iswindows()
                spp_path = replace(spp_path, "\\" => "/")
            end
            open(joinpath(outer_layer, "Manifest.toml"), write=true) do io
                println(io, """
                [[Sandbox_PreservePreferences]]
                path = "$(spp_path)"
                uuid = "$(spp_uuid)"
                """)
            end

            Pkg.activate(outer_layer)
            test_test("Sandbox_PreservePreferences") do
                # The tree that leaks through is from the outer layer,
                # rather than the overall project
                @test Preferences.load_preference(spp_uuid, "tree") === "pine"
                # The scent is still the inner test preference, since that takes priority.
                @test Preferences.load_preference(spp_uuid, "scent") == "juniper"
            end
        end
    end end
end

@testset "Nested Preferences sandboxing" begin
    # Preferences should be copied over into sandbox
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "Sandbox_PreservePreferences")
        Pkg.activate(joinpath(tmp, "Sandbox_PreservePreferences"))
        test_test("Foo") do
            uuid =  UUID("48898bec-3adb-11e9-02a6-a164ba74aeae")
            @test !Preferences.has_preference(uuid, "does_not_exist")
            @test Preferences.load_preference(uuid, "toy") == "car"
            @test Preferences.load_preference(uuid, "tree") == "birch"
            @test Preferences.load_preference(uuid, "default") === nothing
        end
    end end
end

@testset "Basic `build` sandbox" begin
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "BasicSandbox")
        Pkg.activate(joinpath(tmp, "BasicSandbox"))
        Pkg.build()
    end end
end

end # module
