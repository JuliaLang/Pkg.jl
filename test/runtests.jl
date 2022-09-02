# This file is a part of Julia. License is MIT: https://julialang.org/license

@info "Before the Pkg tests" Base.DEPOT_PATH

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

### Disable logging output if true (default)
hide_logs = Pkg.get_bool_env("JULIA_PKG_TEST_QUIET", default="true")

logdir = get(ENV, "JULIA_TEST_VERBOSE_LOGS_DIR", nothing)
### Send all Pkg output to a file called Pkg.log

islogging = logdir !== nothing

if islogging
    logfile = joinpath(logdir, "Pkg.log")
    Pkg.DEFAULT_IO[] = open(logfile, "a")
    @info "Pkg test output is being logged to file" logfile
elseif hide_logs
    Pkg.DEFAULT_IO[] = Base.BufferStream()
    @info "Pkg test output is silenced"
else
    Pkg.DEFAULT_IO[] = stdout
end

Pkg.REPLMode.minirepl[] = Pkg.REPLMode.MiniREPL() # re-set this given DEFAULT_IO has changed

include("utils.jl")

Logging.with_logger(hide_logs ? Logging.NullLogger() : Logging.current_logger()) do
    @testset "Pkg" begin
        try
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
                @info "==== Testing `test/$f`"
                flush(Pkg.DEFAULT_IO[])
                include(f)
            end
        finally
            islogging && close(Pkg.DEFAULT_IO[])
        end
    end
end

@showtime Base.Filesystem.temp_cleanup_purge(force=true)

end # module

@info "After the Pkg tests" Base.DEPOT_PATH
