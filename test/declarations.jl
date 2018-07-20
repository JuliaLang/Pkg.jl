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
end

end # module
