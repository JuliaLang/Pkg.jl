

using  .Utils

@testset "weak deps" begin
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages/", "HasWeakDeps"))
        Pkg.test("HasWeakDeps")
    end
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages/", "HasWeakDepsNoTarget"))
        Pkg.test("HasWeakDepsNoTarget")
    end
    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages/", "HasWeakDeps"))
        io = IOBuffer()
        Pkg.status(; weak=true, io)
        @test contains( String(take!(io)), "(weak: ✘ OffsetArrays)")
        Pkg.add("OffsetArrays")
        @test chomp(read((`$(Base.julia_cmd()) --project=$(Base.active_project()) -e 'using HasWeakDeps; println(HasWeakDeps.offsetarrays_loaded)'`),String)) == "true"
        io = IOBuffer()
        Pkg.status(; weak=true, io)
        @test contains( String(take!(io)), "(weak: ✓ OffsetArrays)")
    end

    isolate(loaded_depot=true) do
        Pkg.activate(; temp=true)
        Pkg.develop(path=joinpath(@__DIR__, "test_packages/", "HasWeakDeps"))
        @test_throws Pkg.Resolve.ResolverError Pkg.add(; name = "OffsetArrays", version = "0.9.0")
    end
end
