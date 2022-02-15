# **4.** Working with Environments

The following discusses Pkg's interaction with environments. For more on the role environments play in code loading, including the "stack" of environments from which code can be loaded, see [this section in the Julia manual](https://docs.julialang.org/en/v1/manual/code-loading/#Environments-1).

## Creating your own projects

So far we have added packages to the default project at `~/.julia/environments/v1.6`. It is however easy to create other, independent, projects.
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

By default any package that is added to a project or updated in a Pkg action will be automatically precompiled, along
with its dependencies. The exception is the `develop` command, which neither builds nor precompiles the package, when
that happens is left up to the user to decide.

If a package that has been updated is already loaded in the session, the precompilation process will go ahead and precompile
the new version, and any packages that depend on it, but will note that the package cannot be used until session restart.

To disable this auto-precompilation, set `ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0`, after which precompilation can be triggered
manually either serially via code loading

```julia-repl
julia> using Example
[ Info: Precompiling Example [7876af07-990d-54b4-ab0e-23690620f79a]
```

 or the parallel precompilation, which can be significantly faster when many dependencies are involved, via

```julia-repl
pkg> precompile
Precompiling project...
  23 dependencies successfully precompiled in 36 seconds
```

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

!!! note "Specifying project on startup"
    Instead of using `activate` from within Julia you can specify the project on startup using
    the `--project=<path>` flag. For example, to run a script from the command line using the
    environment in the current directory you can run
    ```bash
    $ julia --project=. myscript.jl
    ```


## Temporary environments

It is not uncommon to test some package without installing it into your usual environment.
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

The temporary directory containing this environment will be removed when you exit Julia,
so you don't need to worry about interference with your main package environment(s).

Note that this still uses the global package depot (typically `~/.julia`), which is shared between environments.
Perhaps when troubleshooting an especially thorny package management issue, you may want to ensure the
temporary environment's package depot is completely independent from any other package environment by
setting the [`JULIA_DEPOT_PATH`](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_DEPOT_PATH) environment variable.
For example,

```console
# Linux Bash
root@dc76efc35971:/# JULIA_DEPOT_PATH=/tmp/juliatmp julia

(@v1.6) pkg> st
  Installing known registries into `/tmp/juliatmp`
      Status `/tmp/juliatmp/environments/v1.6/Project.toml` (empty project)

(@v1.6) pkg> add Example
    Updating registry at `/tmp/juliatmp/registries/General.toml`
   Resolving package versions...
   Installed Example ─ v0.5.3
    Updating `/tmp/juliatmp/environments/v1.6/Project.toml`
  [7876af07] + Example v0.5.3
    Updating `/tmp/juliatmp/environments/v1.6/Manifest.toml`
  [7876af07] + Example v0.5.3
Precompiling project...
  1 dependency successfully precompiled in 0 seconds
```

This way, anything downloaded or modified by package operations will be stored in the temporary directory
`/tmp/juliatmp`, with no need to worry that it might break your regular workflow.

## [shared environment](@id shared-environment)

For package development, the best practice is to maintain the smallest possible set of dependencies in an independent project folder.
However, from a user's perspective, one often wants to have convenient tools installed globally to reduce the
need to switch between environments. Note that each minor version of Julia has its own default global shared environment stored in the `~/.julia/environments` folder.

For instance, [BenchmarkTools.jl](https://github.com/JuliaCI/BenchmarkTools.jl) provides a popular set of tools to accurately measure function runtime and memory usage.

```julia-repl
(@v1.6) pkg> st
      Status `~/.julia/environments/v1.6/Project.toml`
  [6e4b80f9] BenchmarkTools v1.3.1

(@v1.6) pkg> activate MyProject
  Activating new environment at `~/MyProject/Project.toml`

julia> using BenchmarkTools

```

Loading `BenchmarkTools` in MyProject environment works even if this package is not recorded in `~/MyProject/Project.toml`. This is
because Julia maintains a environments stack via the `LOAD_PATH` variable; see also the [environment stacks](https://docs.julialang.org/en/v1/manual/code-loading/#Environment-stacks) section in the Julia manual.

```julia-repl
julia> LOAD_PATH
3-element Vector{String}:
 "@"
 "@v#.#"
 "@stdlib"
```

With this `LOAD_PATH`, Julia will first try to load the `BenchmarkTools` package in the `@` environment, which is the current activated project.
If it's not found there, Julia will then look in the version-specific global environment `@v#.#`, which is stored in `~/.julia/environments/v1.6` for Julia 1.6. Finally, it will check the standard library.
In the example above, Julia found `BenchmarkTools` in `@v#.#`, i.e., `~/.julia/environments/v1.6/Project.toml`,
and successfully loaded the package.

A convenient command to create a custom shared environment is to prefix the name with `@`:

```julia-repl
(@v1.6) pkg> activate @mytoolbox # requires Julia 1.4 or later
  Activating new project at `~/.julia/environments/mytoolbox`
```

This provides a quick way to activate the project environment stored in `~/.julia/environments` folder.

### Caveat for package developers: Shared environments and reproducibility

Because shared environments allow you to load packages without specifying them in a particular environment's
`Project.toml` and `Manifest.toml`, you may encounter problems with reproducibility.

```julia
(MyProject) pkg> generate MyPackage
  Generating  project MyPackage:
    MyPackage/Project.toml
    MyPackage/src/MyPackage.jl

# ... some modifications to MyPackage/src/MyPackage.jl

julia> print(read("MyPackage/Project.toml", String))
name = "MyPackage"
uuid = "c10752ec-72c1-4eb2-a399-580941ff7382"
version = "0.1.0"

julia> print(read("MyPackage/src/MyPackage.jl", String))
module MyPackage

using BenchmarkTools

greet() = print("Hello World!")

end # module
```

When you try to load `MyPackage`, Julia searches for and finds `BenchmarkTools` in the global shared environment `v#.#`, so loading is successful, but a warning message is printed:

```julia
julia> using MyPackage
┌ Warning: Package MyPackage does not have BenchmarkTools in its dependencies:
│ - If you have MyPackage checked out for development and have
│   added BenchmarkTools as a dependency but haven't updated your primary
│   environment's manifest file, try `Pkg.resolve()`.
│ - Otherwise you may need to report an issue with MyPackage
└ Loading BenchmarkTools into MyPackage from project dependency, future warnings for MyPackage are suppressed.
```

Imagine that you want to ship your wonderful package to other people. Because `BenchmarkTools` is not recorded in `MyPackage/Project.toml`,
you can't ensure that `BenchmarkTools` will be successfully loaded. For this reason, developers of shared packages should be especially mindful of reproducibility issues when using shared environments.
