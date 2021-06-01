module ManifestTests

using  Test, UUIDs, Dates, TOML
import ..Pkg, LibGit2
using  ..Utils

@testset "Manifest.toml formats" begin
    @testset "Default manifest format is v1" begin
        isolate(loaded_depot=true) do
            io = IOBuffer()
            Pkg.activate(; io=io, temp=true)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*", output)
            Pkg.add("Profile")
            env_manifest = Pkg.Types.Context().env.manifest_file
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))
        end
    end

    @testset "v1.0: activate, change, maintain manifest format" begin
        env_dir = joinpath(@__DIR__, "manifest", "formats", "v1.0")
        env_manifest = joinpath(env_dir, "Manifest.toml")
        isfile(env_manifest) || error("Reference manifest is missing")
        if Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            error("Reference manifest file at $(env_manifest) is invalid")
        end
        isolate(loaded_depot=true) do
            io = IOBuffer()
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*formats/v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))
        end
    end

    @testset "v2.0: activate, change, maintain manifest format" begin
        env_dir = joinpath(@__DIR__, "manifest", "formats", "v2.0")
        env_manifest = joinpath(env_dir, "Manifest.toml")
        isfile(env_manifest) || error("Reference manifest is missing")
        if Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))
            error("Reference manifest file at $(env_manifest) is invalid")
        end
        isolate(loaded_depot=true) do
            io = IOBuffer()
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*formats/v2.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
        end
    end

    @testset "v3.0: unknown format, warn" begin
        # the reference file here is not actually v3.0. It just represents an unknown manifest format
        env_dir = joinpath(@__DIR__, "manifest", "formats", "v3.0_unknown")
        env_manifest = joinpath(env_dir, "Manifest.toml")
        isfile(env_manifest) || error("Reference manifest is missing")
        isolate(loaded_depot=true) do
            io = IOBuffer()
            @test_logs (:warn, "Unknown Manifest.toml format version detected. Unexpected behavior may occur") Pkg.activate(env_dir; io=io)
        end
    end
end


end # module