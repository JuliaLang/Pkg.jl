module ConcurrentTests

using Test, UUIDs
import ..Pkg
using ..Utils

function kill_with_info(p)
    if Sys.islinux()
        SIGINFO = 10
    elseif Sys.isbsd()
        SIGINFO = 29
    end
    if @isdefined(SIGINFO)
        kill(p, SIGINFO)
        timedwait(() -> process_exited(p), 20; pollint = 1.0) # Allow time for profile to collect and print before killing
    end
    kill(p)
    wait(p)
    return nothing
end

# This test tests that multiple julia processes can install within same depot concurrently without
# corrupting the depot and being able to load the package. Only one process will do each of these, others will wait on
# the specific action for the specific thing:
# - Install the default registries
# - Install source of package and deps
# - Install artifacts
# - Precompile package and deps
# - Load & use package
@testset "Concurrent setup/installation/precompilation across processes" begin
    @testset for test in 1:1 # increase for stress testing
        mktempdir() do tmp
            pathsep = Sys.iswindows() ? ";" : ":"
            Pkg_dir = dirname(@__DIR__)
            script = """
            using Dates
            t = Timer(t->println(stderr, Dates.now()), 4*60; interval = 10)
            import Pkg
            samefile(pkgdir(Pkg), $(repr(Pkg_dir))) || error("Using wrong Pkg")
            Pkg.activate(temp=true)
            Pkg.add(name="FFMPEG", version="0.4") # a package with a lot of deps but fast to load
            using FFMPEG
            @showtime FFMPEG.exe("-version")
            @showtime FFMPEG.exe("-f", "lavfi", "-i", "testsrc=duration=1:size=128x128:rate=10", "-f", "null", "-") # more complete quick test (~10ms)
            close(t)
            """
            cmd = addenv(
                `$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) --startup-file=no --color=no -e $script`,
                "JULIA_DEPOT_PATH" => join([tmp, LOADED_DEPOT, ""], pathsep)
            )
            did_install_package = Threads.Atomic{Int}(0)
            did_install_artifact = Threads.Atomic{Int}(0)
            any_failed = Threads.Atomic{Bool}(false)
            outputs = fill("", 3)
            t = @elapsed @sync begin
                # All but 1 process should be waiting, so should be ok to run many
                for i in 1:3
                    Threads.@spawn begin
                        iob = IOBuffer()
                        start = time()
                        p = run(pipeline(cmd, stdout = iob, stderr = iob), wait = false)
                        if timedwait(() -> process_exited(p), 5 * 60; pollint = 1.0) === :timed_out
                            kill_with_info(p)
                        end
                        if !success(p)
                            Threads.atomic_cas!(any_failed, false, true)
                        end
                        str = String(take!(iob))
                        if occursin(r"Installed FFMPEG ─", str)
                            Threads.atomic_add!(did_install_package, 1)
                        end
                        if occursin(r"Installed artifact FFMPEG ", str)
                            Threads.atomic_add!(did_install_artifact, 1)
                        end
                        outputs[i] = string("=== test $test, process $i. Took $(time() - start) seconds.\n", str)
                    end
                end
            end
            if any_failed[] || did_install_package[] != 1 || did_install_artifact[] != 1
                println("=== Concurrent Pkg.add test $test failed after $t seconds")
                for i in 1:3
                    printstyled(stdout, outputs[i]; color = (:blue, :green, :yellow)[i])
                end
            end
            # only 1 should have actually installed FFMPEG
            @test !any_failed[]
            @test did_install_package[] == 1
            @test did_install_artifact[] == 1
        end
    end
end

@testset "test atomicity of write_env_usage with $(Sys.CPU_THREADS) parallel processes" begin
    Sys.CPU_THREADS == 1 && error("Cannot test for atomic usage log file interaction effectively with only Sys.CPU_THREADS=1")
    isolate(loaded_depot = true) do
        tasks = Task[]
        iobs = IOBuffer[]
        # Precompile Pkg given we're in a different depot
        # and make sure the General registry is installed
        flag_start_dir = mktempdir() # once n=Sys.CPU_THREADS files are in here, the processes can proceed to the concurrent test
        flag_end_file = tempname() # use creating this file as a way to stop the processes early if an error happens
        for i in 1:Sys.CPU_THREADS
            iob = IOBuffer()
            t = @async run(
                pipeline(
                    addenv(
                        `$(Base.julia_cmd()) --project="$(pkgdir(Pkg))"
                -e "import Pkg;
                Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true;
                Pkg.activate(temp = true);
                Pkg.add(\"Random\", io = devnull);
                touch(tempname(raw\"$flag_start_dir\")*raw\"$i\") # file marker that first part has finished
                while length(readdir(raw\"$flag_start_dir\")) < $(Sys.CPU_THREADS)
                    # sync all processes to start at the same time
                    sleep(0.1)
                end
                @async begin
                    sleep(15)
                    touch(raw\"$flag_end_file\")
                end
                i = 0
                while !isfile(raw\"$flag_end_file\")
                    global i += 1
                    try
                        Pkg.Types.EnvCache()
                    catch
                        touch(raw\"$flag_end_file\")
                        println(stderr, \"Errored after $i iterations\")
                        rethrow()
                    end
                    yield()
                end"`, "JULIA_DEPOT_PATH" => join(Base.DEPOT_PATH, Sys.iswindows() ? ";" : ":")
                    ),
                    stderr = iob, stdout = devnull
                )
            )
            push!(tasks, t)
            push!(iobs, iob)
        end
        for i in eachindex(tasks)
            try
                fetch(tasks[i]) # If any of these failed it will throw when fetched
            catch
                print(String(take!(iobs[i])))
                break
            end
        end
        @test any(istaskfailed, tasks) == false
    end
end

end # module
