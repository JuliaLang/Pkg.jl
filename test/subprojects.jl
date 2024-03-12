module SubProjectsTest

import ..Pkg # ensure we are using the correct Pkg
using Test
using TOML

# TODO: Test sources are merged correctly
# TODO: Test compat is merged correctly

mktempdir() do tmp
    cd(tmp) do
        name = "MonorepoSub"

        rm(name, force=true, recursive=true)
        Pkg.generate(name)
        cd("MonorepoSub")
        Pkg.activate(name)
        # Add some deps
        Pkg.add("Example")
        # add sources
        d = TOML.parsefile("Project.toml")
        d["subprojects"] = ["test", "docs", "benchmarks"]
        Pkg.Types.write_project(d, "Project.toml")
        # Add tests
        mkdir("test")
        Pkg.activate("test")
        Pkg.add("Test")
        @test !isfile("test/Manifest.toml")
        write("test/runtests.jl", """
            using Test
            using MonorepoSub
        """)
        @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="test" test/runtests.jl`))

        #=
        mkdir("benchmarks")
        Pkg.activate("benchmarks")
        Pkg.generate("BenchmarkSpecificPackage")
        Pkg.add("BenchmarkTools")
        d = TOML.parsefile("Project.toml")
        Pkg.Types.write_project(d, "Project.toml")

        @test !isfile("benchmarks/Manifest.toml")
        write("benchmarks/runbenchmarks.jl", """
            using BenchmarkTools
            using MonorepoSub
            using BenchmarkSpecificPackage

            # @btime MonorepoSub.greet("hello")
        """)
        @test issuccess(run(`Base.julia_cmd() --startup-file=no --project="test" benchmarks/runbenchmarks.jl`))
        =#

        # Test loading the package itself
        @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using MonorepoSub'`))

        rm("Manifest.toml")
        Pkg.resolve()
        @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="test" test/runtests.jl`))
        @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using MonorepoSub'`))

        # Set up main project
    end
end

end
