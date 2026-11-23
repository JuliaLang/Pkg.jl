# A `pkg status` executable: the part of Pkg that compiles with `--trim=safe` today.
#
#     julia -m JuliaC --experimental --trim=safe --project <env with Pkg> \
#         --output-exe pkg-status --bundle build contrib/juliac/status.jl
#
# Pkg reads the stdlib projects from `Sys.STDLIB`, so the bundle needs `share/julia/stdlib`
# (or the executable has to live next to a `julia`).

import Pkg

include("overrides.jl")

function (@main)(args::Vector{String})::Cint
    try
        isempty(args) || Base.set_active_project(abspath(args[1]))
        Pkg.API.status(Pkg.Types.Context(; io = Pkg.stderr_f()), Pkg.PackageSpec[]; io = Pkg.stdout_f())
    catch err
        # an uncaught error crashes a trimmed binary
        println(Core.stderr, "ERROR: ", Pkg.errorstring(err))
        return 1
    end
    return 0
end
