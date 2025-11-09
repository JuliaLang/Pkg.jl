module HasDepWithExtensions

using HasExtensions
using OffsetArrays: OffsetArray
# Loading OffsetArrays makes the extesion "OffsetArraysExt" load

using IndirectArrays: IndirectArray
# Loading IndirectArrays makes the extesion "IndirectArraysExt" load

function do_something()
    # @info "First do something with the basic array support"
    HasExtensions.foo(rand(Float64, 2)) == 1 || error("Unexpected value")

    # @info "Now do something with extended OffsetArray support"
    HasExtensions.foo(OffsetArray(rand(Float64, 2), 0:1)) == 2 || error("Unexpected value")

    # @info "Now do something with extended IndirectArray support"
    return HasExtensions.foo(IndirectArray(rand(1:6, 32, 32), 1:6)) == 3 || error("Unexpected value")
end

function dummy_function_for_coverage end

function __init__()
    @eval dummy_function_for_coverage() = Base.donotdelete("Dummy")
    Base.invokelatest(dummy_function_for_coverage)
end

end # module
