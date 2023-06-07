using HasExtensions
using Test

@test !HasExtensions.offsetarrays_loaded
@test HasExtensions.foo(rand(Float64, 2)) == 1

using OffsetArrays

@test HasExtensions.offsetarrays_loaded
@test HasExtensions.foo(OffsetArray(rand(Float64, 2), 0:1)) == 2
