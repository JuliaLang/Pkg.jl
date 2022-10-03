using HasWeakDeps
using Test

# OffsetArrays is in the test target and should therefore be available.
@test HasWeakDeps.offsetarrays_loaded
