module AppsTests

import ..Pkg # ensure we are using the correct Pkg
using  ..Utils

using Test

@testset "Apps" begin

isolate(loaded_depot=true) do
    sep = Sys.iswindows() ? ';' : ':'
    Pkg.Apps.develop(path=joinpath(@__DIR__, "test_packages", "Rot13.jl"))
    current_path = ENV["PATH"]
    withenv("PATH" => string(current_path, sep, joinpath(first(DEPOT_PATH), "apps"))) do
        @test read(`rot13 test`, String) == "grfg\n"
    end
end

isolate(loaded_depot=true) do
    mktempdir() do tmpdir
        sep = Sys.iswindows() ? ';' : ':'
        path = git_init_package(tmpdir, joinpath(@__DIR__, "test_packages", "Rot13.jl"))
        Pkg.add(path=path)

        current_path = ENV["PATH"]
        withenv("PATH" => string(current_path, sep, joinpath(first(DEPOT_PATH), "apps"))) do
            @test read(`rot13 test`, String) == "grfg\n"
        end
    end
end

end

end # module
