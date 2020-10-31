# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg
using TimerOutputs

using Test

@testset "Ensure we're testing the correct Pkg" begin
    @test realpath(dirname(dirname(Base.pathof(Pkg)))) == realpath(dirname(@__DIR__))
end

ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
    s = read(`curl -sLI $(server)`, String);
    @info "Pkg Server metadata:\n$s"
end

Pkg.DEFAULT_IO[] = IOBuffer()

TimerOutputs.reset_timer!(Pkg.to)

include("utils.jl")

# Clean slate. Make sure to not start with an outdated registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)
rm(Utils.LOADED_DEPOT; force = true, recursive = true)
rm(Utils.REGISTRY_DEPOT; force = true, recursive = true)

include("new.jl")
TimerOutputs.print_timer(Pkg.to)
TimerOutputs.print_timer(TimerOutputs.flatten(Pkg.to))
include("pkg.jl")
include("repl.jl")
include("api.jl")
TimerOutputs.print_timer(Pkg.to)
TimerOutputs.print_timer(TimerOutputs.flatten(Pkg.to))
include("registry.jl")
include("subdir.jl")
TimerOutputs.print_timer(Pkg.to)
TimerOutputs.print_timer(TimerOutputs.flatten(Pkg.to))
include("artifacts.jl")
include("binaryplatforms.jl")
include("platformengines.jl")
include("sandbox.jl")
include("resolve.jl")
include("misc.jl")

TimerOutputs.print_timer(Pkg.to)
TimerOutputs.print_timer(TimerOutputs.flatten(Pkg.to))


# clean up locally cached registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

end # module
