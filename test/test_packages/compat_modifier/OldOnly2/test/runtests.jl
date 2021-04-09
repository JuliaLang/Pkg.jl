import OldOnly2
import ScientificTypes
import Test

Test.@testset "OldOnly2.jl" begin
    Test.@test OldOnly2.f(1) == 2
end
