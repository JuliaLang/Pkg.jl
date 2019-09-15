# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg

include("utils.jl")

include("pkg.jl")
include("repl.jl")
include("api.jl")
include("registry.jl")
include("artifacts.jl")
include("binaryplatforms.jl")
include("platformengines.jl")
include("sandbox.jl")
include("resolve.jl")

# clean up locally cached registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

end # module
