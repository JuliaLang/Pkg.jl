#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "ext"))

# Used by both loadmeta and genstdlib, assumed to be a git repo
juliadir = dirname(Sys.STDLIB)

include("loadmeta.jl")
include("utils.jl")
include("gitmeta.jl")
include("genstdlib.jl")
include("generate.jl")
