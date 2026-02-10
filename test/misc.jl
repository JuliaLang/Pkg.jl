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

@testset "normalize_path_for_toml" begin
    # Test that relative paths with backslashes are normalized to forward slashes on Windows
    # and left unchanged on other platforms
    if Sys.iswindows()
        @test Pkg.normalize_path_for_toml("foo\\bar\\baz") == "foo/bar/baz"
        @test Pkg.normalize_path_for_toml("..\\parent\\dir") == "../parent/dir"
        @test Pkg.normalize_path_for_toml(".\\current") == "./current"
        # Absolute paths should not be normalized (they're platform-specific)
        @test Pkg.normalize_path_for_toml("C:\\absolute\\path") == "C:\\absolute\\path"
        @test Pkg.normalize_path_for_toml("\\\\network\\share") == "\\\\network\\share"
    else
        # On Unix-like systems, paths should be unchanged
        @test Pkg.normalize_path_for_toml("foo/bar/baz") == "foo/bar/baz"
        @test Pkg.normalize_path_for_toml("../parent/dir") == "../parent/dir"
        @test Pkg.normalize_path_for_toml("./current") == "./current"
        @test Pkg.normalize_path_for_toml("/absolute/path") == "/absolute/path"
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

end # module
