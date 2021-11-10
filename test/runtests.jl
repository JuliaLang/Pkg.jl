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

include("new.jl")
include("pkg.jl")
include("repl.jl")
include("api.jl")
include("registry.jl")
include("subdir.jl")
include("artifacts.jl")
include("binaryplatforms.jl")
include("platformengines.jl")
include("sandbox.jl")
include("resolve.jl")
include("misc.jl")
include("force_latest_compatible_version.jl")
include("manifests.jl")

# clean up locally cached registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

end # module
