# This file is a part of Julia. License is MIT: https://julialang.org/license

module ScriptsTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg, UUIDs, TOML
using ..Utils

const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

@testset "scripts with inline project metadata" begin
    @testset "write_script_block" begin
        mktempdir() do dir
            path = joinpath(dir, "s.jl")
            # inserting a project block after the leading comments, and a manifest block last
            write(path, "#!/usr/bin/env julia\n# a script\nprintln(1)\n")
            Pkg.Types.write_script_block(path, "project", "[deps]\nA = \"1\"\n")
            @test read(path, String) == "#!/usr/bin/env julia\n# a script\n# /// project\n# [deps]\n# A = \"1\"\n# ///\n\nprintln(1)\n"
            Pkg.Types.write_script_block(path, "manifest", "julia_version = \"1.13.0\"\n\n[[deps.A]]\nuuid = \"1\"\n")
            @test endswith(read(path, String), "println(1)\n\n# /// manifest\n# julia_version = \"1.13.0\"\n#\n# [[deps.A]]\n# uuid = \"1\"\n# ///\n")
            @test Base.has_project_block(path)
            # replacing keeps the rest of the file
            Pkg.Types.write_script_block(path, "project", "[deps]\nB = \"2\"\n")
            content = read(path, String)
            @test occursin("# /// project\n# [deps]\n# B = \"2\"\n# ///\n\nprintln(1)\n", content)
            @test occursin("# /// manifest\n", content)
            @test count("# ///", content) == 4
            # removing takes an adjacent blank line with it
            Pkg.Types.write_script_block(path, "manifest", nothing)
            @test read(path, String) == "#!/usr/bin/env julia\n# a script\n# /// project\n# [deps]\n# B = \"2\"\n# ///\n\nprintln(1)\n"
            # a manifest block that code was added after moves back to the end
            write(path, "# /// project\n# ///\n\n# /// manifest\n# a = 1\n# ///\nprintln(2)\n")
            Pkg.Types.write_script_block(path, "manifest", "a = 2\n")
            @test read(path, String) == "# /// project\n# ///\n\nprintln(2)\n\n# /// manifest\n# a = 2\n# ///\n"
            # blank lines after the leading comments stay after the block
            write(path, "#!/usr/bin/env julia\n\nprintln(1)\n")
            Pkg.Types.write_script_block(path, "project", "")
            @test read(path, String) == "#!/usr/bin/env julia\n# /// project\n# ///\n\nprintln(1)\n"
            # an empty file and an empty block
            write(path, "")
            Pkg.Types.write_script_block(path, "project", "")
            @test read(path, String) == "# /// project\n# ///\n"
            # CRLF is preserved
            write(path, "x = 1\r\ny = 2\r\n")
            Pkg.Types.write_script_block(path, "project", "[deps]\n")
            @test read(path, String) == "# /// project\r\n# [deps]\r\n# ///\r\n\r\nx = 1\r\ny = 2\r\n"
        end
    end

    isolate(loaded_depot = true) do
        @testset "activate, add, rm with an inline manifest" begin
            mktempdir() do dir
                script = joinpath(dir, "script.jl")
                code = "#!/usr/bin/env julia\n\nusing Example\nprintln(Example.hello(\"world\"))\n"
                write(script, code)
                Pkg.activate(script)
                @test Base.active_project() == script
                @test Base.is_script_env(script)
                @test !Base.has_project_block(script) # an empty project until something is written
                @test isempty(Pkg.Types.read_project(script).deps)
                @test !Pkg.Types.manifest_exists(Pkg.Types.EnvCache())
                Pkg.add("Example")
                @test Base.has_project_block(script)
                content = read(script, String)
                @test startswith(content, "#!/usr/bin/env julia\n# /// project\n# [deps]\n# Example = \"7876af07-990d-54b4-ab0e-23690620f79a\"\n# ///\n\nusing Example\n")
                @test occursin("\n# /// manifest\n", content)
                @test occursin("# [[deps.Example]]\n", content)
                @test !occursin("machine-generated", content)
                @test endswith(content, "# ///\n")
                @test Base.active_manifest() == script
                project = Pkg.Types.read_project(script)
                @test project.deps["Example"] == EXAMPLE_UUID
                manifest = Pkg.Types.read_manifest(script)
                @test haskey(manifest, EXAMPLE_UUID)
                @test Pkg.Types.manifest_exists(Pkg.Types.EnvCache())
                # precompilation sees the script's environment
                Pkg.precompile("Example")
                @test Base.isprecompiled(Base.PkgId(EXAMPLE_UUID, "Example"))
                # the script runs in its own environment
                @test readchomp(`$(Base.julia_cmd()) --startup-file=no $script`) == "Hello, world"
                # status shows the script
                @test occursin("Example", sprint(io -> Pkg.status(; io)))
                # a no-op does not touch the file
                mtime_before = mtime(script)
                Pkg.add("Example")
                @test read(script, String) == content
                # comments inside the project block survive
                content = replace(content, "# [deps]\n" => "# # my deps\n# [deps]\n")
                write(script, content)
                Pkg.compat("Example", "0.5")
                content = read(script, String)
                @test occursin("# # my deps\n# [deps]\n", content)
                @test occursin("# [compat]\n# Example = \"0.5\"\n", content)
                Pkg.rm("Example")
                content = read(script, String)
                @test !occursin("7876af07", content)
                @test occursin("# /// project\n# ///\n", content) && occursin("# /// manifest\n", content)
                @test occursin("\nusing Example\nprintln(Example.hello(\"world\"))\n", content)
                @test !haskey(Pkg.Types.read_project(script).deps, "Example")
                @test !haskey(Pkg.Types.read_manifest(script), EXAMPLE_UUID)
                Pkg.activate(; temp = true)
            end
        end

        @testset "manifest in a separate file" begin
            mktempdir() do dir
                script = joinpath(dir, "script.jl")
                write(script, "using Example\n")
                Pkg.activate(script)
                # a path dependency, to check that relative paths survive the move
                dev_path = copy_test_package(dir, "Example")
                Pkg.develop(path = dev_path)
                @test occursin("# /// manifest", read(script, String))
                @test Pkg.Types.manifest_exists(Pkg.Types.EnvCache())
                # moving the manifest out, into a subdirectory
                content = replace(read(script, String), "# /// project\n" => "# /// project\n# manifest = \"env/Manifest.toml\"\n")
                write(script, content)
                manifest_file = joinpath(dir, "env", "Manifest.toml")
                # the inline manifest is still the manifest until it has been written out
                @test Pkg.Types.manifest_exists(Pkg.Types.EnvCache())
                Pkg.resolve()
                @test isfile(manifest_file)
                manifest = Pkg.Types.read_manifest(manifest_file)
                entry = only(e for (_, e) in manifest if e.name == "Example")
                @test realpath(joinpath(dirname(manifest_file), entry.path)) == realpath(dev_path)
                content = read(script, String)
                @test !occursin("# /// manifest", content)
                @test occursin("# manifest = \"env/Manifest.toml\"", content)
                @test Base.active_manifest() == manifest_file
                @test readchomp(`$(Base.julia_cmd()) --startup-file=no $script`) == ""
                Pkg.rm("Example")
                @test !any(e.name == "Example" for (_, e) in Pkg.Types.read_manifest(manifest_file))
                Pkg.activate(; temp = true)
            end
        end

        @testset "instantiate resolves a manifest for a script" begin
            mktempdir() do dir
                script = joinpath(dir, "script.jl")
                write(
                    script, """
                    # /// project
                    # [deps]
                    # Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                    # ///
                    using Example
                    """
                )
                Pkg.activate(script)
                Pkg.instantiate()
                @test haskey(Pkg.Types.read_manifest(script), EXAMPLE_UUID)
                Pkg.activate(; temp = true)
            end
        end

        @testset "status diff of a committed script" begin
            mktempdir() do dir
                script = joinpath(dir, "script.jl")
                write(script, "using Example\n")
                Pkg.activate(script)
                Pkg.add("Example")
                git_init_and_commit(dir)
                Pkg.rm("Example")
                io = IOBuffer()
                Pkg.status(; diff = true, io)
                @test occursin("- Example", String(take!(io)))
                Pkg.activate(; temp = true)
            end
        end

        @testset "pkg> activate and prompt" begin
            mktempdir() do dir
                script = joinpath(dir, "tool.jl")
                write(script, "println(1)\n")
                cd(dir) do
                    Pkg.REPLMode.pkgstr("activate tool.jl")
                end
                @test Base.active_project() == script
                @test Base.is_script_env(script)
                Pkg.REPLMode.pkgstr("add Example")
                @test Base.has_project_block(script)
                @test haskey(Pkg.Types.read_project(script).deps, "Example")
                # an empty file works too
                empty = joinpath(dir, "empty.jl")
                touch(empty)
                Pkg.activate(empty)
                Pkg.add("Example")
                @test startswith(read(empty, String), "# /// project\n# [deps]\n# Example = ")
                Pkg.activate(; temp = true)
            end
        end
    end
end

end # module
