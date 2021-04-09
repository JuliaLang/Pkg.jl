import NewOnly
import ScientificTypes
import Test

Test.@testset "NewOnly.jl" begin
    Test.@test NewOnly.f(1) == 2
end
