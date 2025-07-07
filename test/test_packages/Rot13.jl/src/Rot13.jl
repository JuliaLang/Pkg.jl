module Rot13

function rot13(c::Char)
    shft = islowercase(c) ? 'a' : 'A'
    isletter(c) ? c = shft + (c - shft + 13) % 26 : c
end

rot13(str::AbstractString) = map(rot13, str)

function (@main)(ARGS)
    for arg in ARGS
        println(rot13(arg))
    end
    return 0
end

include("CLI.jl")

end # module Rot13
