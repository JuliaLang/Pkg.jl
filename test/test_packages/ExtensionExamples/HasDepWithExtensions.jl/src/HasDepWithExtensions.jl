module HasDepWithExtensions

using HasExtensions
using OffsetArrays: OffsetArray
# Loading OffsetArrays makes the extesion "OffsetArraysExt" to load

function do_something()
    # @info "First do something with the basic array support in B"
    HasExtensions.foo(rand(Float64, 2))

    # @info "Now do something with extended OffsetArray support in B"
    HasExtensions.foo(OffsetArray(rand(Float64, 2), 0:1))
end

end # module
