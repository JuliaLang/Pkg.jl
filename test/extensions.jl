using  .Utils
using Test

@testset "weak deps" begin
    he_root = joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasExtensions.jl")
    hdwe_root = joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasDepWithExtensions.jl")
    isolate(loaded_depot=true) do
        # clean out any .cov files from previous test runs
        recursive_rm_cov_files(he_root)
        recursive_rm_cov_files(hdwe_root)

        Pkg.activate(; temp=true)
        Pkg.develop(path=he_root)
        Pkg.test("HasExtensions", julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "ext")))

        Pkg.test("HasExtensions", coverage=true, julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        @test any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test any(endswith(".cov"), readdir(joinpath(he_root, "ext")))
    end
    isolate(loaded_depot=true) do
        # clean out any .cov files from previous test runs
        recursive_rm_cov_files(he_root)
        recursive_rm_cov_files(hdwe_root)

        Pkg.activate(; temp=true)
        Pkg.develop(path=hdwe_root)
        Pkg.test("HasDepWithExtensions", julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        io = IOBuffer()
        Pkg.status(; extensions=true, mode=Pkg.PKGMODE_MANIFEST, io)
         # TODO: Test output when ext deps are loaded etc.
        str = String(take!(io))
        @test contains(str, "└─ OffsetArraysExt [OffsetArrays]" )
        @test !any(endswith(".cov"), readdir(joinpath(hdwe_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "ext")))

        Pkg.test("HasDepWithExtensions", coverage=true, julia_args=`--depwarn=no`) # OffsetArrays errors from depwarn
        @test any(endswith(".cov"), readdir(joinpath(hdwe_root, "src")))

        # No coverage files should be in HasExtensions even though it's used because coverage
        # was only requested by Pkg.test for the HasDepWithExtensions package dir
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "ext")))
    end

    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=he_root)
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
    isolate(loaded_depot=false) do
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            depot = mktempdir(); empty!(DEPOT_PATH); push!(DEPOT_PATH, depot)
            Pkg.activate(; temp=true)
            Pkg.Registry.add(Pkg.RegistrySpec(path=joinpath(@__DIR__, "test_packages", "ExtensionExamples", "ExtensionRegistry")))
            Pkg.Registry.add("General")
            Pkg.add("HasDepWithExtensions")
        end
        iob = IOBuffer()
        Pkg.precompile("HasDepWithExtensions", io=iob)
        out = String(take!(iob))
        @test occursin("Precompiling", out)
        @test occursin("OffsetArraysExt", out)
        @test occursin("HasExtensions", out)
        @test occursin("HasDepWithExtensions", out)
    end
end
