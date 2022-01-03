# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTests

import Pkg

using Test, Logging

@testset "Test that we have imported the correct package" begin
    @test realpath(dirname(dirname(Base.pathof(Pkg)))) == realpath(dirname(@__DIR__))
end

ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
    s = read(`curl -sLI $(server)`, String);
    @info "Pkg Server metadata:\n$s"
end

Pkg.DEFAULT_IO[] = IOBuffer()
Pkg.REPLMode.minirepl[] = Pkg.REPLMode.MiniREPL() # re-set this given DEFAULT_IO has changed

### LOGGING OUTPUT IS SUPPRESSED BY DEFAULT
quiet = Pkg.get_bool_env("JULIA_PKG_TEST_QUIET", default="true")

include("utils.jl")

Logging.with_logger(quiet ? Logging.NullLogger() : Logging.current_logger()) do
    @testset "Pkg" begin
        @testset "$f" for f in [
            "new.jl",
            "pkg.jl",
            "repl.jl",
            "api.jl",
            "registry.jl",
            "subdir.jl",
            "artifacts.jl",
            "binaryplatforms.jl",
            "platformengines.jl",
            "sandbox.jl",
            "resolve.jl",
            "misc.jl",
            "force_latest_compatible_version.jl",
            "manifests.jl",
            ]
            flush(Pkg.DEFAULT_IO[])
            include(f)
        end
    end
end

end # module
