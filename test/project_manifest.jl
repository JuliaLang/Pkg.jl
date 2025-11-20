module ProjectManifestTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg, UUIDs
using ..Utils

temp_pkg_dir() do project_path
    @testset "test Project.toml manifest" begin
        mktempdir() do dir
            path = copy_test_package(dir, "monorepo")
            cd(path) do
                with_current_env() do
                    Pkg.develop(path = "packages/B")
                end
            end
            # test subpackage instantiates/tests
            # the order of operations here is important
            # when we instantiate and dev a dependency to the C subpackage
            # the changes are being written to the monorepo/Manifest.toml
            # but are not "sticky" in that if we ran a resolve at the monorepo/
            # level, the C & D packages would be pruned since there's no direct
            # dependency at the monorepo project level yet, so we first build up
            # C's dependencies, then at the monorepo level, we need to dev C *first*
            # to make those Manifest changes "stick" before adding Test.
            cd(joinpath(dir, "monorepo", "packages", "C")) do
                with_current_env() do
                    Pkg.develop(path = "../D") # add unregistered local dependency
                    Pkg.test()
                end
            end
            m = Pkg.Types.read_manifest(joinpath(dir, "monorepo", "Manifest.toml"))
            @test haskey(m, UUID("dd0d8fba-d7c4-4f8e-a2bb-3a090b3e34f2")) # B subpackage
            @test haskey(m, UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")) # C subpackage
            @test haskey(m, UUID("bf733257-898a-45a0-b2f2-c1c188bdd870")) # D subpackage, but no direct dependency
            pkgC = m[UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")]
            @test haskey(pkgC.deps, "D")
            cd(joinpath(dir, "monorepo")) do
                with_current_env() do
                    Pkg.develop(path = "packages/C")
                    Pkg.add("Test")
                    Pkg.test()
                end
            end
            # now test removing a dependency from subpackage correctly updates root manifest
            cd(joinpath(dir, "monorepo", "packages", "C")) do
                with_current_env() do
                    Pkg.rm("D")
                    Pkg.test()
                end
            end
            m = Pkg.Types.read_manifest(joinpath(dir, "monorepo", "Manifest.toml"))
            # currently, we don't prune dependencies from the root manifest since when rm-ing a dep
            # in a subpackage, we don't also do a full resolve at the root level
            # https://github.com/JuliaLang/Pkg.jl/issues/3590
            @test_broken !haskey(m, UUID("bf733257-898a-45a0-b2f2-c1c188bdd870")) # D subpackage, but no direct dependency
            pkgC = m[UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")]
            @test !haskey(pkgC.deps, "D")
        end
    end

    @testset "test get_project_syntax_version" begin
        # Test reading syntax version from Project.toml
        mktempdir() do dir
            test_project = joinpath(dir, "Project.toml")
            test_uuid = string(UUIDs.uuid4())

            # Test with explicit syntax.julia_version
            write(test_project, """
                name = "TestPkg"
                uuid = "$test_uuid"
                syntax.julia_version = "1.13"
                """)
            p = Pkg.Types.read_project(test_project)
            @test Pkg.Operations.get_project_syntax_version(p) == v"1.13"

            # Test with compat.julia
            write(test_project, """
                name = "TestPkg"
                uuid = "$test_uuid"

                [compat]
                julia = "1.10"
                """)
            p = Pkg.Types.read_project(test_project)
            @test Pkg.Operations.get_project_syntax_version(p) == v"1.10.0"

            # Test with neither (should default to current VERSION)
            write(test_project, """
                name = "TestPkg"
                uuid = "$test_uuid"
                """)
            p = Pkg.Types.read_project(test_project)
            @test Pkg.Operations.get_project_syntax_version(p) == VERSION
        end
    end

    @testset "test syntax version propagation end-to-end" begin
        # Full integration test: develop local packages and verify syntax versions propagate to Manifest
        mktempdir() do dir
            # Create main project
            project_dir = joinpath(dir, "MainProject")
            mkpath(project_dir)

            dep1_uuid = UUID("f08855a0-36cb-4a32-8ae5-a227b709c612")
            dep2_uuid = UUID("e127e659-a899-4a00-b565-5b74face18ba")

            # Create two versioned packages
            dep1_dir = joinpath(project_dir, "VersionedDep1")
            mkpath(joinpath(dep1_dir, "src"))
            write(joinpath(dep1_dir, "Project.toml"), """
                name = "VersionedDep1"
                uuid = "$dep1_uuid"
                syntax.julia_version = "1.13"
                """)
            write(joinpath(dep1_dir, "src", "VersionedDep1.jl"), """
                module VersionedDep1
                greet() = "Hello from VersionedDep1"
                end
                """)

            dep2_dir = joinpath(project_dir, "VersionedDep2")
            mkpath(joinpath(dep2_dir, "src"))
            write(joinpath(dep2_dir, "Project.toml"), """
                name = "VersionedDep2"
                uuid = "$dep2_uuid"
                syntax.julia_version = "1.14"
                """)
            write(joinpath(dep2_dir, "src", "VersionedDep2.jl"), """
                module VersionedDep2
                greet() = "Hello from VersionedDep2"
                end
                """)

            # Test manifest resolution through multiple steps
            write(joinpath(project_dir, "Project.toml"), "")
            cd(project_dir) do
                with_current_env() do
                    Pkg.develop(path = "VersionedDep1")
                    Pkg.develop(path = "VersionedDep2")
                end
            end

            manifest_path = joinpath(project_dir, "Manifest.toml")
            m = Pkg.Types.read_manifest(manifest_path)
            @test m[dep1_uuid].julia_syntax_version == v"1.13"
            @test m[dep2_uuid].julia_syntax_version == v"1.14"
        end
    end
end

end # module
