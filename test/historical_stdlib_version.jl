module HistoricalStdlibVersionsTests
using ..Pkg
using Test
using HistoricalStdlibVersions
append!(Pkg.Types.STDLIBS_BY_VERSION, HistoricalStdlibVersions.STDLIBS_BY_VERSION)

include("utils.jl")
using .Utils

HelloWorldC_jll_UUID = Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")
GMP_jll_UUID = Base.UUID("781609d7-10c4-51f6-84f2-b8444358ff6d")
OpenBLAS_jll_UUID = Base.UUID("4536629a-c528-5b80-bd46-f80d51c5b363")
libcxxwrap_julia_jll_UUID = Base.UUID("3eaa8342-bff7-56a5-9981-c04077f7cee7")
libblastrampoline_jll_UUID = Base.UUID("8e850b90-86db-534c-a0d3-1478176c7d93")

isolate(loaded_depot=true) do
    Pkg.activate(temp=true)

    @testset "Elliot and Mosè's mini Pkg test suite" begin

        @testset "HelloWorldC_jll" begin
            # Standard add (non-stdlib, flexible version)
            Pkg.add(; name="HelloWorldC_jll")
            @test haskey(Pkg.dependencies(), HelloWorldC_jll_UUID)

            # Standard add (non-stdlib, url and rev)
            Pkg.add(; name="HelloWorldC_jll", url="https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl", rev="0b4959a49385d4bb00efd281447dc19348ebac08")
            @test Pkg.dependencies()[Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")].git_revision === "0b4959a49385d4bb00efd281447dc19348ebac08"

            # Standard add (non-stdlib, specified version)
            Pkg.add(; name="HelloWorldC_jll", version=v"1.0.10+1")
            @test Pkg.dependencies()[Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")].version === v"1.0.10+1"

            # Standard add (non-stdlib, versionspec)
            Pkg.add(; name="HelloWorldC_jll", version=Pkg.Types.VersionSpec("1.0.10"))
            @test Pkg.dependencies()[Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")].version === v"1.0.10+1"
        end

        @testset "libcxxwrap_julia_jll" begin

            # Julia-version-dependent add (non-stdlib, flexible version)
            Pkg.add(; name="libcxxwrap_julia_jll", julia_version=v"1.7")
            @test Pkg.dependencies()[libcxxwrap_julia_jll_UUID].version === v"0.12.1+0"

            # Julia-version-dependent add (non-stdlib, specified version)
            Pkg.add(; name="libcxxwrap_julia_jll", version=v"0.9.4+0", julia_version=v"1.7")
            @test Pkg.dependencies()[libcxxwrap_julia_jll_UUID].version === v"0.9.4+0"

            Pkg.add(; name="libcxxwrap_julia_jll", version=v"0.8.8+1", julia_version=v"1.9")
            @test Pkg.dependencies()[libcxxwrap_julia_jll_UUID].version === v"0.8.8+1"
        end

        @testset "GMP_jll" begin
            # Stdlib add (current julia version)
            Pkg.add(; name="GMP_jll")
            @test Pkg.dependencies()[GMP_jll_UUID].version === v"6.2.1+6"

            # Stdlib add (other julia version)
            Pkg.add(; name="GMP_jll", julia_version=v"1.7")
            @test Pkg.dependencies()[GMP_jll_UUID].version === v"6.2.1+1"

            # Stdlib add (other julia version, with specific version bound)
            # Note, this doesn't work properly, it adds but doesn't install any artifacts.
            # Technically speaking, this is probably okay from Pkg's perspective, since
            # we're asking Pkg to resolve according to what Julia v1.7 would do.... and
            # Julia v1.7 would not install anything because it's a stdlib!  However, we
            # would sometimes like to resolve the latest version of GMP_jll for Julia v1.7
            # then install that.  If we have to manually work around that and look up what
            # GMP_jll for Julia v1.7 is, then ask for that version explicitly, that's ok.

            Pkg.add(; name="GMP_jll", julia_version=v"1.7")

            # This is expected to fail, that version can't live with `julia_version = v"1.7"`
            @test_throws Pkg.Resolve.ResolverError Pkg.add(; name="GMP_jll", version=v"6.2.0+5", julia_version=v"1.7")

            # Stdlib add (julia_version == nothing)
            # Note: this is currently known to be broken, we get the wrong GMP_jll!
            Pkg.add(; name="GMP_jll", version=v"6.2.1+1", julia_version=nothing)
            @test_broken Pkg.dependencies()[GMP_jll_UUID].version === v"6.2.1+1"
        end

        @testset "Julia Version = Nothing" begin
            # Stdlib add (impossible constraints due to julia version compat, so
            # must pass `julia_version=nothing`). In this case, we always fully
            # specify versions, but if we don't, it's okay to just give us whatever
            # the resolver prefers
            Pkg.add([
                PackageSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
                PackageSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
            ]; julia_version=nothing)
            @test v"0.3.14" > Pkg.dependencies()[OpenBLAS_jll_UUID].version >= v"0.3.13"
            @test v"5.1.2" > Pkg.dependencies()[libblastrampoline_jll_UUID].version >= v"5.1.1"
        end
    end
end
end # module
