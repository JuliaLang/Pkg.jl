module AppsTests

import ..Pkg # ensure we are using the correct Pkg
using  ..Utils

using Test

@testset "Apps" begin

isolate(loaded_depot=true) do
    sep = Sys.iswindows() ? ';' : ':'
    Pkg.Apps.develop(path=joinpath(@__DIR__, "test_packages", "Rot13.jl"))
    current_path = ENV["PATH"]
    exename = Sys.iswindows() ? "juliarot13.bat" : "juliarot13"
    withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
        @test contains(Sys.which("$exename"), first(DEPOT_PATH))
        @test read(`$exename test`, String) == "grfg\n"
        Pkg.Apps.rm("Rot13")
        @test Sys.which(exename) == nothing
    end
end

isolate(loaded_depot=true) do
    mktempdir() do tmpdir
        sep = Sys.iswindows() ? ';' : ':'
        path = git_init_package(tmpdir, joinpath(@__DIR__, "test_packages", "Rot13.jl"))
        Pkg.Apps.add(path=path)
        exename = Sys.iswindows() ? "juliarot13.bat" : "juliarot13"
        current_path = ENV["PATH"]
        withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
            @test contains(Sys.which(exename), first(DEPOT_PATH))
            @test read(`$exename test`, String) == "grfg\n"
            Pkg.Apps.rm("Rot13")
            @test Sys.which(exename) == nothing
        end
    end
end

end

end # module
