using Test
using Pkg
using Pkg.Types

@testset "Non-upgradable stdlib compat handling" begin
    mktempdir() do dir
        cd(dir) do
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

            # Get the LibCURL version in the current Julia
            libcurl_uuid = Base.UUID("b27032c2-a3e7-50c8-80cd-2d36dbcbfd21")
            libcurl_version = Pkg.Types.stdlib_version(libcurl_uuid, VERSION)

            # The compat entry is incompatible with current version
            # This should trigger a warning but not error
            ctx = Pkg.Types.Context()

            # Test that get_compat_workspace ignores the incompatible compat
            compat = Pkg.Operations.get_compat_workspace(ctx.env, "LibCURL")

            # Should return unrestricted spec for non-upgradable stdlib with incompatible compat
            @test compat == Pkg.Types.VersionSpec("*")

            @test_logs (:warn, r"Ignoring incompatible compat entry") Pkg.resolve()
        end
    end
end
