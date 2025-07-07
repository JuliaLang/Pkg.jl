using Test
using AllowReresolveTest

@testset "AllowReresolveTest.jl" begin
    @test AllowReresolveTest.greet() == "Hello from AllowReresolveTest using Example!"
end
