using  .Utils
using Test

@testset "weak deps" begin
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasExtensions.jl"))
        Pkg.test("HasExtensions", julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
    end
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasDepWithExtensions.jl"))
        Pkg.test("HasDepWithExtensions", julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        io = IOBuffer()
        Pkg.status(; ext=true, mode=Pkg.PKGMODE_MANIFEST, io)
         # TODO: Test output when ext deps are loaded etc.
        str = String(take!(io))
        @test contains(str, "└─ OffsetArraysExt [OffsetArrays]" )
    end

    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasExtensions.jl"))
        @test_throws Pkg.Resolve.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end

    isolate(loaded_depot=false) do
        depot = mktempdir(); empty!(DEPOT_PATH); push!(DEPOT_PATH, depot)
        Pkg.activate(; temp=true)
        Pkg.Registry.add(Pkg.RegistrySpec(path=joinpath(@__DIR__, "test_packages", "ExtensionExamples", "ExtensionRegistry")))
        Pkg.Registry.add("General")
        Pkg.add("HasExtensions")
        Pkg.test("HasExtensions", julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        Pkg.add("HasDepWithExtensions")
        Pkg.test("HasDepWithExtensions", julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        @test_throws Pkg.Resolve.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end
end
