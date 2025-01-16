# This file is a part of Julia. License is MIT: https://julialang.org/license

module PkgTestsOuter

original_depot_path = copy(Base.DEPOT_PATH)
original_load_path = copy(Base.LOAD_PATH)
original_env = copy(ENV)
original_project = Base.active_project()

module PkgTestsInner

original_wd = pwd()

import Pkg
using Test, Logging

if realpath(dirname(dirname(Base.pathof(Pkg)))) != realpath(dirname(@__DIR__))
    @show dirname(dirname(Base.pathof(Pkg))) realpath(dirname(@__DIR__))
    error("The wrong Pkg is being tested")
end

ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0
ENV["HISTORICAL_STDLIB_VERSIONS_AUTO_REGISTER"]="false"

logdir = get(ENV, "JULIA_TEST_VERBOSE_LOGS_DIR", nothing)
### Send all Pkg output to a file called Pkg.log
islogging = logdir !== nothing

if islogging
    logfile = joinpath(logdir, "Pkg.log")
    Pkg.DEFAULT_IO[] = open(logfile, "a")
    @info "Pkg test output is being logged to file" logfile
else
    Pkg.DEFAULT_IO[] = devnull # or stdout
end

include("utils.jl")
Logging.with_logger((islogging || Pkg.DEFAULT_IO[] == devnull) ? Logging.ConsoleLogger(Pkg.DEFAULT_IO[]) : Logging.current_logger()) do

    # Because julia CI doesn't run stdlib tests via `Pkg.test` test deps must be manually installed if missing
    if Base.find_package("HistoricalStdlibVersions") === nothing
        @debug "Installing HistoricalStdlibVersions for Pkg tests"
        iob = IOBuffer()
        Pkg.activate(; temp = true)
        try
            # Needed for custom julia version resolve tests
            # Don't use the toplevel PKg.add() command to avoid accidentally installing another copy of the registry
            spec = Pkg.PackageSpec(
                name="HistoricalStdlibVersions", 
                url="https://github.com/JuliaPackaging/HistoricalStdlibVersions.jl",
                rev="5879c5f690795208481c60b904f4af4e8c1eeef8", #= version="2.0.0", =#
                uuid="6df8b67a-e8a0-4029-b4b7-ac196fe72102")
            Pkg.API.handle_package_input!(spec)
            Pkg.add(Pkg.API.Context(), [spec], io=iob)
        catch
            println(String(take!(iob)))
            rethrow()
        end
    end

    @eval import HistoricalStdlibVersions

    if (server = Pkg.pkg_server()) !== nothing && Sys.which("curl") !== nothing
        s = read(`curl -sLI $(server)`, String);
        @info "Pkg Server metadata:\n$s"
    end

    Utils.check_init_reg()

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
                "project_manifest.jl",
                "sources.jl",
                "workspaces.jl",
                "apps.jl",
                ]
                @info "==== Testing `test/$f`"
                flush(Pkg.DEFAULT_IO[])
                include(f)
            end
        finally
            islogging && close(Pkg.DEFAULT_IO[])
            cd(original_wd)
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
