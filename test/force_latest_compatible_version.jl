# This file is a part of Julia. License is MIT: https://julialang.org/license

module ForceLatestCompatibleVersionTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

const expected_message_1 = "Unsatisfiable requirements detected"
const expected_message_2 = "Package does not have a [compat] entry"

const test_package_parent_dir = joinpath(
    @__DIR__,
    "test_packages",
    "force_latest_compatible_version",
)

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
                Utils.isolate() do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    for force_latest_compatible_version in [false, true]
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            @test(
                                Pkg.test(;
                                    force_latest_compatible_version,
                                ) == nothing
                            )
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                @test(
                                    Pkg.test(;
                                        force_latest_compatible_version,
                                        allow_earlier_backwards_compatible_versions,
                                    ) == nothing
                                )
                            end
                        end
                    end
                end
            end
        end

        @testset "OldOnly2: `SomePkg = \"0.1\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "OldOnly2")
                cp(joinpath(test_package_parent_dir, "OldOnly2"), test_package; force = true)
                Utils.isolate() do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                        for force_latest_compatible_version in [false, true]
                            @test(
                                Pkg.test(;
                                    force_latest_compatible_version,
                                ) == nothing
                            )
                        end
                    end

                    @testset "`allow_earlier_backwards_compatible_versions` = false" begin
                        @test(
                            Pkg.test(;
                                force_latest_compatible_version = false,
                                allow_earlier_backwards_compatible_versions = false,
                            ) == nothing
                        )
                        @test_throws(
                            Pkg.Resolve.ResolverError,
                            Pkg.test(;
                                force_latest_compatible_version = true,
                                allow_earlier_backwards_compatible_versions = false,
                            ),
                        )
                        let
                            ex = try
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                    allow_earlier_backwards_compatible_versions = false,
                                )
                            catch ex
                                ex
                            end
                            @test ex isa Pkg.Resolve.ResolverError
                            @test occursin(lowercase(strip(expected_message_1)), lowercase(strip(ex.msg)))
                        end
                    end

                    @testset "`allow_earlier_backwards_compatible_versions` = true" begin
                        for force_latest_compatible_version in [false, true]
                            @test(
                                Pkg.test(;
                                    force_latest_compatible_version,
                                    allow_earlier_backwards_compatible_versions = true,
                                ) == nothing
                            )
                        end
                    end
                end
            end
        end

        @testset "BothOldAndNew: `SomePkg = \"0.1, 0.2\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "BothOldAndNew")
                cp(joinpath(test_package_parent_dir, "BothOldAndNew"), test_package; force = true)
                Utils.isolate() do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                        @test(
                            Pkg.test(;
                                force_latest_compatible_version = false,
                            ) == nothing
                        )
                        @test_throws(
                            Pkg.Resolve.ResolverError,
                            Pkg.test(;
                                force_latest_compatible_version = true,
                            ),
                        )
                        let
                            ex = try
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                )
                            catch ex
                                ex
                            end
                            @test ex isa Pkg.Resolve.ResolverError
                            @test occursin(lowercase(strip(expected_message_1)), lowercase(strip(ex.msg)))
                        end
                    end

                    @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                        for allow_earlier_backwards_compatible_versions in [false, true]
                            @test(
                                Pkg.test(;
                                    force_latest_compatible_version = false,
                                    allow_earlier_backwards_compatible_versions,
                                ) == nothing
                            )
                            @test_throws(
                                Pkg.Resolve.ResolverError,
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                    allow_earlier_backwards_compatible_versions,
                                ),
                            )
                            let
                                ex = try
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                        allow_earlier_backwards_compatible_versions,
                                    )
                                catch ex
                                    ex
                                end
                                @test ex isa Pkg.Resolve.ResolverError
                                @test occursin(lowercase(strip(expected_message_1)), lowercase(strip(ex.msg)))
                            end
                        end
                    end
                end
            end
        end

        @testset "NewOnly: `SomePkg = \"0.2\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "NewOnly")
                cp(joinpath(test_package_parent_dir, "NewOnly"), test_package; force = true)
                Utils.isolate() do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    for force_latest_compatible_version in [false, true]
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            @test_throws(
                                Pkg.Resolve.ResolverError,
                                Pkg.test(;
                                    force_latest_compatible_version,
                                ),
                            )
                            let
                                ex = try
                                    Pkg.test(;
                                        force_latest_compatible_version,
                                    )
                                catch ex
                                    ex
                                end
                                @test ex isa Pkg.Resolve.ResolverError
                                @test occursin(lowercase(strip(expected_message_1)), lowercase(strip(ex.msg)))
                            end
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                @test_throws(
                                    Pkg.Resolve.ResolverError,
                                    Pkg.test(;
                                        force_latest_compatible_version,
                                        allow_earlier_backwards_compatible_versions,
                                    ),
                                )
                                let
                                    ex = try
                                        Pkg.test(;
                                            force_latest_compatible_version,
                                            allow_earlier_backwards_compatible_versions,
                                        )
                                    catch ex
                                        ex
                                    end
                                    @test ex isa Pkg.Resolve.ResolverError
                                    @test occursin(lowercase(strip(expected_message_1)), lowercase(strip(ex.msg)))
                                end
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
                registry_commit = "982ab1618f87a7dc69c3617e124a6ad83a22b1c5"
                Utils.isolate_and_pin_registry(; registry_url, registry_commit) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @testset "force_latest_compatible_version = false" begin
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            @test(
                                Pkg.test(;
                                    force_latest_compatible_version = false,
                                ) == nothing
                            )
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                @test(
                                    Pkg.test(;
                                        force_latest_compatible_version = false,
                                        allow_earlier_backwards_compatible_versions,
                                    ) == nothing
                                )
                            end
                        end
                    end

                    @testset "force_latest_compatible_version = true" begin
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            @test(
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                ) == nothing
                            )
                            @test_logs(
                                (:warn, expected_message_2),
                                match_mode=:any,
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                ),
                            )
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                @test(
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                        allow_earlier_backwards_compatible_versions,
                                    ) == nothing
                                )
                                @test_logs(
                                    (:warn, expected_message_2),
                                    match_mode=:any,
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                        allow_earlier_backwards_compatible_versions,
                                    ),
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
