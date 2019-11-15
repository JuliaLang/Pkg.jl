# **7.** Registries

Registries contain information about packages, such as
available releases and dependencies, and where they can be downloaded.
The `General` registry (https://github.com/JuliaRegistries/General)
is the default one, and is installed automatically.

## Managing registries

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

Registries can be added, removed and updated from either the Pkg REPL
or by using the function based API. In this section we will describe the
REPL interface. The registry API is documented in
the [Registry API Reference](@ref) section.

### Adding registries

A custom registry can be added with the `registry add` command
from the Pkg REPL. Usually this will be done with a URL to the
registry. Here we add the `General` registry:

```julia-repl
pkg> registry add https://github.com/JuliaRegistries/General
   Cloning registry from "https://github.com/JuliaRegistries/General"
     Added registry `General` to `~/.julia/registries/General`
```

and now all the packages registered in `General` are available for e.g. adding.
To see which registries are currently installed you can use the `registry status`
(or `registry st`) command

```julia-repl
pkg> registry st
Registry Status
 [23338594] General (https://github.com/JuliaRegistries/General.git)
```

Registries are always added to the user depot, which is the first entry in `DEPOT_PATH` (cf. the [Glossary](@ref) section).

### Removing registries

Registries can be removed with the `registry remove` (or `registry rm`) command.
Here we remove the `General` registry

```julia-repl
pkg> registry rm General
  Removing registry `General` from ~/.julia/registries/General

pkg> registry st
Registry Status
  (no registries found)
```

In case there are multiple registries named `General` installed you have to
disambiguate with the `uuid`, just as when manipulating packages, e.g.

```julia-repl
pkg> registry rm General=23338594-aafe-5451-b93e-139f81909106
  Removing registry `General` from ~/.julia/registries/General
```

### Updating registries

The `registry update` (or `registry up`) command is available to update registries.
Here we update the `General` registry:

```julia-repl
pkg> registry up General
  Updating registry at `~/.julia/registries/General`
  Updating git-repo `https://github.com/JuliaRegistries/General`
```

and to update all installed registries just do:

```julia-repl
pkg> registry up
  Updating registry at `~/.julia/registries/General`
  Updating git-repo `https://github.com/JuliaRegistries/General`
```
