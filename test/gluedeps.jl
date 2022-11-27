using  .Utils
using Test

@testset "glue deps" begin
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "HasGluePkgs.jl"))
        Pkg.test("HasGluePkgs")
    end
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "HasDepWithGluePkgs.jl"))
        Pkg.test("HasDepWithGluePkgs")
        Pkg.status(; glue=true, io=IOBuffer()) # TODO: Test output
    end

    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "HasGluePkgs.jl"))
        @test_throws Pkg.Resolve.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end

    isolate(loaded_depot=false) do
        depot = mktempdir(); empty!(DEPOT_PATH); push!(DEPOT_PATH, depot)
        Pkg.activate(; temp=true)
        Pkg.Registry.add(Pkg.RegistrySpec(path=joinpath(@__DIR__, "test_packages", "GluePkgExamples", "GlueRegistry")))
        Pkg.Registry.add("General")
        Pkg.add("HasGluePkgs")
        Pkg.test("HasGluePkgs")
        Pkg.add("HasDepWithGluePkgs")
        Pkg.test("HasDepWithGluePkgs")
        @test_throws Pkg.Resolve.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end
end
