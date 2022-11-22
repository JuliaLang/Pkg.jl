module SourcesTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils

temp_pkg_dir() do project_path
    @testset "test Project.toml [sources]" begin
        mktempdir() do dir
            path = abspath(joinpath(dirname(pathof(Pkg)), "../test", "test_packages", "WithSources"))
            cp(path, joinpath(dir, "WithSources"))
            cd(joinpath(dir, "WithSources")) do
                with_current_env() do
                    Pkg.resolve()
                end
            end

            cd(joinpath(dir, "WithSources", "TestWithUnreg")) do
                with_current_env() do
                    Pkg.test()
                end
            end
        end
    end
end

end # module
