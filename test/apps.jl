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
    cliexename = Sys.iswindows() ? "juliarot13cli.bat" : "juliarot13cli"
    withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
        # Test original app
        @test contains(Sys.which("$exename"), first(DEPOT_PATH))
        @test read(`$exename test`, String) == "grfg\n"

        # Test submodule app
        @test contains(Sys.which("$cliexename"), first(DEPOT_PATH))
        @test read(`$cliexename test`, String) == "CLI: grfg\n"

        Pkg.Apps.rm("Rot13")
        @test Sys.which(exename) == nothing
        @test Sys.which(cliexename) == nothing
    end
end

isolate(loaded_depot=true) do
    mktempdir() do tmpdir
        sep = Sys.iswindows() ? ';' : ':'
        path = git_init_package(tmpdir, joinpath(@__DIR__, "test_packages", "Rot13.jl"))
        Pkg.Apps.add(path=path)
        exename = Sys.iswindows() ? "juliarot13.bat" : "juliarot13"
        cliexename = Sys.iswindows() ? "juliarot13cli.bat" : "juliarot13cli"
        current_path = ENV["PATH"]
        withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
            # Test original app
            @test contains(Sys.which(exename), first(DEPOT_PATH))
            @test read(`$exename test`, String) == "grfg\n"

            # Test submodule app
            @test contains(Sys.which(cliexename), first(DEPOT_PATH))
            @test read(`$cliexename test`, String) == "CLI: grfg\n"

            Pkg.Apps.rm("Rot13")
            @test Sys.which(exename) == nothing
            @test Sys.which(cliexename) == nothing
        end

        # https://github.com/JuliaLang/Pkg.jl/issues/4258
        Pkg.Apps.add(path=path)
        Pkg.Apps.develop(path=path)
        mv(joinpath(path, "src", "Rot13_edited.jl"), joinpath(path, "src", "Rot13.jl"); force=true)
        withenv("PATH" => string(joinpath(first(DEPOT_PATH), "bin"), sep, current_path)) do
            @test read(`$exename test`, String) == "Updated!\n"
        end
    end
end

end

end # module
