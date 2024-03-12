module SubProjectsTest

import ..Pkg # ensure we are using the correct Pkg
using Test
using TOML
using UUIDs

tmp = mktempdir()
cd(tmp) do
    name = "MonorepoSub"
    rm(name, force=true, recursive=true)
    Pkg.generate(name)
    cd("MonorepoSub")
    Pkg.activate(".")
    Pkg.add("Example")
    Pkg.add("Crayons")
    Pkg.compat("Crayons", "=4.0.0, =4.0.1, =4.0.2, =4.0.3")
    Pkg.generate("PrivatePackage")
    Pkg.develop(path="PrivatePackage")

    d = TOML.parsefile("Project.toml")
    d["subprojects"] = ["test", "docs", "benchmarks"]
    d["sources"] = Dict("PrivatePackage" => Dict("path" => "PrivatePackage"))
    Pkg.Types.write_project(d, "Project.toml")
    # Add tests
    mkdir("test")
    Pkg.generate("TestSpecificPackage")
    Pkg.activate("test")
    Pkg.add("Test")
    Pkg.add("Crayons")
    Pkg.compat("Crayons", "=4.0.1, =4.0.2, =4.0.3, =4.0.4")
    # Compat in base package should prevent updating to 4.0.4
    Pkg.update()
    @test Pkg.dependencies()[UUID("a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f")].version == v"4.0.3"

    Pkg.develop(path="TestSpecificPackage")
    d = TOML.parsefile("test/Project.toml")
    d["sources"] = Dict("TestSpecificPackage" => Dict("path" => "TestSpecificPackage"))
    Pkg.Types.write_project(d, "test/Project.toml")

    @test !isfile("test/Manifest.toml")
    write("test/runtests.jl", """
        using Test # subproject specific
        using PrivatePackage # base project specific with source
        using TestSpecificPackage # subproject specific with source
        using MonorepoSub # base project
        using Example # base project dependency
    """)
    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="test" test/runtests.jl`))

    # Test loading the package itself
    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using MonorepoSub'`))

    rm("Manifest.toml")
    Pkg.resolve()
    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project="test" test/runtests.jl`))
    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using MonorepoSub'`))
end

end
