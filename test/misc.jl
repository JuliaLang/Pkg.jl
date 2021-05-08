using Test
using Pkg

@testset "inference" begin
    f() = Pkg.Types.STDLIBS_BY_VERSION
    @inferred f()
    f() = Pkg.Types.UNREGISTERED_STDLIBS
    @inferred f()
end

@testset "hashing" begin
    @test hash(Pkg.Types.Project()) == 0xd4b8cda960e4de88
    @test hash(Pkg.Types.VersionBound()) == 0xdc46ceef40d7ff7f
    @test hash(Pkg.Resolve.Fixed(VersionNumber(0,1,0))) == 0xea3ee20b2c9d6ccb

    # hashes for these empty objects aren't stable
    hash(Pkg.Types.VersionSpec())
    hash(Pkg.Types.PackageEntry())
end
