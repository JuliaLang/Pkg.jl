# This file is a part of Julia. License is MIT: https://julialang.org/license

module ForceLatestCompatTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

@testset "ForceLatestCompatTests" begin
    @testset "`Types.latest_compat`" begin
        @test Pkg.Types.latest_compat("1, 3.4, 5.6.7") == "5.6.7"
        @test Pkg.Types.latest_compat("1, 4.5.6, 2.3") == "4.5.6"
        @test Pkg.Types.latest_compat("1, 4.5, 2.3") == "4.5.0"
        @test Pkg.Types.latest_compat("1, 4.5, 2.3.6") == "4.5.0"
        @test Pkg.Types.latest_compat("1.5.7, 4, 2.3.6") == "4"
    end

    @testset "`Types.force_latest_compat`" begin
        before = """
        [compat]
        PkgA = "1, 4.5.6, 2.3"
        """
        expected_after = """
        [compat]
        PkgA = "4.5.6"
        """
        tmp_dir = mktempdir(; cleanup = true)
        project_file = joinpath(tmp_dir, "Project.toml")
        open(project_file, "w") do io
            println(io, before)
        end
        @test strip(read(project_file, String)) == strip(before)
        Pkg.Types.force_latest_compat(project_file)
        @test strip(read(project_file, String)) == strip(expected_after)
        rm(tmp_dir; force = true, recursive = true)
    end

    @testset "`force_latest_compat` kwarg to `Pkg.test`" begin
        parent_dir = joinpath(@__DIR__, "test_packages", "force-latest-compat")
        @testset "OldOnly: `SomePkg = \"0.1\"`" begin
            tmp_dir = mktempdir(; cleanup = true)
            test_package = joinpath(tmp_dir, "OldOnly")
            cp(joinpath(parent_dir, "OldOnly"), test_package; force = true)
            Utils.isolate() do
                Pkg.activate(test_package)
                Pkg.instantiate()
                Pkg.build()
                @test Pkg.test(; force_latest_compat = false) == nothing
                @test Pkg.test(; force_latest_compat = false) == nothing
            end
            rm(tmp_dir; force = true, recursive = true)
        end
        @testset "BothOldAndNew: `SomePkg = \"0.1, 0.2\"`" begin
            tmp_dir = mktempdir(; cleanup = true)
            test_package = joinpath(tmp_dir, "BothOldAndNew")
            cp(joinpath(parent_dir, "BothOldAndNew"), test_package; force = true)
            Utils.isolate() do
                Pkg.activate(test_package)
                Pkg.instantiate()
                Pkg.build()
                @test Pkg.test(; force_latest_compat = false) == nothing
                @test_throws Pkg.Resolve.ResolverError Pkg.test(; force_latest_compat = true)
            end
            rm(tmp_dir; force = true, recursive = true)
        end
        @testset "NewOnly: `SomePkg = \"0.2\"`" begin
            tmp_dir = mktempdir(; cleanup = true)
            test_package = joinpath(tmp_dir, "NewOnly")
            cp(joinpath(parent_dir, "NewOnly"), test_package; force = true)
            Utils.isolate() do
                Pkg.activate(test_package)
                Pkg.instantiate()
                Pkg.build()
                @test_throws Pkg.Resolve.ResolverError Pkg.test(; force_latest_compat = false)
                @test_throws Pkg.Resolve.ResolverError Pkg.test(; force_latest_compat = true)
            end
            rm(tmp_dir; force = true, recursive = true)
        end
    end
end

end # end module ForceLatestCompatTests
