module OffsetArraysExt

using HasExtensions, OffsetArrays
import HasExtensions: foo

function foo(::OffsetArray)
    return 2
end

function dummy_function_for_coverage end

function __init__()
    @eval dummy_function_for_coverage() = Base.donotdelete("Dummy")
    Base.invokelatest(dummy_function_for_coverage)
    return HasExtensions.offsetarrays_loaded = true
end

end
