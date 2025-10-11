using Test
using Pkg

@testset "dry-run" begin
    mktempdir() do tmp_dir
        cd(tmp_dir) do
            Pkg.activate(".")

            # Test add with dry-run
            Pkg.add("Example"; dry_run = true)
            @test !haskey(Pkg.project().dependencies, "Example")
            @test !isfile("Manifest.toml")  # No manifest should exist

            # Actually add Example 0.5.3 for subsequent tests
            Pkg.add(name = "Example", version = "0.5.3")
            @test haskey(Pkg.project().dependencies, "Example")
            example_uuid = Pkg.project().dependencies["Example"]

            # Test update with dry-run - should not upgrade from 0.5.3
            initial_deps = copy(Pkg.dependencies())
            manifest_before = read("Manifest.toml", String)
            Pkg.update(; dry_run = true)
            @test Pkg.dependencies() == initial_deps
            @test read("Manifest.toml", String) == manifest_before

            # Test resolve with dry-run
            # TODO: This doesn't actually change anything currently, so it's a bit pointless
            Pkg.resolve(; dry_run = true)
            @test Pkg.dependencies() == initial_deps
            @test read("Manifest.toml", String) == manifest_before

            # Test develop with dry-run
            Pkg.develop("JSON"; dry_run = true)
            entry = get(Pkg.dependencies(), example_uuid, nothing)
            @test entry !== nothing
            @test !entry.is_tracking_path  # Should not be tracking path after dry-run
            @test read("Manifest.toml", String) == manifest_before
        end
    end
end
