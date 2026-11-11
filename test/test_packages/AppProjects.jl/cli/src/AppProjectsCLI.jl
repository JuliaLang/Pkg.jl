module AppProjectsCLI

using AppProjects, Dates

function (@main)(ARGS)
    println("CLI: ", AppProjects.greeting(join(ARGS, " ")), " ", Dates.monthname(1))
    return 0
end

end # module
