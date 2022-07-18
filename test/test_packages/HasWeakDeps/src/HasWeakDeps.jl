module HasWeakDeps

using Example

function foo(x::AbstractArray)
    @info "HasWeakDeps.jl: A custom logging method for AbstractArray" x
end

if Base.@hasdep OffsetArrays
    using OffsetArrays
    println("Loading custom OffsetArrays code...")
    offsetarrays_loaded = true
    function foo(x::OffsetArray)
        @info "HasWeakDeps.jl: A custom logging method for OffsetArray" x
    end
else
    println("OffsetArrays not installed")
    offsetarrays_loaded = false
end

end # module
