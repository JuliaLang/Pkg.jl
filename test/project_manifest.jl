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
                    Pkg.develop(path="packages/B")
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
                    Pkg.develop(path="../D") # add unregistered local dependency
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
                    Pkg.develop(path="packages/C")
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
end

end # module
