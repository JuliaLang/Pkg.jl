module PreferencesTests
import ..Pkg
import Base: UUID
using ..Utils, ..Pkg.TOML
using Test, Pkg.Preferences
import Pkg.Scratch: scratch_dir

@testset "Preferences" begin
    # Create a temporary package, store some preferences within it.
    with_temp_env() do project_dir
        uuid = UUID(UInt128(0))
        save_preferences!(uuid, Dict("foo" => "bar"))

        project_path = joinpath(project_dir, "Project.toml")
        @test isfile(project_path)
        proj = Pkg.Types.parse_toml(project_path)
        @test haskey(proj, "preferences")
        @test isa(proj["preferences"], Dict)
        @test haskey(proj["preferences"], string(uuid))
        @test isa(proj["preferences"][string(uuid)], Dict)
        @test proj["preferences"][string(uuid)]["foo"] == "bar"

        prefs = modify_preferences!(uuid) do prefs
            prefs["foo"] = "baz"
            prefs["spoon"] = [Dict("qux" => "idk")]
        end
        @test prefs == load_preferences(uuid)

        clear_preferences!(uuid)
        proj = Pkg.Types.parse_toml(project_path)
        @test !haskey(proj, "preferences")
    end

    temp_pkg_dir() do project_dir
        # Test setting of depot-wide preferences
        uuid = UUID(UInt128(0))
        toml_path = last(Pkg.Preferences.depot_preferences_paths(uuid))

        @test isempty(load_preferences(uuid))
        @test !isfile(toml_path)

        # Now, save something
        save_preferences!(uuid, Dict("foo" => "bar"); depot=Pkg.depots1())
        @test isfile(toml_path)
        prefs = load_preferences(uuid)
        @test load_preferences(uuid)["foo"] == "bar"

        prefs = modify_preferences!(uuid) do prefs
            prefs["foo"] = "baz"
            prefs["spoon"] = [Dict("qux" => "idk")]
        end

        # Test that we get the properly-merged prefs, but that the
        # depot-wide file stays the same:
        @test prefs == load_preferences(uuid)
        toml_prefs = Pkg.Types.parse_toml(toml_path)
        @test toml_prefs["foo"] != prefs["foo"]
        @test !haskey(toml_prefs, "spoon")

        clear_preferences!(uuid)
        @test !isfile(toml_path)
    end

    # Do a test within a package to ensure that we can use the macros
    temp_pkg_dir() do project_dir
        add_this_pkg()
        copy_test_package(project_dir, "UsesPreferences")
        Pkg.develop(path=joinpath(project_dir, "UsesPreferences"))
        
        # Run UsesPreferences tests manually, so that they can run in the explicitly-given project
        test_script = joinpath(project_dir, "UsesPreferences", "test", "runtests.jl")
        run(`$(Base.julia_cmd()) --project=$(Base.active_project()) $(test_script)`)

        # Set a new depot-level preference, ensure that it's ignored:
        up_uuid = UUID("056c4eb5-4491-6b91-3d28-8fffe3ee2af9")
        save_preferences!(up_uuid, Dict("backend" => "CUDA"); depot=Pkg.depots1())
        prefs = load_preferences(up_uuid)
        @test haskey(prefs, "backend")
        @test prefs["backend"] == "jlFPGA"
    end
end

end # module PreferencesTests