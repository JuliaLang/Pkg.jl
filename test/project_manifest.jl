module ProjectManifestTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils

temp_pkg_dir() do project_path
    @testset "test Project.toml manifest" begin
        mktempdir() do dir
            path = abspath(joinpath(dirname(pathof(Pkg)), "../test", "test_packages", "monorepo"))
            cp(path, joinpath(dir, "monorepo"))
            cd(joinpath(dir, "monorepo")) do
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
            cd(joinpath(dir, "monorepo")) do
                with_current_env() do
                    Pkg.develop(path="packages/C")
                    Pkg.add("Test")
                    Pkg.test()
                end
            end
        end
    end
end

end # module