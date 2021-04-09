# This file is a part of Julia. License is MIT: https://julialang.org/license

module CompatModifierTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

struct Foo end

const foo = 1
const bar = 2
const baz = 3
const foobar = 4
const foobarbaz = 5

const exception_1_type = Pkg.Resolve.ResolverError
const exception_1_message = r"^Unsatisfiable requirements detected for package"
const exception_2_instance = ErrorException("Invalid return type for `compat_modifier`: `Main.PkgTests.CompatModifierTests.Foo`; expected `Pkg.Types.VersionSpec` or `Nothing`")

get_exception_message(ex::Pkg.Resolve.ResolverError) = ex.msg
get_exception_message(ex::ErrorException) = ex.msg

function test_throws_msg(f::Function)
    ex = try
        f()
    catch ex
        ex
    end
    msg = get_exception_message(ex)
    return ex, msg
end

const test_package_parent_dir = joinpath(
    @__DIR__,
    "test_packages",
    "compat_modifier",
)

@testset "CompatModifierTests" begin
    @testset "`compat_modifier` keyword argument to the `Pkg.test` function" begin
        @testset "`compat_modifier = Pkg.Operations.force_latest_compatible_exact`" begin
            compat_modifier = Pkg.Operations.force_latest_compatible_exact

            @testset "OldOnly1" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly1")
                    cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "OldOnly2" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly2")
                    cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "BothOldAndNew" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "BothOldAndNew")
                    cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "NewOnly" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "NewOnly")
                    cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "DirectDepWithoutCompatEntry" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "DirectDepWithoutCompatEntry")
                    cp(joinpath(test_package_parent_dir, "DirectDepWithoutCompatEntry"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end
        end

        @testset "`compat_modifier = Pkg.Operations.force_latest_compatible_family`" begin
            compat_modifier = Pkg.Operations.force_latest_compatible_family

            @testset "OldOnly1" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly1")
                    cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "OldOnly2" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly2")
                    cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "BothOldAndNew" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "BothOldAndNew")
                    cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "NewOnly" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "NewOnly")
                    cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "DirectDepWithoutCompatEntry" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "DirectDepWithoutCompatEntry")
                    cp(joinpath(test_package_parent_dir, "DirectDepWithoutCompatEntry"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end
        end

        @testset "`compat_modifier = nothing`" begin
            compat_modifier = nothing

            @testset "OldOnly1" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly1")
                    cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "OldOnly2" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly2")
                    cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "BothOldAndNew" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "BothOldAndNew")
                    cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "NewOnly" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "NewOnly")
                    cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "DirectDepWithoutCompatEntry" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "DirectDepWithoutCompatEntry")
                    cp(joinpath(test_package_parent_dir, "DirectDepWithoutCompatEntry"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end
        end

        @testset "`compat_modifier = x -> nothing`" begin
            compat_modifier = x -> nothing

            @testset "OldOnly1" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly1")
                    cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "OldOnly2" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly2")
                    cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "BothOldAndNew" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "BothOldAndNew")
                    cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "NewOnly" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "NewOnly")
                    cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "DirectDepWithoutCompatEntry" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "DirectDepWithoutCompatEntry")
                    cp(joinpath(test_package_parent_dir, "DirectDepWithoutCompatEntry"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end
        end

        @testset "`compat_modifier = x -> Pkg.Versions.VersionSpec(\"*\")`" begin
            compat_modifier = x -> Pkg.Versions.VersionSpec("*")

            @testset "OldOnly1" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly1")
                    cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "OldOnly2" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "OldOnly2")
                    cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "BothOldAndNew" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "BothOldAndNew")
                    cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end

            @testset "NewOnly" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "NewOnly")
                    cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test_throws exception_1_type Pkg.test(; compat_modifier)
                        ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                        @test ex isa exception_1_type
                        @test occursin(exception_1_message, msg)
                    end
                end
            end

            @testset "DirectDepWithoutCompatEntry" begin
                mktempdir() do tmp_dir
                    test_package = joinpath(tmp_dir, "DirectDepWithoutCompatEntry")
                    cp(joinpath(test_package_parent_dir, "DirectDepWithoutCompatEntry"), test_package; force = true)
                    Utils.isolate() do
                        Pkg.activate(test_package)
                        Pkg.instantiate()
                        Pkg.build()
                        @test Pkg.test(; compat_modifier) === nothing
                    end
                end
            end
        end

        @testset "Invalid return type for `compat_modifier`" begin
            compat_modifier = x -> Foo()
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "OldOnly1")
                cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                Utils.isolate() do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()
                    @test_throws exception_2_instance Pkg.test(; compat_modifier)
                    ex, msg = test_throws_msg(() -> Pkg.test(; compat_modifier))
                    @test ex == exception_2_instance
                    @test msg == get_exception_message(exception_2_instance)
                end
            end
        end
    end

    @testset "earliest_backwards_compatible" begin
        @test Pkg.Operations.earliest_backwards_compatible(v"1.2.3") == v"1.0.0"
        @test Pkg.Operations.earliest_backwards_compatible(v"0.2.3") == v"0.2.0"
        @test Pkg.Operations.earliest_backwards_compatible(v"0.0.3") == v"0.0.3"
    end
end

end # module
