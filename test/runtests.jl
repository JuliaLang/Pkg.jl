# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg
using TimerOutputs
using Test
macro testsection(str, block)
    return quote
        @timeit Pkg.to "$($(esc(str)))" begin
            @testset "$($(esc(str)))" begin
                $(esc(block))
            end
        end
    end
end

reset_timer!(Pkg.to)
try
    include("utils.jl")
    include("pkg.jl")
    include("binaryplatforms.jl")
    include("platformengines.jl")
    include("sandbox.jl")
    include("resolve.jl")

    # clean up locally cached registry
    rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)
finally
    print_timer(TimerOutputs.flatten(Pkg.to))

    println()
    println("-------------------------------------------------------------------")
    println("-------------------------------------------------------------------")
    println("-------------------------------------------------------------------")
    println("-------------------------------------------------------------------")
    println()

    print_timer(Pkg.to)
    println()
end

end # module
