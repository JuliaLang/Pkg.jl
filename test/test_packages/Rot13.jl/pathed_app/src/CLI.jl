module CLI

function @main(args)
    for arg in args
        println("PathedCLI: $(reverse(arg))")  # Different prefix from main Rot13
    end
end

end