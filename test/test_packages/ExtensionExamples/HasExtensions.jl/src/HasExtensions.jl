module HasExtensions

using Example

function foo(::AbstractArray)
    return 1
end

indirectarrays_loaded = false
offsetarrays_loaded = false

function dummy_function_for_coverage end

function __init__()
    @eval dummy_function_for_coverage() = Base.donotdelete("Dummy")
    Base.invokelatest(dummy_function_for_coverage)
end

end # module
