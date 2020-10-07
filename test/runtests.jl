# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg

ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
    s = read(`curl -sLI $(server)`, String);
    @info "Pkg Server metadata:\n$s"
end

# Make sure to not start with an outdated registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

testfiles = [
    "utils",
    "new",
    "pkg",
    "repl",
    "api",
    "registry",
    "subdir",
    "artifacts",
    "binaryplatforms",
    "platformengines",
    "sandbox",
    "resolve",
]
original_project = Base.active_project()
for testfile in testfiles
    @info "Running test/$(testfile).jl"
    include("$(testfile).jl")
    Pkg.activate(original_project)
end

# clean up locally cached registry
rm(joinpath(@__DIR__, "registries"); force = true, recursive = true)

end # module
