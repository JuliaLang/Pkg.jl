using HasExtensions
using Test

@test !HasExtensions.offsetarrays_loaded

using OffsetArrays

@test HasExtensions.offsetarrays_loaded
