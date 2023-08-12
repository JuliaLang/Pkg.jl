module OffsetArraysExt

using HasExtensions, OffsetArrays
import HasExtensions: foo

function foo(::OffsetArray)
    return 2
end

function __init__()
    HasExtensions.offsetarrays_loaded = true
end

end
