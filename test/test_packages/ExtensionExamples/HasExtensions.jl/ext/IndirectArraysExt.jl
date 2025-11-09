module IndirectArraysExt

using HasExtensions, IndirectArrays
import HasExtensions: foo

function foo(::IndirectArray)
    return 3
end

function dummy_function_for_coverage end

function __init__()
    @eval dummy_function_for_coverage() = Base.donotdelete("Dummy")
    Base.invokelatest(dummy_function_for_coverage)
    return HasExtensions.indirectarrays_loaded = true
end

end
