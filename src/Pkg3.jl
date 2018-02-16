__precompile__(true)
module Pkg3

import Random
import REPL
using REPL.TerminalMenus

depots() = Base.DEPOT_PATH
logdir() = joinpath(depots()[1], "logs")

# load snapshotted dependencies
include("../ext/TOML/src/TOML.jl")

include("PlatformEngines.jl")
include("Types.jl")
include("GraphType.jl")
include("Resolve.jl")
include("Display.jl")
include("Operations.jl")
include("REPLMode.jl")
include("API.jl")

import .API: add, rm, up, test, gc, init, build, installed
const update = up

function __init__()
    if isdefined(Base, :active_repl)
        REPLMode.repl_init(Base.active_repl)
    else
        atreplinit() do repl
            repl.interface = REPL.setup_interface(repl)
            REPLMode.repl_init(repl)
        end
    end
end

end # module
