using Test

@testset "ParallelTestA" begin
    sync_dir = ENV["PKG_PARALLEL_SYNC_DIR"]
    touch(joinpath(sync_dir, "ParallelTestA"))
    @test timedwait(() -> isfile(joinpath(sync_dir, "ParallelTestB")), 60) === :ok
end
