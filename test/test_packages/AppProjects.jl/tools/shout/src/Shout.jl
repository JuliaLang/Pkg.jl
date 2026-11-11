module Shout

module Loud

    using AppProjects, Unicode

    function (@main)(ARGS)
        println(Unicode.uppercase(AppProjects.greeting(join(ARGS, " "))))
        return 0
    end

end # module Loud

end # module
