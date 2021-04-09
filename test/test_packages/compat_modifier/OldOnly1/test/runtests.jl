import OldOnly1
import ScientificTypes
import Test

Test.@testset "OldOnly1.jl" begin
    Test.@test OldOnly1.f(1) == 2
end
