# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg
using TimerOutputs

ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
    s = read(`curl -sLI $(server)`, String);
    @info "Pkg Server metadata:\n$s"
end

# Make sure to not start with an outdated registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)


Pkg.DEFAULT_IO[] = IOBuffer()

TimerOutputs.reset_timer!(Pkg.to)

include("utils.jl")
@timeit Pkg.to "new.jl" include("new.jl")
@timeit Pkg.to "pkg.jl" include("pkg.jl")
@timeit Pkg.to "repl.jl" include("repl.jl")
@timeit Pkg.to "api.jl" include("api.jl")
@timeit Pkg.to "registry.jl" include("registry.jl")
@timeit Pkg.to "subdir.jl" include("subdir.jl")
@timeit Pkg.to "artifacts.jl" include("artifacts.jl")
@timeit Pkg.to "binaryplatforms.jl" include("binaryplatforms.jl")
@timeit Pkg.to "platformengines.jl" include("platformengines.jl")
@timeit Pkg.to "sandbox.jl" include("sandbox.jl")
@timeit Pkg.to "resolve.jl" include("resolve.jl")

TimerOutputs.print_timer(Pkg.to)
TimerOutputs.print_timer(TimerOutputs.flatten(Pkg.to))


# clean up locally cached registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

end # module
