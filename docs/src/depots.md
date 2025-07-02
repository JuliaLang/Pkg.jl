# **###.** Depots, where package-code is stored on a computer

The packages installed for a particular environment, defined in the
files `Project.toml` and `Manifest.toml` within the directory
structure, are not actually installed within that directory but into a
"depot". The location of the depots are set by the variable
`DEPOT_PATH`, which has by default the following entries:
1. `~/.julia` where `~` is the user home as appropriate on the system`
2. an architecture-specific shared system directory, e.g. `/usr/local/share/julia`
3. an architecture-independent shared system directory, e.g. `/usr/share/julia`

Packages which are installed by a user go into 1 and the Julia
standard library is in 3.

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
occurring there and set a new environment at the same location
```julia-repl
julia> deleteat!(DEPOT_PATH, [1])

julia> env_path = "$(DEPOT_PATH[1])/environments/v$(VERSION.major).$(VERSION.minor)"

julia> using Pkg; Pkg.activate(env_path);

julia> Pkg.add("YourFavoritePackage"); Pkg.precompile()
```
Notes:
- that this setup mirrors the layout used in the "standard" depot
  `./julia`.  However, another setup can be chosen with different depot
  and environment paths.
- depending on the write permissions on the system, above may
- the precompile will be picked up by the system users (unless it
  isn't)

To make this environment available to the system users, it has to be
added to the `LOAD_PATH`.
```julia-repl

```
Note that the `DEPOT_PATH` is already set, as we installed into
`DEPOT_PATH[2]`.  This can be done by launching Julia
```
$ JULIA_LOAD_PATH="@":"@v#.#":/usr/local/share/julia/environments/v1.5:"@stdlib" julia
```
where `/usr/local/share/julia/environments/v1.5` has to adjusted
accordingly.  The environment variable `JULIA_LOAD_PATH` will need to
be set for all users, query the internet for a suitable method.
Once that is done, all users will have access to the system-wide
installed package(s).

Regarding the motivating example: don't forget to copy the
Julia-kernel created by IJulia to a place where the JupyterHub install
can pick it up.
