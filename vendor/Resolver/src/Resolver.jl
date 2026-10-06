module Resolver

export resolve, issatisfiable, Problem, Diagnosis

include("BitKernels.jl")
include("DepsProvider.jl")
include("Problem.jl")
include("PkgInfo.jl")
include("PkgInfoFiles.jl")
include("FilterPkgs.jl")
include("PicoSAT.jl")
include("Clauses.jl")
include("SAT.jl")
include("UnsatCores.jl")
using .UnsatCores # the API; not re-exported from Resolver
include("Resolve.jl")
include("Diagnostics.jl")
using .Diagnostics: Diagnosis # `resolve`'s answer; nothing else re-exported

end # module
