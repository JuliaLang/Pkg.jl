using HasExtensions
using Test

@test !HasExtensions.offsetarrays_loaded
@test HasExtensions.foo(rand(Float64, 2)) == 1

using OffsetArrays

@test HasExtensions.offsetarrays_loaded
@test HasExtensions.foo(OffsetArray(rand(Float64, 2), 0:1)) == 2

using IndirectArrays

@test HasExtensions.indirectarrays_loaded
@test HasExtensions.foo(IndirectArray(rand(1:6, 32, 32), 1:6)) == 3
