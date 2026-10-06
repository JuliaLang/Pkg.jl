module StdlibCompatTests

using Test, UUIDs
import ..Pkg
using Pkg.Types
using ..Utils

@testset "Non-upgradable stdlib compat handling" begin
    mktempdir() do dir
        cd(dir) do
            Pkg.activate(dir) do
                # Create a project with incompatible compat for LibCURL (non-upgradable stdlib)
                write(
                    "Project.toml", """
                    name = "TestProject"
                    uuid = "12345678-1234-1234-1234-123456789012"

                    [deps]
                    LibCURL = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"

                    [compat]
                    LibCURL = "0.6"
                    """
                )
                Pkg.activate(dir)

                # The compat entry is incompatible with current version
                # This should trigger a warning but not error
                @test_logs (:warn, r"Ignoring incompatible compat entry") Pkg.resolve()
            end
        end
    end
end

@testset "registry dep on non-upgradable stdlib with incompatible compat #4801" begin
    # A registered package whose compat on a non-upgradable stdlib excludes the
    # current stdlib version must still get that stdlib in its manifest deps.
    isolate(loaded_depot = true) do
        dp = DEPOT_PATH[1]
        newreg = joinpath(dp, "registries", "NewReg")
        mkpath(newreg)
        write(
            joinpath(newreg, "Registry.toml"), """
            name = "NewReg"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "whydoineedthis?"

            [packages]
            7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
            """
        )
        example_path = joinpath(newreg, "E", "Example")
        mkpath(example_path)
        write(
            joinpath(example_path, "Package.toml"), """
            name = "Example"
            uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
            repo = "https://github.com/JuliaLang/Example.jl.git"
            """
        )
        write(
            joinpath(example_path, "Versions.toml"), """
            ["0.99.99"]
            git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
            """
        )
        write(
            joinpath(example_path, "Deps.toml"), """
            ["0"]
            LibCURL = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
            """
        )
        # No LibCURL version has ever been 0.0.1, so this is incompatible on every Julia
        write(
            joinpath(example_path, "Compat.toml"), """
            ["0"]
            LibCURL = "0.0.1"
            """
        )

        Pkg.add("Example")
        example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
        libcurl_uuid = UUID("b27032c2-a3e7-50c8-80cd-2d36dbcbfd21")
        manifest = Pkg.Types.EnvCache().manifest
        @test manifest[example_uuid].version == v"0.99.99"
        @test haskey(manifest, libcurl_uuid)
        @test manifest[example_uuid].deps["LibCURL"] == libcurl_uuid
    end
end

end # module
