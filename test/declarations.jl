module DeclTests

using Pkg
import Pkg.Types.CommandError
using Test
include("utils.jl")

@testset "`parse_option` unit tests" begin
    opt = Pkg.REPLMode.parse_option("-x")
    @test opt.val == "x"
    @test opt.argument === nothing
    opt = Pkg.REPLMode.parse_option("--hello")
    @test opt.val == "hello"
    @test opt.argument === nothing
    opt = Pkg.REPLMode.parse_option("--env=some")
    @test opt.val == "env"
    @test opt.argument == "some"
end

@testset "option class error paths" begin
    # command options
    @test_throws CommandError Pkg.REPLMode.parse("--project add Example")
    # meta options
    #TODO @test_throws CommandError Pkg.REPLMode.parse("add --env=foobar Example")
end

@testset "`parse` integration tests" begin
    @test isempty(Pkg.REPLMode.parse(""))

    statement = Pkg.REPLMode.parse("up")[1]
    @test statement.command == "up"
    @test isempty(statement.meta_options)
    @test isempty(statement.options)
    @test isempty(statement.arguments)

    statement = Pkg.REPLMode.parse("dev Example")[1]
    @test statement.command == "dev"
    @test isempty(statement.meta_options)
    @test isempty(statement.options)
    @test statement.arguments == ["Example"]

    statement = Pkg.REPLMode.parse("dev Example#foo #bar")[1]
    @test statement.command == "dev"
    @test isempty(statement.meta_options)
    @test isempty(statement.options)
    @test statement.arguments == ["Example", "#foo", "#bar"]

    statement = Pkg.REPLMode.parse("dev Example#foo Example@v0.0.1")[1]
    @test statement.command == "dev"
    @test isempty(statement.meta_options)
    @test isempty(statement.options)
    @test statement.arguments == ["Example", "#foo", "Example", "@v0.0.1"]

    statement = Pkg.REPLMode.parse("--one -t add --first --second arg1")[1]
    @test statement.command == "add"
    @test statement.meta_options == ["--one", "-t"]
    @test statement.options == ["--first", "--second"]
    @test statement.arguments == ["arg1"]

    statements = Pkg.REPLMode.parse("--one -t add --first -o arg1; --meta pin -x -a arg0 Example")
    @test statements[1].command == "add"
    @test statements[1].meta_options == ["--one", "-t"]
    @test statements[1].options == ["--first", "-o"]
    @test statements[1].arguments == ["arg1"]
    @test statements[2].command == "pin"
    @test statements[2].meta_options == ["--meta"]
    @test statements[2].options == ["-x", "-a"]
    @test statements[2].arguments == ["arg0", "Example"]

    statements = Pkg.REPLMode.parse("up; --meta -x pin --first; dev")
    @test statements[1].command == "up"
    @test isempty(statements[1].meta_options)
    @test isempty(statements[1].options)
    @test isempty(statements[1].arguments)
    @test statements[2].command == "pin"
    @test statements[2].meta_options == ["--meta", "-x"]
    @test statements[2].options == ["--first"]
    @test isempty(statements[2].arguments)
    @test statements[3].command == "dev"
    @test isempty(statements[3].meta_options)
    @test isempty(statements[3].options)
    @test isempty(statements[3].arguments)
end

@testset "argument count" begin
    with_temp_env() do
        @test_throws CommandError Pkg.REPLMode.pkgstr("activate one two")
        @test_throws CommandError Pkg.REPLMode.pkgstr("activate one two three")
        @test_throws CommandError Pkg.REPLMode.pkgstr("precompile Example")
    end
end

@testset "invalid options" begin
    with_temp_env() do
        @test_throws CommandError Pkg.REPLMode.pkgstr("rm --minor Example")
        @test_throws CommandError Pkg.REPLMode.pkgstr("pin --project Example")
    end
end

@testset "Argument order" begin
    with_temp_env() do
        @test_throws CommandError Pkg.REPLMode.pkgstr("add FooBar Example#foobar#foobar")
        @test_throws CommandError Pkg.REPLMode.pkgstr("up Example#foobar@0.0.0")
        @test_throws CommandError Pkg.REPLMode.pkgstr("pin Example@0.0.0@0.0.1")
        @test_throws CommandError Pkg.REPLMode.pkgstr("up #foobar")
        @test_throws CommandError Pkg.REPLMode.pkgstr("add @0.0.1")
    end
end

@testset "gc" begin
    with_temp_env() do
        @test_throws CommandError Pkg.REPLMode.pkgstr("gc --project")
        @test_throws CommandError Pkg.REPLMode.pkgstr("gc --minor")
        @test_throws CommandError Pkg.REPLMode.pkgstr("gc Example")
        Pkg.REPLMode.pkgstr("gc")
    end
end

@testset "precompile" begin
    with_temp_env() do
        @test_throws CommandError Pkg.REPLMode.pkgstr("precompile --project")
        @test_throws CommandError Pkg.REPLMode.pkgstr("precompile Example")
        Pkg.REPLMode.pkgstr("precompile")
    end
end

@testset "generate" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws CommandError Pkg.REPLMode.pkgstr("generate --major Example")
        @test_throws CommandError Pkg.REPLMode.pkgstr("generate --foobar Example")
        @test_throws CommandError Pkg.REPLMode.pkgstr("generate Example1 Example2")
        Pkg.REPLMode.pkgstr("generate Example")
    end
    end
    end
end

@testset "test" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        Pkg.add("Example")
        @test_throws CommandError Pkg.REPLMode.pkgstr("test --project Example")
        Pkg.REPLMode.pkgstr("test --coverage Example")
        Pkg.REPLMode.pkgstr("test Example")
    end
    end
    end
end

@testset "build" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws CommandError Pkg.REPLMode.pkgstr("build --project")
        @test_throws CommandError Pkg.REPLMode.pkgstr("build --minor")
    end
    end
    end
end

@testset "free" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        @test_throws CommandError Pkg.REPLMode.pkgstr("free --project")
        @test_throws CommandError Pkg.REPLMode.pkgstr("free --major")
    end
    end
    end
end

@testset "conflicting options" begin
    @test_throws CommandError Pkg.REPLMode.pkgstr("up --major --minor")
    @test_throws CommandError Pkg.REPLMode.pkgstr("rm --project --manifest")
end

end # module
