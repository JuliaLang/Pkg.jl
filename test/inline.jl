using Test
using UUIDs
import Pkg

const MARKDOWN_UUID = UUID("d6f4376e-aef5-505a-96c1-9c027394607a")

@testset "Inline project creation and package management" begin
    mktempdir() do dir
        # Start with an empty .jl file
        script_path = joinpath(dir, "inline_app.jl")
        write(script_path, "println(\"hello inline\")\n")

        # Activate the script as the project
        Pkg.activate(script_path)

        # Initialize the project by adding a package
        Pkg.add("Markdown")

        # Verify inline sections were created
        source = read(script_path, String)
        @test contains(source, "#!project begin")
        @test contains(source, "#!manifest begin")

        # Verify project was created correctly
        project = Pkg.Types.read_project(script_path)
        @test haskey(project.deps, "Markdown")
        @test project.deps["Markdown"] == MARKDOWN_UUID

        # Verify manifest was created
        manifest = Pkg.Types.read_manifest(script_path)
        @test haskey(manifest.deps, MARKDOWN_UUID)

        # Test that the original code is preserved
        @test contains(source, "println(\"hello inline\")")
    end
end

@testset "Inline project read/write" begin
    mktempdir() do dir
        # Start with an empty .jl file
        script_path = joinpath(dir, "inline_app2.jl")
        write(script_path, "# My script\n")

        # Activate and add package
        Pkg.activate(script_path)
        Pkg.add("Markdown")

        # Read the project and manifest
        project = Pkg.Types.read_project(script_path)
        @test haskey(project.deps, "Markdown")

        manifest = Pkg.Types.read_manifest(script_path)
        @test haskey(manifest.deps, MARKDOWN_UUID)
        entry = manifest[MARKDOWN_UUID]
        original_version = entry.version

        # Modify and write back
        entry.version = VersionNumber("99.99.99")
        Pkg.Types.write_manifest(manifest, script_path)

        # Reload and verify
        manifest_reloaded = Pkg.Types.read_manifest(script_path)
        @test manifest_reloaded[MARKDOWN_UUID].version == VersionNumber("99.99.99")

        # Verify inline sections still exist
        source = read(script_path, String)
        @test contains(source, "#!project begin")
        @test contains(source, "#!manifest begin")
        @test contains(source, "# My script")
    end
end
