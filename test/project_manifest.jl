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
                    Pkg.add("Test") # test https://github.com/JuliaLang/Pkg.jl/issues/324
                    Pkg.instantiate()
                    Pkg.test()
                end
            end
            # test subpackage instantiates/tests
            cd(joinpath(dir, "monorepo", "packages", "C")) do
                with_current_env() do
                    Pkg.develop(path="../D") # add unregistered local dependency
                    Pkg.test()
                end
            end
            new_A_module = """
            module A
            using B, C
            test() = true
            end # module
            """
            open(joinpath(dir, "monorepo", "src", "A.jl"), "w") do io
                write(io, new_A_module)
            end
            cd(joinpath(dir, "monorepo")) do
                with_current_env() do
                    Pkg.develop(path="packages/C")
                    Pkg.develop(path="packages/B")
                    Pkg.test()
                end
            end
        end
    end
end

end # module