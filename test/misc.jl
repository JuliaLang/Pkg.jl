using Test
using Pkg

@testset "inference" begin
    f() = Pkg.Types.STDLIBS_BY_VERSION
    @inferred f()
    f() = Pkg.Types.UNREGISTERED_STDLIBS
    @inferred f()
end

@testset "watchers" begin
    val = Ref(false)
    push!(Pkg.Types.active_project_watcher_thunks, () -> val[] = true)
    push!(Pkg.Types.active_project_watcher_thunks, () -> error("broken"))
    Pkg.Types.notify_active_project_watchers()
    @test val[]
    for _ = 1:2 pop!(Pkg.Types.active_project_watcher_thunks) end  # clean up
end
