using TestFailure
using Test

if haskey(ENV, "TEST_SIGNAL")
    run(`kill -s $(ENV["TEST_SIGNAL"]) $(getpid())`)
elseif haskey(ENV, "TEST_EXITCODE")
    exit(parse(Int, ENV["TEST_EXITCODE"]))
end

@testset "TestFailure" begin
    @test false
end
