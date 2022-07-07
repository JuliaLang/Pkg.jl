using  .Utils
using Test

@testset "weak deps" begin
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "HasGluePkgs.jl"))
        Pkg.test("HasGluePkgs")
    end
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "HasDepWithGluePkgs.jl"))
        Pkg.test("HasDepWithGluePkgs")
    end

    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "HasGluePkgs.jl"))
        @test_throws Pkg.Resolve.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end
end
