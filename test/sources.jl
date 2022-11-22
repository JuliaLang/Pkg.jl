module SourcesTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg
using ..Utils

temp_pkg_dir() do project_path
    @testset "test Project.toml [sources]" begin
        mktempdir() do dir
            path = abspath(joinpath(dirname(pathof(Pkg)), "../test", "test_packages", "monorepo"))
            cp(path, joinpath(dir, "monorepo"))
            cd(joinpath(dir, "monorepo")) do
                with_current_env() do
                    Pkg.add("Test") # test https://github.com/JuliaLang/Pkg.jl/issues/324
                    Pkg.test()
                end
            end
            # test subpackage instantiates/tests
            cd(joinpath(dir, "monorepo", "packages", "C")) do
                with_current_env() do
                    Pkg.add("Test") # test
                    Pkg.test()
                end
            end
        end
    end
end

end # module