import OldOnly
import ScientificTypes
import Test

Test.@testset "OldOnly.jl" begin
    Test.@test OldOnly.f(1) == 2
end
