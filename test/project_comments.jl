# This file is a part of Julia. License is MIT: https://julialang.org/license

module ProjectCommentsTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg, TOML
using ..Utils

# Comment preservation requires TOML stdlib support (Julia 1.14+, JuliaLang/julia#42697)
if !Pkg.Types.TOML_COMMENTS_SUPPORTED
    @info "Skipping Project.toml comment preservation tests (TOML stdlib does not support comments)"
else
    @testset "Project.toml comment preservation" begin
        commented_project = """
        # This is my package

        name = "MyPkg"
        uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
        version = "1.0.3"

        [deps]
        # `Example` is used for fooing bars
        Example = "7876af07-990d-54b4-ab0e-23690620f79a"

        [compat]
        Example = "0.5" # see issue 123 before bumping
        julia = "1"
        """

        @testset "read_project/write_project round trip" begin
            mktempdir() do dir
                project_file = joinpath(dir, "Project.toml")
                write(project_file, commented_project)
                project = Pkg.Types.read_project(project_file)
                @test project.comments isa TOML.Comments
                out_file = joinpath(dir, "Project_out.toml")
                Pkg.Types.write_project(project, out_file)
                str = read(out_file, String)
                @test occursin("# This is my package", str)
                @test occursin("# `Example` is used for fooing bars", str)
                @test occursin("Example = \"0.5\" # see issue 123 before bumping", str)
                # the floating preamble comment is at the top of the file
                @test startswith(str, "# This is my package")
                # a second write of the re-read project is byte-identical
                project2 = Pkg.Types.read_project(out_file)
                out_file2 = joinpath(dir, "Project_out2.toml")
                Pkg.Types.write_project(project2, out_file2)
                @test read(out_file2, String) == str
            end
        end

        @testset "comments do not affect Project equality" begin
            io = IOBuffer(commented_project)
            a = Pkg.Types.read_project(io)
            b = Pkg.Types.read_project(IOBuffer(replace(commented_project, "# This is my package" => "# Changed comment")))
            @test a == b
            @test hash(a) == hash(b)
        end

        @testset "Pkg.compat preserves comments" begin
            isolate(loaded_depot = true) do
                mktempdir() do dir
                    project_file = joinpath(dir, "Project.toml")
                    write(project_file, commented_project)
                    Pkg.activate(dir)
                    # instantiate the environment first; `Pkg.compat` resolves
                    # to check compliance, which requires an installed registry
                    Pkg.add("Example")
                    Pkg.compat("Example", "0.5.1")
                    str = read(project_file, String)
                    @test occursin("Example = \"0.5.1\"", str)
                    @test occursin("# This is my package", str)
                    @test occursin("# `Example` is used for fooing bars", str)
                    # the inline comment stays attached to the compat entry it was on
                    @test occursin("Example = \"0.5.1\" # see issue 123 before bumping", str)
                end
            end
        end

        @testset "Pkg.rm drops the removed dep's comments" begin
            isolate(loaded_depot = true) do
                mktempdir() do dir
                    project_file = joinpath(dir, "Project.toml")
                    write(project_file, commented_project)
                    Pkg.activate(dir)
                    Pkg.add("Example")
                    str = read(project_file, String)
                    @test occursin("# `Example` is used for fooing bars", str)
                    @test occursin("# This is my package", str)
                    Pkg.rm("Example")
                    str = read(project_file, String)
                    @test !occursin("fooing bars", str)
                    @test !occursin("issue 123", str)
                    @test occursin("# This is my package", str)
                end
            end
        end
    end
end

end # module
