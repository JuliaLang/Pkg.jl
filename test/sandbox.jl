module SandboxTests
import ..Pkg # ensure we are using the correct Pkg

using Test
using UUIDs
using Pkg

using ..Utils
test_test(fn, name; kwargs...) = Pkg.test(name; test_fn=fn, kwargs...)
test_test(fn; kwargs...)       = Pkg.test(;test_fn=fn, kwargs...)

@testset "Basic `test` sandboxing" begin
    # also indirectly checks that test `compat` is obeyed
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "SandboxFallback2")
        Pkg.activate(joinpath(tmp, "SandboxFallback2"))
        test_test("Unregistered") do
            json = get(Pkg.Types.Context().env.manifest, UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6"), nothing)
            @test json !== nothing
            @test json.version == v"0.20.0"
        end
    end end
    # test dependencies should be preserved, when possible
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "Sandbox_PreserveTestDeps")
        Pkg.activate(joinpath(tmp, "Sandbox_PreserveTestDeps"))
        test_test("Foo") do
            x = get(Pkg.Types.Context().env.manifest, UUID("7876af07-990d-54b4-ab0e-23690620f79a"), nothing)
            @test x !== nothing
            @test x.version == v"0.4.0"
        end
    end end
end

@testset "Basic `build` sandbox" begin
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "BasicSandbox")
        Pkg.activate(joinpath(tmp, "BasicSandbox"))
        Pkg.build()
    end end
end

end # module
