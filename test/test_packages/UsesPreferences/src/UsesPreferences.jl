module UsesPreferences
using Pkg.Preferences

# This will get initialized in __init__()
backend = Ref{String}()

function set_backend(new_backend::AbstractString)
    if !(new_backend in ("OpenCL", "CUDA", "jlFPGA"))
        throw(ArgumentError("Invalid backend: \"$(new_backend)\""))
    end

    # Set it in our runtime values, as well as saving it to disk
    backend[] = new_backend
    @modify_preferences!() do prefs
        prefs["backend"] = new_backend
    end
end

function get_backend()
    return backend[]
end

function __init__()
    @modify_preferences!() do prefs
        prefs["initialized"] = "true"

        # If it's never been set before, default it to OpenCL
        prefs["backend"] = get(prefs, "backend", "OpenCL")
        backend[] = prefs["backend"]
    end
end

end # module UsesPreferences