module ManifestTests

using  Test, UUIDs, Dates, TOML
import ..Pkg, LibGit2
using  ..Utils

# used with the reference manifests in `test/manifest/formats`
# ensures the manifests are valid and restored after test
function reference_manifest_isolated_test(f, dir::String; v1::Bool=false)
    env_dir = joinpath(@__DIR__, "manifest", "formats", dir)
    env_manifest = joinpath(env_dir, "Manifest.toml")
    env_project = joinpath(env_dir, "Project.toml")
    cp(env_manifest, string(env_manifest, "_backup"))
    cp(env_project, string(env_project, "_backup"))
    try
        isfile(env_manifest) || error("Reference manifest is missing")
        if Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == !v1
            error("Reference manifest file at $(env_manifest) is invalid")
        end
        isolate(loaded_depot=true) do
            f(env_dir, env_manifest)
        end
    finally
        cp(string(env_manifest, "_backup"), env_manifest, force = true)
        rm(string(env_manifest, "_backup"))
        cp(string(env_project, "_backup"), env_project, force = true)
        rm(string(env_project, "_backup"))
    end
end

##

@testset "Manifest.toml formats" begin
    @testset "Default manifest format is v2" begin
        isolate(loaded_depot=true) do
            io = IOBuffer()
            Pkg.activate(; io=io, temp=true)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*", output)
            Pkg.add("Profile")
            env_manifest = Pkg.Types.Context().env.manifest_file
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.0.0"
        end
    end

    @testset "v1.0: activate, change, maintain manifest format" begin
        reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))
        end
    end

    @testset "v2.0: activate, change, maintain manifest format" begin
        reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v2.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            m = Pkg.Types.read_manifest(env_manifest)
            @test m.other["some_other_field"] == "other"
            @test m.other["some_other_data"] == [1,2,3,4]

            mktemp() do path, io
                Pkg.Types.write_manifest(io, m)
                m2 = Pkg.Types.read_manifest(env_manifest)
                @test m.deps == m2.deps
                @test m.julia_version == m2.julia_version
                @test m.manifest_format == m2.manifest_format
                @test m.other == m2.other
            end
        end
        reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
            m = Pkg.Types.read_manifest(env_manifest)
            m.julia_version = v"1.5.0"
            msg = r"The active manifest file has dependencies that were resolved with a different julia version"
            @test_logs (:warn, msg) Pkg.Types.check_warn_manifest_julia_version_compat(m, env_manifest)

            m.julia_version = nothing
            msg = r"The active manifest file is missing a julia version entry"
            @test_logs (:warn, msg) Pkg.Types.check_warn_manifest_julia_version_compat(m, env_manifest)
        end
    end

    @testset "v3.0: unknown format, warn" begin
        # the reference file here is not actually v3.0. It just represents an unknown manifest format
        reference_manifest_isolated_test("v3.0_unknown") do env_dir, env_manifest
            io = IOBuffer()
            @test_logs (:warn,) Pkg.activate(env_dir; io=io)
        end
    end

    @testset "Pkg.upgrade_manifest()" begin
        reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.upgrade_manifest()
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.0.0"
        end
    end
    @testset "Pkg.upgrade_manifest(manifest_path)" begin
        reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.upgrade_manifest(env_manifest)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            Pkg.activate(env_dir; io=io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.0.0"
        end
    end
end

@testset "Manifest metadata" begin
    @testset "julia_version" begin
        @testset "dropbuild" begin
            @test Pkg.Operations.dropbuild(v"1.2.3-DEV.2134") == v"1.2.3-DEV"
            @test Pkg.Operations.dropbuild(v"1.2.3-DEV") == v"1.2.3-DEV"
            @test Pkg.Operations.dropbuild(v"1.2.3") == v"1.2.3"
            @test Pkg.Operations.dropbuild(v"1.2.3-rc1") == v"1.2.3-rc1"
        end
        @testset "new environment: value is `nothing`, then ~`VERSION` after resolve" begin
            isolate(loaded_depot=true) do
                Pkg.activate(; temp=true)
                @test Pkg.Types.Context().env.manifest.julia_version == nothing
                Pkg.add("Profile")
                @test Pkg.Types.Context().env.manifest.julia_version == Pkg.Operations.dropbuild(VERSION)
            end
        end
        @testset "activating old environment: maintains old version, then ~`VERSION` after resolve" begin
            reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
                Pkg.activate(env_dir)
                @test Pkg.Types.Context().env.manifest.julia_version == v"1.7.0-DEV"

                Pkg.add("Profile")
                @test Pkg.Types.Context().env.manifest.julia_version == Pkg.Operations.dropbuild(VERSION)
            end
        end
        @testset "instantiate manifest from different julia_version" begin
            reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
                Pkg.activate(env_dir)
                @test_logs (:warn, r"The active manifest file") Pkg.instantiate()
                @test Pkg.Types.Context().env.manifest.julia_version == nothing
            end
            if VERSION >= v"1.8"
                reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
                    Pkg.activate(env_dir)
                    @test_logs (:warn, r"The active manifest file") Pkg.instantiate()
                    @test Pkg.Types.Context().env.manifest.julia_version == v"1.7.0-DEV"
                end
            end
        end
        @testset "project_hash for identifying out of sync manifest" begin
            isolate(loaded_depot=true) do
                iob = IOBuffer()

                Pkg.activate(; temp=true)
                Pkg.add("Example")
                @test Pkg.is_manifest_current() === true

                Pkg.compat("Example", "0.4")
                @test Pkg.is_manifest_current() === false
                Pkg.status(io = iob)
                sync_msg_str = r"The project dependencies or compat requirements have changed since the manifest was last resolved."
                @test occursin(sync_msg_str, String(take!(iob)))
                @test_logs (:warn, sync_msg_str) Pkg.instantiate()

                Pkg.update()
                @test Pkg.is_manifest_current() === true
                Pkg.status(io = iob)
                @test !occursin(sync_msg_str, String(take!(iob)))

                Pkg.compat("Example", "0.5")
                Pkg.status(io = iob)
                @test occursin(sync_msg_str, String(take!(iob)))
                @test_logs (:warn, sync_msg_str) Pkg.instantiate()

                Pkg.rm("Example")
                @test Pkg.is_manifest_current() === true
                Pkg.status(io = iob)
                @test !occursin(sync_msg_str, String(take!(iob)))
            end
        end
    end
end

end # module
