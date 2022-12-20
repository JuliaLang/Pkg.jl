using HasExtensions
using Test

@test !HasExtensions.offsetarrays_loaded
@test foo(Int[1,2,3]) == 1

using OffsetArrays

@test HasExtensions.offsetarrays_loaded
@test foo(OffsetArray(Int[1,2,3], -1:1)) == 2
