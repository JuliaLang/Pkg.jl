# **4.** Working with Environments

The following discusses Pkg's interaction with environments. For more on the role environments play in code loading, including the "stack" of environments from which code can be loaded, see [this section in the Julia manual](https://docs.julialang.org/en/v1/manual/code-loading/#Environments-1).

## Creating your own projects

So far we have added packages to the default project at `~/.julia/environments/v1.6`. It is however easy to create other, independent, projects.
This approach has the benefit of allowing you to check-in a Project.toml (and even a Manifest.toml if you wish) into version control (e.g. git)
to ensure that the code you're version controlling also has a reproducible environment.
It should be pointed out that when two projects use the same package at the same version, the content of this package is not duplicated.
In order to create a new project, create a directory for it and then activate that directory to make it the "active project", which package operations manipulate:

```julia-repl
julia> mkdir("MyProject")

julia> cd("MyProject")
/Users/kristoffer/MyProject

# we can now use "." instead of a longer relative or full path:
(@v1.6) pkg> activate .
Activating new environment at `/Users/kristoffer/MyProject/Project.toml`

(MyProject) pkg> st
    Status `/Users/kristoffer/MyProject/Project.toml` (empty project)
```

Note that the REPL prompt changed when the new project is activated. Since this is a newly created project, the status command shows that it contains no packages, and in fact, it has no project or manifest file until we add a package to it:

```julia-repl
julia> readdir()
String[]

(MyProject) pkg> add Example
  Installing known registries into `~/.julia`
       Added registry `General` to `~/.julia/registries/General`
   Resolving package versions...
   Installed Example ─ v0.5.3
    Updating `/Users/kristoffer/MyProject/Project.toml`
  [7876af07] + Example v0.5.3
    Updating `~/Users/kristoffer/MyProject/Manifest.toml`
  [7876af07] + Example v0.5.3
Precompiling project...
  1 dependency successfully precompiled in 2 seconds

julia> readdir()
2-element Vector{String}:
 "Manifest.toml"
 "Project.toml"

julia> print(read("Project.toml", String))
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"

julia> print(read("Manifest.toml", String))
# This file is machine-generated - editing it directly is not advised

[[Example]]
git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.3"
```

This new environment is completely separate from the one we used earlier. See [`Project.toml` and `Manifest.toml`](@ref Project-and-Manifest) for a more detailed explanation.

## Project Precompilation

Before a package can be imported, Julia will "precompile" the source code into an intermediate more efficient cache on disc.
This precompilation can be triggered via code loading if the un-imported package is new or has changed since the last cache

```julia-repl
julia> using Example
[ Info: Precompiling Example [7876af07-990d-54b4-ab0e-23690620f79a]
```

or using Pkg's precompile option, which can precompile the entire project, or a given dependency, and do so in parallel,
which can be significantly faster than the code-load route above.

```julia-repl
(@v1.6) pkg> precompile
Precompiling project...
  23 dependencies successfully precompiled in 36 seconds
```

However, neither of these should be required routinely due to Pkg's automatic precompilation.

### Automatic Precompilation

By default, any package that is added to a project or updated in a Pkg action will be automatically precompiled, along
with its dependencies.

```julia-repl
(@v1.6) pkg> add Images
   Resolving package versions...
    Updating `~/.julia/environments/v1.9/Project.toml`
  [916415d5] + Images v0.25.2
    Updating `~/.julia/environments/v1.9/Manifest.toml`
    ...
Precompiling project...
  Progress [===================>                     ]  45/97
  ✓ NaNMath
  ✓ IntervalSets
  ◐ CoordinateTransformations
  ◑ ArnoldiMethod
  ◑ IntegralArrays
  ◒ RegionTrees
  ◐ ChangesOfVariables
  ◓ PaddedViews
```

The exception is the `develop` command, which neither builds nor precompiles the package. When
that happens is left up to the user to decide.

If a given package version errors during auto-precompilation, Pkg will remember for the following times it
automatically tries, and will skip that package with a brief warning. Manual precompilation can be used to
force these packages to be retried, as `pkg> precompile` will always retry all packages.

To disable the auto-precompilation, set `ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0`.

### Precompiling new versions of loaded packages

If a package that has been updated is already loaded in the session, the precompilation process will go ahead and precompile
the new version, and any packages that depend on it, but will note that the package cannot be used until session restart.

## Using someone else's project

Simply clone their project using e.g. `git clone`, `cd` to the project directory and call

```julia-repl
shell> git clone https://github.com/JuliaLang/Example.jl.git
Cloning into 'Example.jl'...
...

(@v1.6) pkg> activate Example.jl
Activating project at `~/Example.jl`

(Example) pkg> instantiate
  No Changes to `~/Example.jl/Project.toml`
  No Changes to `~/Example.jl/Manifest.toml`
```

If the project contains a manifest, this will install the packages in the same state that is given by that manifest.
Otherwise, it will resolve the latest versions of the dependencies compatible with the project.

Note that `activate` by itself does not install missing dependencies.
If you only have a `Project.toml`, a `Manifest.toml` must be generated by "resolving" the environment, then any missing packages must be installed and precompiled. `instantiate` does all this for you.

If you already have a resolved `Manifest.toml`, then you will still need to ensure that the packages are installed and with the correct versions. Again `instantiate` does this for you.

In short, `instantiate` is your friend to make sure an environment is ready to use. If there's nothing to do, `instantiate` does nothing.

!!! note "Specifying project on startup"
    Instead of using `activate` from within Julia you can specify the project on startup using
    the `--project=<path>` flag. For example, to run a script from the command line using the
    environment in the current directory you can run
    ```bash
    $ julia --project=. myscript.jl
    ```


## Temporary environments

Temporary environments make it easy to start an environment from a blank slate to test a package or set of
packages, and have Pkg automatically delete the environment when you're done.
For instance, when writing a bug report, you may want to test your minimal reproducible
example in a 'clean' environment to ensure it's actually reproducible as written. You might
also want a scratch space to try out a new package, or a sandbox to resolve version conflicts
between several incompatible packages.

```julia-repl
(@v1.6) pkg> activate --temp # requires Julia 1.5 or later
  Activating new environment at `/var/folders/34/km3mmt5930gc4pzq1d08jvjw0000gn/T/jl_a31egx/Project.toml`

(jl_a31egx) pkg> add Example
    Updating registry at `~/.julia/registries/General`
   Resolving package versions...
    Updating `/private/var/folders/34/km3mmt5930gc4pzq1d08jvjw0000gn/T/jl_a31egx/Project.toml`
  [7876af07] + Example v0.5.3
    Updating `/private/var/folders/34/km3mmt5930gc4pzq1d08jvjw0000gn/T/jl_a31egx/Manifest.toml`
  [7876af07] + Example v0.5.3
```
