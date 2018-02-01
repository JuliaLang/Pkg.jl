module Pkg3Tests

using Pkg3
if VERSION < v"0.7.0-DEV.2005"
    using Base.Test
else
    using Test
end

include("operations.jl")
include("resolve.jl")

end # module
