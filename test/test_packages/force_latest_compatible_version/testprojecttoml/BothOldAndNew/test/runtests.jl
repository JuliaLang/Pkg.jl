import BothOldAndNew
import ScientificTypes
import Test

Test.@testset "BothOldAndNew.jl" begin
    Test.@test BothOldAndNew.f(1) == 2
end
