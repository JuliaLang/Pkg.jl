# This file is a part of Julia. License is MIT: https://julialang.org/license

module ForceLatestCompatibleVersionTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

get_exception_message(ex::Pkg.Resolve.ResolverError) = ex.msg

function get_exception_and_message(f::Function)
    ex = try
        f()
    catch ex
        ex
    end
    msg = get_exception_message(ex)
    return ex, msg
end

const exception_type_1 = Pkg.Resolve.ResolverError
const message_1 = "Unsatisfiable requirements detected for package"
const message_2 = "Dependency does not have a [compat] entry"

const test_package_parent_dir = joinpath(
    @__DIR__,
    "test_packages",
    "force_latest_compatible_version",
)

# Check that `Pkg.test` with the given kwargs fails to resolve, with a message
# about unsatisfiable requirements.
function test_unsatisfiable(; kwargs...)
    ex, msg = get_exception_and_message() do
        Pkg.test(; kwargs...)
    end
    @test ex isa exception_type_1
    @test occursin(message_1, msg)
    return
end

# Every `Pkg.test` call below that succeeds runs the package's tests in a
# subprocess, so the combinations are kept to the ones that make a
# difference: `force_latest_compatible_version = false` ignores
# `allow_earlier_backwards_compatible_versions` entirely.
@testset "check_force_latest_compatible_version" begin
    @testset "get_earliest_backwards_compatible_version" begin
        @test Pkg.Operations.get_earliest_backwards_compatible_version(v"1.2.3") == v"1.0.0"
        @test Pkg.Operations.get_earliest_backwards_compatible_version(v"0.2.3") == v"0.2.0"
        @test Pkg.Operations.get_earliest_backwards_compatible_version(v"0.0.3") == v"0.0.3"
    end

    @testset "`force_latest_compatible_version` kwarg to `Pkg.test`" begin
        @testset "OldOnly1: `SomePkg = \"=0.1.0\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "OldOnly1")
                cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                Utils.isolate(loaded_depot = true) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    # The compat entry pins a single version, so forcing the
                    # latest compatible version never changes anything.
                    @test Pkg.test(; force_latest_compatible_version = false) == nothing
                    @test Pkg.test(; force_latest_compatible_version = true) == nothing
                    for allow_earlier_backwards_compatible_versions in [false, true]
                        @test(
                            Pkg.test(;
                                force_latest_compatible_version = true,
                                allow_earlier_backwards_compatible_versions,
                            ) == nothing
                        )
                    end
                end
            end
        end

        @testset "OldOnly2: `SomePkg = \"0.1\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "OldOnly2")
                cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                Utils.isolate(loaded_depot = true) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @test Pkg.test(; force_latest_compatible_version = false) == nothing

                    @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                        @test Pkg.test(; force_latest_compatible_version = true) == nothing
                    end

                    @testset "`allow_earlier_backwards_compatible_versions` = false" begin
                        test_unsatisfiable(;
                            force_latest_compatible_version = true,
                            allow_earlier_backwards_compatible_versions = false,
                        )
                    end

                    @testset "`allow_earlier_backwards_compatible_versions` = true" begin
                        @test(
                            Pkg.test(;
                                force_latest_compatible_version = true,
                                allow_earlier_backwards_compatible_versions = true,
                            ) == nothing
                        )
                    end
                end
            end
        end

        @testset "BothOldAndNew: `SomePkg = \"0.1, 0.2\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "BothOldAndNew")
                cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                Utils.isolate(loaded_depot = true) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @test Pkg.test(; force_latest_compatible_version = false) == nothing

                    @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                        test_unsatisfiable(; force_latest_compatible_version = true)
                    end

                    @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                        for allow_earlier_backwards_compatible_versions in [false, true]
                            test_unsatisfiable(;
                                force_latest_compatible_version = true,
                                allow_earlier_backwards_compatible_versions,
                            )
                        end
                    end
                end
            end
        end

        @testset "NewOnly: `SomePkg = \"0.2\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "NewOnly")
                cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                Utils.isolate(loaded_depot = true) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    # The manifest is unsatisfiable regardless of the kwargs
                    for force_latest_compatible_version in [false, true]
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            test_unsatisfiable(; force_latest_compatible_version)
                        end
                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                test_unsatisfiable(;
                                    force_latest_compatible_version,
                                    allow_earlier_backwards_compatible_versions,
                                )
                            end
                        end
                    end
                end
            end
        end

        @testset "DirectDepWithoutCompatEntry" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "DirectDepWithoutCompatEntry")
                cp(joinpath(test_package_parent_dir, "DirectDepWithoutCompatEntry"), test_package; force = true)

                # Because this test involves instantiating a project that has
                # a direct dependency that does not have a `[compat]` entry,
                # it is possible that future commits to the General registry
                # will break this test. Therefore, we intentionally run this
                # test using a fixed version of the General registry.
                registry_url = "https://github.com/JuliaRegistries/General.git"
                registry_commit = "8129a7701ba2bd95bd83b90178114dd3aa2d3295"
                Utils.isolate_and_pin_registry(; registry_url, registry_commit) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @testset "force_latest_compatible_version = false" begin
                        @test Pkg.test(; force_latest_compatible_version = false) == nothing
                    end

                    @testset "force_latest_compatible_version = true" begin
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            @test(
                                @test_logs(
                                    (:warn, message_2),
                                    match_mode = :any,
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                    ),
                                ) == nothing
                            )
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                @test(
                                    @test_logs(
                                        (:warn, message_2),
                                        match_mode = :any,
                                        Pkg.test(;
                                            force_latest_compatible_version = true,
                                            allow_earlier_backwards_compatible_versions,
                                        ),
                                    ) == nothing
                                )
                            end
                        end
                    end
                end
            end
        end
    end
end

end # module
