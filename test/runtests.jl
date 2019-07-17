# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

include("utils.jl")
include("pkg.jl")
include("sandbox.jl")
include("resolve.jl")

# clean up locally cached registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

end # module
