# [**8.** Preferences](@id Preferences)

!!! compat "Julia 1.6"
    Pkg's preferences API requires at least Julia 1.6.

`Pkg` Preferences support embedding a simple `Dict` of metadata for a package on a per-project or per-depot basis.  These preferences allow for packages to set simple, persistent pieces of data that the user has selected, that can persist across multiple versions of a package.

## API Overview

Usage is performed primarily through the `@load_preferences`, `@save_preferences` and `@modify_preferences` macros.  These macros will auto-detect the UUID of the calling package, (throwing an error if the calling module does not belong to a package) the function forms can be used to load, save or modify preferences belonging to another package.

Example usage:

```julia
using Pkg.Preferences

function get_preferred_backend()
    prefs = @load_preferences()
    return get(prefs, "backend", "native")
end

function set_backend(new_backend)
    @modify_preferences!() do prefs
        prefs["backend"] = new_backend
    end
end
```

By default, preferences are stored within the `Project.toml` file of the currently-active project, and as such all new projects will start from a blank state, with all preferences being un-set.
Package authors that wish to have a default value set for their preferences should use the `get(prefs, key, default)` pattern as shown in the code example above.
If a system administrator wishes to provide a default value for new environments on a machine, they may create a depot-wide default value by saving preferences for a particular UUID targeting a particular depot:

```julia
using Pkg.Preferences, Foo
# We want Foo to default to a certain library on this machine,
# save that as a depot-wide preference to our `~/.julia` depot
foo_uuid = Preferences.get_uuid_throw(Foo)
prefs = Dict("libfoo_vendor" => "setec_astronomy")

save_preferences(pkg_uuid, prefs; depot=Pkg.depots1())
```

Depot-wide preferences are overridden by preferences stored wtihin `Project.toml` files, and all preferences (including those inherited from depot-wide preferences) are stored concretely within `Project.toml` files.
This means that depot-wide preferences will serve to provide default values for new projects/environments, but once a project has
saved its preferences at all, they are effectively decoupled.
This is an intentional design choice to maximize reproducibility and to continue to support the `Project.toml` as an independent archive.

For a full listing of docstrings and methods, see the [Preferences Reference](@ref) section.