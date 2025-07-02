module CLI

using ..Rot13: rot13

function (@main)(ARGS)
    if length(ARGS) == 0
        println("Usage: rot13cli <text>")
        return 1
    end
    
    for arg in ARGS
        # Add a prefix to distinguish from main module output
        println("CLI: $(rot13(arg))")
    end
    return 0
end

end # module CLI