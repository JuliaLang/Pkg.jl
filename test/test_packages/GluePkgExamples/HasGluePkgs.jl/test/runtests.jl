using HasGluePkgs
using Test

@test !HasGluePkgs.offsetarrays_loaded

using OffsetArrays

@test HasGluePkgs.offsetarrays_loaded
