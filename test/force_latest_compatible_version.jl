# This file is a part of Julia. License is MIT: https://julialang.org/license

module ForceLatestCompatibleVersionTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

import TOML

get_exception_message(ex::Pkg.Resolve.ResolverError) = ex.msg

get_exception_message(ex::Nothing) = "" # TODO: delete this line

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

@testset "`force_latest_compatible_version` kwarg to `Pkg.test`" begin
    @testset "get_earliest_backwards_compatible_version" begin
        @test Pkg.Operations.get_earliest_backwards_compatible_version(v"1.2.3") == v"1.0.0"
        @test Pkg.Operations.get_earliest_backwards_compatible_version(v"0.2.3") == v"0.2.0"
        @test Pkg.Operations.get_earliest_backwards_compatible_version(v"0.0.3") == v"0.0.3"
    end

    # "regular" = `/Project.toml` exists, `/test/Project.toml` does not exist,
    #             test dependencies are defined in `/Project.toml`
    # "testprojecttoml" = `Project.toml` exists, `/test/Project.toml` exists,
    #             test dependencies are defined in `test/Project.toml`
    @testset for type in ["regular", "testprojecttoml"]
        test_package_parent_dir = joinpath(
            @__DIR__,
            "test_packages",
            "force_latest_compatible_version",
            type,
        )
        @test isdir(test_package_parent_dir)

        # TODO: delete this entire if-else block
        if type == "testprojecttoml"
            broken = true
        else
            broken = false
        end

        @testset "sanity checks for our test fixtures" begin
            for test_package_name in readdir(test_package_parent_dir)
                test_package_path = joinpath(test_package_parent_dir, test_package_name)

                main_project_filename = joinpath(test_package_parent_dir, test_package_name, "Project.toml")
                test_project_filename = joinpath(test_package_parent_dir, test_package_name, "test", "Project.toml")

                @test isfile(main_project_filename)
                main_project = TOML.parsefile(main_project_filename)
                @test haskey(main_project, "deps")
                @test haskey(main_project, "compat")
                main_project_deps = main_project["deps"]
                main_project_compat = main_project["compat"]
                @test !isempty(main_project_deps)
                @test !isempty(main_project_compat)

                if type == "testprojecttoml"
                    @test isfile(test_project_filename)
                    test_project = TOML.parsefile(test_project_filename)

                    @test haskey(test_project, "deps")
                    @test haskey(test_project, "compat")
                    test_project_deps = test_project["deps"]
                    test_project_compat = test_project["compat"]
                    @test !isempty(test_project_deps)
                    @test !isempty(test_project_compat)
                else # type == "regular"
                    !isfile(test_project_filename)
                    !ispath(test_project_filename)

                    @test haskey(main_project, "extras")
                    @test haskey(main_project, "targets")
                    main_project_extras = main_project["extras"]
                    main_project_targets = main_project["targets"]
                    @test !isempty(main_project_extras)
                    @test !isempty(main_project_targets)
                end
            end
        end

        @testset "OldOnly1: `SomePkg = \"=0.1.0\"`" begin
            mktempdir() do tmp_dir
                test_package = joinpath(tmp_dir, "OldOnly1")
                cp(joinpath(test_package_parent_dir, "OldOnly1"), test_package; force = true)
                Utils.isolate(loaded_depot = true) do
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
                Utils.isolate(loaded_depot = true) do
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
                        if !broken
                            @test_throws(
                                exception_type_1,
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                    allow_earlier_backwards_compatible_versions = false,
                                ),
                            )
                        end
                        let
                            f = function ()
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                    allow_earlier_backwards_compatible_versions = false,
                                )
                            end
                            ex, msg = get_exception_and_message(f)
                            @test ex isa exception_type_1 broken=broken
                            @test occursin(message_1, msg) broken=broken
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
                Utils.isolate(loaded_depot = true) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                        @test(
                            Pkg.test(;
                                force_latest_compatible_version = false,
                            ) == nothing
                        )
                        if !broken
                            @test_throws(
                                exception_type_1,
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                ),
                            )
                        end
                        let
                            f = function ()
                                Pkg.test(;
                                    force_latest_compatible_version = true,
                                )
                            end
                            ex, msg = get_exception_and_message(f)
                            @test ex isa exception_type_1 broken=broken
                            @test occursin(message_1, msg) broken=broken
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
                            if !broken
                                @test_throws(
                                    exception_type_1,
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                        allow_earlier_backwards_compatible_versions,
                                    ),
                                )
                            end
                            let
                                f = function ()
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                        allow_earlier_backwards_compatible_versions,
                                    )
                                end
                                ex, msg = get_exception_and_message(f)
                                @test ex isa exception_type_1 broken=broken
                                @test occursin(message_1, msg) broken=broken
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
                Utils.isolate(loaded_depot = true) do
                    Pkg.activate(test_package)
                    Pkg.instantiate()
                    Pkg.build()

                    for force_latest_compatible_version in [false, true]
                        @testset "default value of `allow_earlier_backwards_compatible_versions`" begin
                            if true # if !broken
                                @test_throws(
                                    exception_type_1,
                                    Pkg.test(;
                                        force_latest_compatible_version,
                                    ),
                                )
                            end
                            let
                                f = function ()
                                    Pkg.test(;
                                        force_latest_compatible_version,
                                    )
                                end
                                ex, msg = get_exception_and_message(f)
                                @test ex isa exception_type_1
                                @test occursin(message_1, msg)
                            end
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                if true # if !broken
                                    @test_throws(
                                        exception_type_1,
                                        Pkg.test(;
                                            force_latest_compatible_version,
                                            allow_earlier_backwards_compatible_versions,
                                        ),
                                    )
                                end
                                let
                                    f = function ()
                                        Pkg.test(;
                                            force_latest_compatible_version,
                                            allow_earlier_backwards_compatible_versions,
                                        )
                                    end
                                    ex, msg = get_exception_and_message(f)
                                    @test ex isa exception_type_1
                                    @test occursin(message_1, msg)
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
                registry_commit = "a5a987a4098d6534b1f57fd13589ef982ce0f8d0"
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
                            if !broken
                                @test_logs(
                                    (:warn, message_2),
                                    match_mode=:any,
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                    ),
                                )
                            end
                        end

                        @testset "provide a value for `allow_earlier_backwards_compatible_versions`" begin
                            for allow_earlier_backwards_compatible_versions in [false, true]
                                @test(
                                    Pkg.test(;
                                        force_latest_compatible_version = true,
                                        allow_earlier_backwards_compatible_versions,
                                    ) == nothing
                                )
                                if !broken
                                    @test_logs(
                                        (:warn, message_2),
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
end

end # module
