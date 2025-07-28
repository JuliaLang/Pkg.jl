using .Utils
using Test
using UUIDs

@testset "weak deps" begin
    he_root = joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasExtensions.jl")
    hdwe_root = joinpath(@__DIR__, "test_packages", "ExtensionExamples", "HasDepWithExtensions.jl")
    isolate(loaded_depot = true) do
        # clean out any .cov files from previous test runs
        recursive_rm_cov_files(he_root)
        recursive_rm_cov_files(hdwe_root)

        Pkg.activate(; temp = true)
        Pkg.develop(path = he_root)
        Pkg.test("HasExtensions", julia_args = `--depwarn=no`) # OffsetArrays errors from depwarn
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "ext")))

        Pkg.test("HasExtensions", coverage = true, julia_args = `--depwarn=no`) # OffsetArrays errors from depwarn
        @test any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test any(endswith(".cov"), readdir(joinpath(he_root, "ext")))
    end
    isolate(loaded_depot = true) do
        # clean out any .cov files from previous test runs
        recursive_rm_cov_files(he_root)
        recursive_rm_cov_files(hdwe_root)

        Pkg.activate(; temp = true)
        Pkg.develop(path = hdwe_root)
        Pkg.test("HasDepWithExtensions", julia_args = `--depwarn=no`) # OffsetArrays errors from depwarn
        io = IOBuffer()
        Pkg.status(; extensions = true, mode = Pkg.PKGMODE_MANIFEST, io)
        # TODO: Test output when ext deps are loaded etc.
        str = String(take!(io))
        @test contains(str, "└─ OffsetArraysExt [OffsetArrays]") || contains(str, "├─ OffsetArraysExt [OffsetArrays]")
        @test !any(endswith(".cov"), readdir(joinpath(hdwe_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "ext")))

        Pkg.test("HasDepWithExtensions", coverage = true, julia_args = `--depwarn=no`) # OffsetArrays errors from depwarn
        @test any(endswith(".cov"), readdir(joinpath(hdwe_root, "src")))

        # No coverage files should be in HasExtensions even though it's used because coverage
        # was only requested by Pkg.test for the HasDepWithExtensions package dir
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "src")))
        @test !any(endswith(".cov"), readdir(joinpath(he_root, "ext")))
    end

    isolate(loaded_depot = true) do
        Pkg.activate(; temp = true)
        Pkg.develop(path = he_root)
        @test_throws Pkg.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end

    isolate(loaded_depot = false) do
        depot = mktempdir(); empty!(DEPOT_PATH); push!(DEPOT_PATH, depot); Base.append_bundled_depot_path!(DEPOT_PATH)
        Pkg.activate(; temp = true)
        Pkg.Registry.add(path = joinpath(@__DIR__, "test_packages", "ExtensionExamples", "ExtensionRegistry"))
        Pkg.Registry.add("General")
        Pkg.add("HasExtensions")
        Pkg.test("HasExtensions", julia_args = `--depwarn=no`) # OffsetArrays errors from depwarn
        Pkg.add("HasDepWithExtensions")
        Pkg.test("HasDepWithExtensions", julia_args = `--depwarn=no`) # OffsetArrays errors from depwarn
        @test_throws Pkg.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end
    isolate(loaded_depot = false) do
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            depot = mktempdir(); empty!(DEPOT_PATH); push!(DEPOT_PATH, depot); Base.append_bundled_depot_path!(DEPOT_PATH)
            Pkg.activate(; temp = true)
            Pkg.Registry.add(path = joinpath(@__DIR__, "test_packages", "ExtensionExamples", "ExtensionRegistry"))
            Pkg.Registry.add("General")
            Pkg.add("HasDepWithExtensions")
        end
        iob = IOBuffer()
        Pkg.precompile("HasDepWithExtensions", io = iob)
        out = String(take!(iob))
        @test occursin("Precompiling", out)
        @test occursin("OffsetArraysExt", out)
        @test occursin("HasExtensions", out)
        @test occursin("HasDepWithExtensions", out)
    end
    isolate(loaded_depot = false) do
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
            Pkg.activate(; temp = true)
            Pkg.add("Example", target = :weakdeps)
            proj = Pkg.Types.Context().env.project
            @test isempty(proj.deps)
            @test proj.weakdeps == Dict{String, Base.UUID}("Example" => Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a"))

            Pkg.activate(; temp = true)
            Pkg.add("Example", target = :extras)
            proj = Pkg.Types.Context().env.project
            @test isempty(proj.deps)
            @test proj.extras == Dict{String, Base.UUID}("Example" => Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
        end
    end

    isolate(loaded_depot = false) do
        mktempdir() do dir
            Pkg.Registry.add("General")
            path = copy_test_package(dir, "TestWeakDepProject")
            Pkg.activate(path)
            Pkg.resolve()
            @test Pkg.dependencies()[UUID("2ab3a3ac-af41-5b50-aa03-7779005ae688")].version == v"0.3.26"

            # Check that explicitly adding a package that is a weak dep removes it from the set of weak deps
            ctx = Pkg.Types.Context()
            @test "LogExpFunctions" in keys(ctx.env.project.weakdeps)
            @test !("LogExpFunctions" in keys(ctx.env.project.deps))
            Pkg.add("LogExpFunctions")
            ctx = Pkg.Types.Context()
            @test "LogExpFunctions" in keys(ctx.env.project.deps)
            @test !("LogExpFunctions" in keys(ctx.env.project.weakdeps))
        end
    end
end
