# Entry point for compiling the `pkg` command-line interface to a native executable:
#
#     julia -m JuliaC --experimental --trim=safe --project <env with Pkg> \
#         --output-exe pkg --bundle build contrib/juliac/pkg.jl

import Pkg

include("overrides.jl")

using Pkg: main
