using HasWeakDepsNoTarget
using Test

# OffsetArrays is *not* in the test target and should therefore be available.
@test !HasWeakDepsNoTarget.offsetarrays_loaded
