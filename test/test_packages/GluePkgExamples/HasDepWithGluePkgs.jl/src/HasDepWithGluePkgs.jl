module HasDepWithGluePkgs

using HasGluePkgs
using OffsetArrays: OffsetArray
# Loading OffsetArrays makes the glue module "GlueOffsetArrays" to load

function do_something()
    # @info "First do something with the basic array support in B"
    HasGluePkgs.foo(rand(Float64, 2))

    # @info "Now do something with extended OffsetArray support in B"
    HasGluePkgs.foo(OffsetArray(rand(Float64, 2), 0:1))
end

end # module
