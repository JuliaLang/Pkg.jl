# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg
Pkg.API.RUNNING_CI[] = true
old_depot_path = copy(DEPOT_PATH)
depot_dir = mktempdir()
try
    empty!(DEPOT_PATH)
    push!(DEPOT_PATH, depot_dir)
    include("utils.jl")
    include("pkg.jl")
    include("binaryplatforms.jl")
    include("platformengines.jl")
    include("sandbox.jl")
    include("resolve.jl")

    # clean up locally cached registry
    rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)
finally
    Base.rm(depot_dir; force=true, recursive=true)
end

end # module
