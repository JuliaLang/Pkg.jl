# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTestsOuter

original_depot_path = copy(Base.DEPOT_PATH)
original_load_path = copy(Base.LOAD_PATH)
original_env = copy(ENV)
original_project = Base.active_project()

module PkgTestsInner

import Pkg

# Because julia CI doesn't run stdlib tests via `Pkg.test` test deps must be manually installed if missing
if Base.find_package("HistoricalStdlibVersions") === nothing
    @debug "Installing HistoricalStdlibVersions for Pkg tests"
    iob = IOBuffer()
    Pkg.activate(; temp = true)
    try
        Pkg.add("HistoricalStdlibVersions", io=iob) # Needed for custom julia version resolve tests
    catch
        println(String(take!(iob)))
        rethrow()
    end
end

import HistoricalStdlibVersions

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
hide_logs = Base.get_bool_env("JULIA_PKG_TEST_QUIET", true)

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

Utils.check_init_reg()

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
                "extensions.jl",
                "artifacts.jl",
                "binaryplatforms.jl",
                "platformengines.jl",
                "sandbox.jl",
                "resolve.jl",
                "misc.jl",
                "force_latest_compatible_version.jl",
                "manifests.jl",
                "project_manifest.jl"
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

if haskey(ENV, "CI")
    # if CI don't clean up as it will be slower than the runner filesystem reset
    empty!(Base.Filesystem.TEMP_CLEANUP)
else
    @showtime Base.Filesystem.temp_cleanup_purge(force=true)
end

end # module

empty!(Base.DEPOT_PATH)
empty!(Base.LOAD_PATH)
append!(Base.DEPOT_PATH, original_depot_path)
append!(Base.LOAD_PATH, original_load_path)

for k in setdiff(collect(keys(ENV)), collect(keys(original_env)))
    delete!(ENV, k)
end
for (k, v) in pairs(original_env)
    ENV[k] = v
end

Base.set_active_project(original_project)

end # module
