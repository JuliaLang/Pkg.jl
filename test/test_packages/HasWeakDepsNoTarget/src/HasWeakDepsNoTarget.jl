module HasWeakDepsNoTarget

using Example

if Base.@hasdep OffsetArrays
    offsetarrays_loaded = true
else
    offsetarrays_loaded = false
end

end # module
