import DirectDepWithoutCompatEntry
import ScientificTypes
import Test

Test.@testset "DirectDepWithoutCompatEntry.jl" begin
    Test.@test DirectDepWithoutCompatEntry.f(1) == 2
end
