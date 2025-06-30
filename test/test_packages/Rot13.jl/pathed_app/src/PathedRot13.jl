module PathedRot13

function @main(args)
    for arg in args
        println(reverse(arg))  # Different from Rot13 - just reverse the string
    end
end

include("CLI.jl")

end