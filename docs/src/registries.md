# **8.** Registries

Registries contain information about packages, such as
available releases and dependencies, and where they can be downloaded.
The [`General` registry](https://github.com/JuliaRegistries/General)
is the default one, and is installed automatically if there are no
other registries installed.

## Managing registries

Registries can be added, removed and updated from either the Pkg REPL
or by using the functional API. In this section we will describe the
REPL interface. The registry API is documented in
the [Registry API Reference](@ref) section.

### Adding registries

A custom registry can be added with the `registry add` command
from the Pkg REPL. Usually this will be done with a URL to the
registry.

If a custom registry has been installed causing the `General` registry
to not be automatically installed, it is easy to add it manually:


```julia-repl
pkg> registry add General
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

!!! note "Registries from a package server"

    It is possible for a package server to be advertising additional available package
    registries. When Pkg runs with a clean Julia depot (e.g. after a fresh install), with
    a custom package server configured with `JULIA_PKG_SERVER`, it will automatically
    add all such available registries. If the depot already has some registries installed
    (e.g. General), the additional ones can easily be installed with the no-argument
    `registry add` command.

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

Registries automatically update once per session when a package operation is performed so it
rarely has to be done manually.

## Registry format

In a registry, each package gets its own directory; in that directory
are the following files: `Compat.toml`, `Deps.toml`, `Package.toml`,
and `Versions.toml`.
The formats of these files are described below.

### Registry Compat.toml

The `Compat.toml` file has a series of blocks specifying version
numbers, with a set of dependencies listed below. For example,
part of such a file might look like this:

```toml
["0.8-0.8.3"]
DependencyA = "0.4-0.5"
DependencyB = "0.3-0.5"

["0.8.2-0.8.5"]
DependencyC = "0.7-0"
```

Dependencies that are unchanged across a range of versions are grouped
together in these blocks. The interpretation of these ranges is given by the comment after each line below:

```toml
"0.7-0.8"  # [0.7.0, 0.9.0)
"0.7-0"    # [0.7.0, 1.0.0)
"0.8.6-0"  # [0.8.6, 1.0.0)
"0.7-*"    # [0.7.0, ∞)
```

So for this package, versions `[0.8.0, 0.8.3]` depend on versions `[0.4.0, 0.6.0)` of `DependencyA` and version `[0.3.0, 0.6.0)` of `DependencyB`.
Meanwhile, it is also true that versions `[0.8.2, 0.8.5]` require specific versions of `DependencyC` (so that all three are required for versions `0.8.2` and `0.8.3`).

### Registry flavors

The default Pkg Server (`pkg.julialang.org`) offers two different "flavors" of registry.

!!! compat "Julia 1.8"
    Registry flavors are only available starting with Julia 1.8.

- `conservative`: suitable for most users; all packages and artifacts in this registry flavor are available from the Pkg Server, with no need to download from other sources
- `eager`: this registry offers the latest versions of packages, even if the Pkg and Storage Servers have not finished processing them; thus, some packages and artifacts may not be available from the Pkg Server, and thus may need to be downloaded from other sources (such as GitHub)

The default registry flavor is `conservative`. We recommend that most users stick to the `conservative` flavor unless they know that they need to use the `eager` flavor.

To select the `eager` flavor:

```julia
ENV["JULIA_PKG_SERVER_REGISTRY_PREFERENCE"] = "eager"

import Pkg

Pkg.Registry.update()
```

To select the `conservative` flavor:

```julia
ENV["JULIA_PKG_SERVER_REGISTRY_PREFERENCE"] = "conservative"

import Pkg

Pkg.Registry.update()
```

### Creating and maintaining registries

Pkg only provides client facilities for registries, rather than functionality to create
or maintain them. However, [Registrator.jl](https://github.com/JuliaRegistries/Registrator.jl)
and [LocalRegistry.jl](https://github.com/GunnarFarneback/LocalRegistry.jl) provide ways to
create and update registries, and [RegistryCI.jl](https://github.com/JuliaRegistries/RegistryCI.jl)
provides automated testing and merging functionality for maintaining a registry.
