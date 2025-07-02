module IndirectArraysExt

using HasExtensions, IndirectArrays
import HasExtensions: foo

function foo(::IndirectArray)
    return 3
end

function __init__()
    HasExtensions.indirectarrays_loaded = true
    return
end

end
