#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "ext"))

# TODO: use Sys.STDLIBDIR instead once implemented
let vers = "v$(VERSION.major).$(VERSION.minor)"
    global stdlibdir = realpath(abspath(Sys.BINDIR, "..", "share", "julia", "stdlib", vers))
    isdir(stdlibdir) || error("stdlib directory does not exist: $stdlibdir")
end
juliadir = dirname(stdlibdir) # used by both loadmeta and genstdlib

include("loadmeta.jl")
include("utils.jl")
include("gitmeta.jl")
include("genstdlib.jl")
include("generate.jl")
