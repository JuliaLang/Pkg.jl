module SubProjectsTest

import ..Pkg # ensure we are using the correct Pkg
using Test
using TOML
using UUIDs
if !isdefined(@__MODULE__, :Utils)
    include("utils.jl")
    using .Utils
end


temp_pkg_dir() do project_path
    cd(project_path) do
        name = "MonorepoSub"
        rm(name, force=true, recursive=true)
        Pkg.generate(name)
        cd("MonorepoSub") do
            Pkg.activate(".")
            # Add Example, Crayons, PrivatePackage to the "MonorepoSub" package
            Pkg.add("Example")
            Pkg.add(;name="Crayons", version="v4.0.3")
            Pkg.compat("Crayons", "=4.0.0, =4.0.1, =4.0.2, =4.0.3")
            Pkg.generate("PrivatePackage")
            Pkg.develop(path="PrivatePackage")
            d = TOML.parsefile("Project.toml")
            d["subprojects"] = ["test", "docs", "benchmarks", "PrivatePackage"]
            abs_path = abspath("PrivatePackage") # TODO: Make relative after #3842 is fixed
            d["sources"] = Dict("PrivatePackage" => Dict("path" => abs_path))
            Pkg.Types.write_project(d, "Project.toml")
            write("src/MonorepoSub.jl", """
                module MonorepoSub
                using Example, Crayons, PrivatePackage
                end
            """)

            # Add some deps to PrivatePackage
            Pkg.activate("PrivatePackage")
            Pkg.add(; name="Chairmarks", version=v"1.1.2")
            @test !isfile("PrivatePackage/Manifest.toml")
            d = TOML.parsefile("PrivatePackage/Project.toml")
            d["subprojects"] = ["test"]
            Pkg.Types.write_project(d, "PrivatePackage/Project.toml")
            write("PrivatePackage/src/PrivatePackage.jl", """
            module PrivatePackage
                using Chairmarks
            end
            """)
            io = IOBuffer()
            Pkg.status(; io)
            status = String(take!(io))
            for pkg in ["Crayons v", "Example v", "TestSpecificPackage v"]
                @test !occursin(pkg, status)
            end
            @test occursin("Chairmarks v", status)

            # Make a test subproject in PrivatePackage
            # Note that this is a "nested subproject" since in this environment
            # PrivatePackage is a subproject of MonorepoSub
            mkdir("PrivatePackage/test")
            Pkg.activate("PrivatePackage/test")
            # This adds too many packages to the Project file...
            Pkg.add("Test")
            @test length(Pkg.project().dependencies) == 1
            write("PrivatePackage/test/runtests.jl", """
                using Test # nested subproject specific
                using PrivatePackage # subproject package
                using Chairmarks # base project dependency
            """)
            # A nested subproject should still use the root base manifest
            @test !isfile("PrivatePackage/test/Manifest.toml")
            # Test status shows deps in test-subproject + base (MonoRepoSub)
            io = IOBuffer()
            Pkg.status(; io)
            status = String(take!(io))
            for pkg in ["Crayons", "Example", "TestSpecificPackage"]
                @test !occursin(pkg, status)
            end
            @test occursin("Test v", status)

            Pkg.status(; io, all_subprojects=true)
            status = String(take!(io))
            for pkg in ["Crayons", "Example", "Test"]
                @test occursin(pkg, status)
            end

            # Add tests to MonorepoSub
            mkdir("test")
            Pkg.activate("test")
            # Test specific deps
            Pkg.add("Test")
            Pkg.add("Crayons")
            Pkg.compat("Crayons", "=4.0.1, =4.0.2, =4.0.3, =4.0.4")
            # Compat in base package should prevent updating to 4.0.4
            Pkg.update()
            @test Pkg.dependencies()[UUID("a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f")].version == v"4.0.3"
            Pkg.generate("TestSpecificPackage")
            Pkg.develop(path="TestSpecificPackage")
            d = TOML.parsefile("test/Project.toml")
            abs_pkg = abspath("TestSpecificPackage") # TODO: Make relative after #3842 is fixed
            d["sources"] = Dict("TestSpecificPackage" => Dict("path" => abs_pkg))
            Pkg.Types.write_project(d, "test/Project.toml")
            # Test status shows deps in test-subproject + base (MonoRepoSub)
            io = IOBuffer()
            Pkg.status(; io)
            status = String(take!(io))
            for pkg in ["Crayons", "Example", "PrivatePackage", "TestSpecificPackage", "Test"]
                @test occursin(pkg, status)
            end

            @test !isfile("test/Manifest.toml")
            write("test/runtests.jl", """
                using Test # subproject specific
                using PrivatePackage # base project specific with source
                using TestSpecificPackage # subproject specific with source
                using MonorepoSub # base project
                using Example # base project dependency
            """)

            # Test that the subprojects are working
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="test" test/runtests.jl`))
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using MonorepoSub'`))
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="PrivatePackage" -e 'using PrivatePackage'`))
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="PrivatePackage/test" PrivatePackage/test/runtests.jl`))

            rm("Manifest.toml")
            Pkg.activate(".")
            Pkg.resolve()
            # Resolve should have fixed the manifest so that everything above works from the existing project files
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="test" test/runtests.jl`))
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using MonorepoSub'`))
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="PrivatePackage" -e 'using PrivatePackage'`))
            @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="PrivatePackage/test" PrivatePackage/test/runtests.jl`))


        end
    end
end

end # module
