using Test

# Part of the parallel `Pkg.test` regression test (see test/pkg.jl). Each package's
# test process announces itself in a shared directory and then waits until every
# sibling process has announced too. When the packages are tested concurrently all
# announcements appear and the wait returns quickly; when tested serially a process
# only ever sees its own announcement and the wait times out. A passing run therefore
# proves the test processes ran at the same time.
@testset "ParallelTestA" begin
    sync_dir = ENV["PKG_PARALLEL_SYNC_DIR"]
    touch(joinpath(sync_dir, "ParallelTestA"))
    # Block until ParallelTestB's process starts, proving the two ran concurrently.
    @test timedwait(() -> isfile(joinpath(sync_dir, "ParallelTestB")), 60) === :ok
end
