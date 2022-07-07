module GlueOffsetArrays

using HasGluePkgs, OffsetArrays

function foo(::OffsetArray)
    return 2
end

function __init__()
    HasGluePkgs.offsetarrays_loaded = true
end

end
