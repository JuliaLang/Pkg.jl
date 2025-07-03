# **15.** Depots

The packages installed for a particular environment, defined in the
files `Project.toml` and `Manifest.toml` within the directory
structure, are not actually installed within that directory but into a
"depot". The location of the depots are set by the variable
`DEPOT_PATH`, which has by default the following entries:

1. `~/.julia` where `~` is the user home as appropriate on the system
2. an architecture-specific shared system directory, e.g. `/usr/local/share/julia`
3. an architecture-independent shared system directory, e.g. `/usr/share/julia`

Packages which are installed by a user go into 1 and the Julia
standard library is in 3.

You should not need to manage the user depot directly. Pkg will automatically clean up
the depots when packages are removed after a delay. However you may want to manually
remove old `.julia/compiled/` subdirectories if you have any that reside for older Julia
versions that you no longer use (hence have not been run to tidy themselves up).

## Configuring the depot path with `JULIA_DEPOT_PATH`

The depot path can be configured using the `JULIA_DEPOT_PATH` environment variable.
This environment variable is used to populate the global Julia `DEPOT_PATH` variable
at startup. Unlike the shell `PATH` variable, empty entries in `JULIA_DEPOT_PATH`
have special behavior:

- At the end, an empty entry is expanded to the default depot path, *excluding* the user depot
- At the start, an empty entry is expanded to the default depot path, *including* the user depot

This allows easy overriding of the user depot while retaining access to system resources.
For example, to switch the user depot to `/custom/depot` while still accessing bundled
resources, use a trailing path separator:

```bash
export JULIA_DEPOT_PATH="/custom/depot:"
```

!!! note
    The trailing path separator (`:` on Unix, `;` on Windows) is crucial for including
    the default system depots, which contain the standard library and other bundled
    resources. Without it, Julia will only use the specified depot and will have to precompile
    standard library packages, which can be time-consuming and inefficient.

## Shared depots for distributed computing

When using Julia in distributed computing environments, such as high-performance computing
(HPC) clusters, it's recommended to use a shared depot via `JULIA_DEPOT_PATH`. This allows
multiple Julia processes to share precompiled packages and reduces redundant compilation.

Since Julia v1.10, multiple processes using the same depot coordinate via pidfile locks
to ensure only one process precompiles a package while others wait. However, due to
the caching of native code in pkgimages since v1.9, you may need to set the `JULIA_CPU_TARGET`
environment variable appropriately to ensure cache compatibility across different
worker nodes with varying CPU capabilities.

For more details, see the [FAQ section on distributed computing](https://docs.julialang.org/en/v1/manual/faq/#Computing-cluster)
and the [environment variables documentation](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_CPU_TARGET).

## Example: System-wide package installation on a *nix OS

Usually, most of the packages will be installed by the user into their
own depot.  However, sometimes a system-wide installation of some
packages are desired or necessary.  One example where it is necessary
to install a package system-wide is in a
[JupyterHub](https://github.com/jupyterhub/jupyterhub), where the
[IJulia.jl](https://github.com/jupyterhub/jupyterhub) package needs to
be available as it provides the kernel which JupyterHub needs to run
to provide a Julia notebook.

Here the depot `DEPOT_PATH[2]` is chosen as the install depot, the
corresponding environment is placed in
`DEPOT_PATH[2]/environments/v#.#`, with `v#.#` denoting the version of
Julia.

First remove the standard, user-depot, such that installs are not
occurring there and set a new environment at the same location:

```julia-repl
julia> deleteat!(DEPOT_PATH, [1])

julia> env_path = "$(DEPOT_PATH[1])/environments/v$(VERSION.major).$(VERSION.minor)"

julia> using Pkg; Pkg.activate(env_path);

julia> Pkg.add("YourFavoritePackage")
```

Notes:

- This setup mirrors the layout used in the "standard" depot
  `./julia`. However, another setup can be chosen with different depot
  and environment paths.
- Depending on the write permissions on the system, the above commands may
  require administrator privileges.
- The precompile cache will be available to system users if they have
  read access to the depot.

To make this environment available to the system users, it has to be
added to the `LOAD_PATH`:

```bash
JULIA_LOAD_PATH="@":"@v#.#":/usr/local/share/julia/environments/v1.13:"@stdlib" julia
```

Note that the `DEPOT_PATH` is already set, as we installed into
`DEPOT_PATH[2]`. The path `/usr/local/share/julia/environments/v1.13` should be
adjusted according to your Julia version and chosen depot location.
The environment variable `JULIA_LOAD_PATH` will need to
be set for all users. Once that is done, all users will have access to the system-wide
installed package(s).

Regarding the motivating example: don't forget to copy the
Julia-kernel created by IJulia to a place where the JupyterHub install
can pick it up.
