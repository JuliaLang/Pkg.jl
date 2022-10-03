# Weak dependencies

It is sometimes desirable to be able to extend some functionality of a package without having to
unconditionally take on the cost (in terms of e.g. load time) of adding an extra dependency.
A *weak* dependency is a package that is only available to load if some other package in the
current environment has that package as a normal (or strong) dependency.

Weak dependencies are listed in a `Project.toml` file under the `[weakdeps]` section which can be compared to a
(strong) dependency which is under the `[deps]` section.
Compatibility on weak dependencies is specified like a normal dependency in the `[compat]` section.

A useful application of weak dependencies could be for a plotting package that should be able to plot
objects from different Julia packages. Adding all those different Julia packages as dependencies
could be expensive. Instead, these packages are added as weak dependencies so that they are available only
if there is a chance that someone might call the function with such a type.

Below is an example of how the code can be structured for a use case as outlined above.

`Project.toml`:
```toml
name = "Plotting"
version = "0.1.0"
uuid = "..."

[deps] # strong dependencies
Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"

[weakdeps]
Contour = "d38c429a-6771-53c6-b99e-75d170b6e991"

[compat] # compat can also be given on weak dependencies
Colors = "0.12.8"
Contour = "0.6.2"
```

`src/Plotting.jl`:
```julia
module Plotting

using Colors

if Base.@hasdep Contour
    using Contour
    function plot(c::Contour.ContourCollection
         ...
    end
end

end # module
```

## Compatibility with older Julia versions.

It is possible to have a dependency be a weak version in Julia versions that support it and be a strong dependency in earlier
Julia versions. This is done by having the dependency as *both* a strong and weak dependency. Older Julia versions will ignore
the specification of the dependency as weak while new Julia versions will tag it as a weak dependency.

The above code would then look like this:

```julia
module Plotting

using Colors

if !isdefined(Base, :hasdep) || Base.hasdep(@__MODULE__, :Contour)
    using Contour
    function plot(c::Contour.ContourCollection
         ...
    end
end

end # module
```

where the "conditional code" is executed unconditionally on old Julia versions and based on the presence of the weak
dependency on the new Julia version. Here the functional form of `@hasdep` was used which requires a module as the first
argument.
