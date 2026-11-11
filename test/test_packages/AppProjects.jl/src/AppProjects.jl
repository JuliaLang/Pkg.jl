module AppProjects

greeting(name) = "Hello, $(name)!"

function (@main)(ARGS)
    println(greeting(join(ARGS, " ")))
    return 0
end

end # module
