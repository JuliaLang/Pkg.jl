using Test

@testset "ParallelTestB" begin
    sync_dir = ENV["PKG_PARALLEL_SYNC_DIR"]
    touch(joinpath(sync_dir, "ParallelTestB"))
    @test timedwait(() -> isfile(joinpath(sync_dir, "ParallelTestA")), 60) === :ok
end
