using Test
using Pkg
using Pkg.Types

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
