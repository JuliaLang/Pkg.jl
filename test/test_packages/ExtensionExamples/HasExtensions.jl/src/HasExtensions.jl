module HasExtensions

using Example

function foo(::AbstractArray)
    return 1
end

indirectarrays_loaded = false
offsetarrays_loaded = false

end # module
