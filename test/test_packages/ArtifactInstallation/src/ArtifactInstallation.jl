module ArtifactInstallation
using Pkg.Artifacts, Test, Libdl
export do_test

function do_test()
    # First, check that `"HelloWorldC"` is installed automatically
    artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
    @test artifact_exists(artifact_hash("HelloWorldC", artifacts_toml))

    # Test that we can use `artifact""` to get at HelloWorldC
    hello_world_exe = joinpath(artifact"HelloWorldC", "bin", "hello_world")
    if Sys.iswindows()
        hello_world_exe = "$(hello_world_exe).exe"
    end
    @test isfile(hello_world_exe)

    # Test that we can use a variable, not just a literal:
    hello_world = "HelloWorldC"
    hello_world_exe = joinpath(@artifact_str(hello_world), "bin", "hello_world")
    if Sys.iswindows()                                                                                    
        hello_world_exe = "$(hello_world_exe).exe"
    end
    @test isfile(hello_world_exe)
end

end
