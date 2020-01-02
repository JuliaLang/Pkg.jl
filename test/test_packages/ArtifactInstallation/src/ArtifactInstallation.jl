module ArtifactInstallation
using Pkg.Artifacts, Test, Libdl
export do_test

function do_test()
    # First, check that `"c_simple"` is installed automatically
    artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
    @test artifact_exists(artifact_hash("c_simple", artifacts_toml))

    # Test that we can use `artifact""` to get at c_simple
    c_simple_exe = joinpath(artifact"c_simple", "bin", "c_simple")
    if Sys.iswindows()
        c_simple_exe = "$(c_simple_exe).exe"
    end
    @test isfile(c_simple_exe)

    # Test that we can use a variable, not just a literal:
    c_simple = "c_simple"
    c_simple_exe = joinpath(@artifact_str(c_simple), "bin", "c_simple")
    if Sys.iswindows()                                                                                    
        c_simple_exe = "$(c_simple_exe).exe"
    end
    @test isfile(c_simple_exe)

    # Test that we can dlopen and ccall libc_simple
    libc_simple_path = if Sys.iswindows()
        joinpath(artifact"c_simple", "bin", "libc_simple.dll")
    elseif Sys.isapple()
        joinpath(artifact"c_simple", "lib", "libc_simple.dylib")
    else
        joinpath(artifact"c_simple", "lib", "libc_simple.so")
    end

    libc_simple = dlopen(libc_simple_path)
    @test libc_simple != nothing
    @test ccall(dlsym(libc_simple, :my_add), Cint, (Cint, Cint), 2, 3) == 5
    dlclose(libc_simple)
end

end
