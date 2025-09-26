module PkgMisc
using ..Pkg
using Test

@testset "inference" begin
    f1() = Pkg.Types.STDLIBS_BY_VERSION
    @inferred f1()
    f2() = Pkg.Types.UNREGISTERED_STDLIBS
    @inferred f2()
end

@testset "hashing" begin
    @test hash(Pkg.Types.Project()) == hash(Pkg.Types.Project())
    @test hash(Pkg.Types.VersionBound()) == hash(Pkg.Types.VersionBound())
    @test hash(Pkg.Resolve.Fixed(VersionNumber(0, 1, 0))) == hash(Pkg.Resolve.Fixed(VersionNumber(0, 1, 0)))

    hash(Pkg.Types.VersionSpec()) # hash isn't stable
    hash(Pkg.Types.PackageEntry()) # hash isn't stable because the internal `repo` field is a mutable struct
end

@testset "safe_realpath" begin
    realpath(Sys.BINDIR) == Pkg.safe_realpath(Sys.BINDIR)
    # issue #3085
    for p in ("", "some-non-existing-path", "some-non-existing-drive:")
        @test p == Pkg.safe_realpath(p)
    end
end

@test eltype([PackageSpec(a) for a in []]) == PackageSpec

@testset "PackageSpec version default" begin
    # Test that PackageSpec without explicit version gets set to VersionSpec("*")
    # This behavior is relied upon by BinaryBuilderBase.jl for dependency filtering
    # See: https://github.com/JuliaPackaging/BinaryBuilderBase.jl/blob/master/src/Prefix.jl
    ps = PackageSpec(name = "Example")
    @test ps.version == Pkg.Types.VersionSpec("*")

    # Test with UUID as well
    ps_uuid = PackageSpec(name = "Example", uuid = Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
    @test ps_uuid.version == Pkg.Types.VersionSpec("*")

    # Test that explicitly set version is preserved
    ps_versioned = PackageSpec(name = "Example", version = v"1.0.0")
    @test ps_versioned.version == v"1.0.0"

    # Test that explicitly set versionspec (string format) is preserved
    ps_versioned = PackageSpec(name = "Example", version = "1.0.0")
    @test ps_versioned.version == "1.0.0"
end

@testset "upstream_version tests" begin
    mktempdir() do tmpdir
        # Create a project with upstream_version
        project_file = joinpath(tmpdir, "Project.toml")
        open(project_file, "w") do io
            write(
                io, """
                name = "TestPkg"
                uuid = "12345678-1234-1234-1234-123456789abc"
                version = "0.1.0"
                upstream_version = "2.4.1-beta"

                [deps]
                TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
                """
            )
        end

        # Test reading
        project = Pkg.Types.read_project(project_file)
        @test project.upstream_version == "2.4.1-beta"
        @test project.name == "TestPkg"
        @test project.version == v"0.1.0"

        # Test writing
        destructured = Pkg.Types.destructure(project)
        @test destructured["upstream_version"] == "2.4.1-beta"

        # Write back and read again
        output_file = joinpath(tmpdir, "Project_output.toml")
        Pkg.Types.write_project(destructured, output_file)

        project2 = Pkg.Types.read_project(output_file)
        @test project2.upstream_version == "2.4.1-beta"

        # Test that it's preserved in the written file
        content = read(output_file, String)
        @test occursin("upstream_version = \"2.4.1-beta\"", content)

        # Test nil case
        project_file2 = joinpath(tmpdir, "Project2.toml")
        open(project_file2, "w") do io
            write(
                io, """
                name = "TestPkg2"
                uuid = "87654321-4321-4321-4321-210987654321"
                version = "0.1.0"

                [deps]
                TOML = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
                """
            )
        end

        project_no_upstream = Pkg.Types.read_project(project_file2)
        @test project_no_upstream.upstream_version === nothing

        # Test that it doesn't appear in written file when not set
        destructured_no_upstream = Pkg.Types.destructure(project_no_upstream)
        @test !haskey(destructured_no_upstream, "upstream_version")
    end

    # Test PackageSpec upstream_version field
    @testset "PackageSpec upstream_version" begin
        ps = PackageSpec(name = "Example", upstream_version = "1.2.3-alpha")
        @test ps.upstream_version == "1.2.3-alpha"

        ps_nil = PackageSpec(name = "Example")
        @test ps_nil.upstream_version === nothing
    end

    # Test manifest upstream_version functionality
    @testset "Manifest upstream_version" begin
        mktempdir() do tmpdir
            # Create a manifest with upstream_version in an entry
            manifest_file = joinpath(tmpdir, "Manifest.toml")
            open(manifest_file, "w") do io
                write(
                    io, """
                    julia_version = "1.13.0"
                    manifest_format = "2.0"

                    [[deps.Example]]
                    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                    version = "1.0.0"
                    upstream_version = "2.3.4-rc1"
                    """
                )
            end

            # Test reading manifest
            manifest = Pkg.Types.read_manifest(manifest_file)
            example_uuid = Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a")
            @test haskey(manifest, example_uuid)

            entry = manifest[example_uuid]
            @test entry.upstream_version == "2.3.4-rc1"
            @test entry.version == v"1.0.0"

            # Test writing manifest
            destructured = Pkg.Types.destructure(manifest)
            output_file = joinpath(tmpdir, "Manifest_output.toml")
            Pkg.Types.write_manifest(destructured, output_file)

            # Verify the upstream_version is written
            content = read(output_file, String)
            @test occursin("upstream_version = \"2.3.4-rc1\"", content)

            # Test reading it back
            manifest2 = Pkg.Types.read_manifest(output_file)
            entry2 = manifest2[example_uuid]
            @test entry2.upstream_version == "2.3.4-rc1"
        end
    end
end

end # module
