module StdlibCompatTests

using Test, UUIDs
import ..Pkg
using Pkg.Types
using ..Utils

const libcurl_uuid = UUID("b27032c2-a3e7-50c8-80cd-2d36dbcbfd21")

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

@testset "Incompatible stdlib compat in a registry package keeps the stdlib as a dep (#4801)" begin
    isolate(loaded_depot = true) do
        # A registry whose Example entry depends on the non-upgradable stdlib LibCURL
        # with a compat bound that no Julia version satisfies. The bad bound must be
        # ignored, but LibCURL itself has to stay a dependency and end up in the manifest.
        dp = DEPOT_PATH[1]
        newreg = joinpath(dp, "registries", "StdlibCompatReg")
        example_path = joinpath(newreg, "E", "Example")
        mkpath(example_path)
        write(
            joinpath(newreg, "Registry.toml"), """
            name = "StdlibCompatReg"
            uuid = "5f6a2c1e-8d3b-4c7a-9e21-3b4f5a6c7d8e"
            repo = "https://example.com/StdlibCompatReg.git"

            [packages]
            7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
            """
        )
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
            [0]
            LibCURL = "$libcurl_uuid"
            """
        )
        write(
            joinpath(example_path, "Compat.toml"), """
            [0]
            LibCURL = "0.0.1"
            """
        )

        Pkg.add(name = "Example", version = v"0.99.99")

        manifest = Pkg.Types.Context().env.manifest
        @test manifest[TEST_PKG.uuid].version == v"0.99.99"
        @test haskey(manifest[TEST_PKG.uuid].deps, "LibCURL")
        @test haskey(manifest, libcurl_uuid)
        @test manifest[libcurl_uuid].version == Pkg.Types.stdlib_version(libcurl_uuid, VERSION)
    end
end

end # module
