module IndirectArraysExt

using HasExtensions, IndirectArrays
import HasExtensions: foo

function foo(::IndirectArray)
    return 3
end

function __init__()
    return HasExtensions.indirectarrays_loaded = true
end

end
