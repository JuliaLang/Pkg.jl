@show Base.GLUE_PKG_DORMITORY


using HasGluePkgs
using Test

@show Base.GLUE_PKG_DORMITORY
@test !HasGluePkgs.offsetarrays_loaded


using OffsetArrays

@show Base.GLUE_PKG_DORMITORY

@test HasGluePkgs.offsetarrays_loaded
