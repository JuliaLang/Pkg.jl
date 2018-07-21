module DeclTests

using Pkg
import Pkg.Types.CommandError
using Test
include("utils.jl")

@testset "`parse_option` error paths" begin
    # unregistered options
    @test_throws CommandError Pkg.REPLMode.parse_option("-x")
    @test_throws CommandError Pkg.REPLMode.parse_option("--notanoption")
    # argument options
    @test_throws CommandError Pkg.REPLMode.parse_option("--env")
    # switch options
    @test_throws CommandError Pkg.REPLMode.parse_option("--project=foobar")
end

@testset "option class error paths" begin
    # command options
    @test_throws CommandError Pkg.REPLMode.parse("--project add Example")
    # meta options
    #TODO @test_throws CommandError Pkg.REPLMode.parse("add --env=foobar Example")
end

@testset "`parse` unit tests" begin
    statement = Pkg.REPLMode.parse("--env=foobar add Example")[1]
    @test statement.command == "add"
    @test statement.meta_options[1].spec.name == "env"
    @test statement.meta_options[1].argument == "foobar"

    statements = Pkg.REPLMode.parse("--env=foobar add Example; rm Example")
    @test statements[1].command == "add"
    @test statements[2].command == "rm"

    statement = Pkg.REPLMode.parse("--env=foobar add --project Example1 Example2")[1]
    @test statement.command == "add"
    @test statement.arguments[1] == "Example1"
    @test statement.arguments[2] == "Example2"
    @test length(statement.arguments) == 2
    @test statement.options[1].val == "project"
    @test length(statement.options) == 1

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

end # module
