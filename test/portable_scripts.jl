using Test
using UUIDs
import Pkg

const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

function write_script(path::AbstractString, code::AbstractString)
    open(path, "w") do io
        write(io, code)
    end
end

@testset "Portable scripts inline manifest lifecycle" begin
    mktempdir() do dir
        script_path = joinpath(dir, "portable_script.jl")
        initial_code = """
        #!/usr/bin/env julia
        # portable script

        println("Hello from portable script!")

        function greet(name)
            println("Hello, \$name!")
        end

        greet("World")
        """

        write_script(script_path, initial_code)

        Pkg.activate(script_path)
        Pkg.add("Example")

        content_after_add = read(script_path, String)
        @test occursin("#!project begin", content_after_add)
        @test occursin("#!manifest begin", content_after_add)
        @test occursin("Example", content_after_add)
        @test occursin(initial_code, content_after_add)

        Pkg.add("Example")
        @test read(script_path, String) == content_after_add

        Pkg.rm("Example")
        final_content = read(script_path, String)

        @test occursin(initial_code, final_content)
        @test occursin("#!project begin", final_content)
        @test occursin("#!manifest begin", final_content)
        @test !occursin("Example", final_content)
        @test occursin("#!project end\n\n#!manifest begin", final_content)

        project = Pkg.Types.read_project(script_path)
        @test !haskey(project.deps, "Example")

        manifest = Pkg.Types.read_manifest(script_path)
        @test !haskey(manifest.deps, EXAMPLE_UUID)

        Pkg.activate(; temp = true)
    end
end

@testset "Portable scripts external manifest" begin
    mktempdir() do dir
        script_path = joinpath(dir, "portable_external.jl")
        write_script(script_path, "println(\"portable external\")\n")

        Pkg.activate(script_path)
        Pkg.add("Example")

        project = Pkg.Types.read_project(script_path)
        project.other["inline_manifest"] = false
        Pkg.Types.write_project(project, script_path)

        Pkg.resolve()

        manifest_path = joinpath(dir, "portable_external-Manifest.toml")
        @test isfile(manifest_path)

        source = read(script_path, String)
        @test occursin("#!project begin", source)
        @test !occursin("#!manifest begin", source)
        @test occursin("inline_manifest = false", source)

        manifest = Pkg.Types.read_manifest(manifest_path)
        @test haskey(manifest.deps, EXAMPLE_UUID)

        Pkg.rm("Example")
        Pkg.activate(; temp = true)
    end
end
