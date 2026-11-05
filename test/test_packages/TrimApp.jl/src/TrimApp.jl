module TrimApp

# Only uses `Core` IO so that it can be compiled with `--trim=safe`
function (@main)(args::Vector{String})
    Core.println(Core.stdout, isempty(args) ? "trimapp" : "trimapp " * args[1])
    return 0
end

end # module
