# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg

using Test

@testset "Test that we have imported the correct package" begin
    @test realpath(dirname(dirname(Base.pathof(Pkg)))) == realpath(dirname(@__DIR__))
end

ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
    s = read(`curl -sLI $(server)`, String);
    @info "Pkg Server metadata:\n$s"
end

Pkg.DEFAULT_IO[] = IOBuffer()

include("utils.jl")

@testset "Pkg" verbose = true begin
    @testset "$f" verbose = true for f in [
        "new.jl",
        "pkg.jl",
        "repl.jl",
        "pkg.jl",
        "repl.jl",
        "api.jl",
        "registry.jl",
        "subdir.jl",
        "artifacts.jl",
        "binaryplatforms.jl",
        "platformengines.jl",
        "sandbox.jl",
        "resolve.jl",
        "misc.jl",
        "force_latest_compatible_version.jl",
        "manifests.jl",
        ]
        include(f)
    end
end

end # module
