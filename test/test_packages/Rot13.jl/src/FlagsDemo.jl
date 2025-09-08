module FlagsDemo

function (@main)(ARGS)
    println("Julia flags demo!")
    println("Thread count: $(Threads.nthreads())")
    println("Optimization level: $(Base.JLOptions().opt_level)")
    println("Startup file enabled: $(Base.JLOptions().startupfile != 2)")
    println("App arguments: $(join(ARGS, " "))")
    return 0
end

end # module FlagsDemo
