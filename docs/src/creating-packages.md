# **5.** Creating Packages

A package is a project with a `name`, `uuid` and `version` entry in the `Project.toml` file, and a `src/PackageName.jl` file that defines the module `PackageName`.
This file is executed when the package is loaded.

## Generating files for a package

!!! note
    The [PkgTemplates](https://github.com/invenia/PkgTemplates.jl) package offers a very easy, repeatable, and 
    customizable way to generate the files for a new package. We recommend that you use PkgTemplates for creating
    new packages instead of using the minimal `pkg> generate` functionality described below.

To generate files for a new package, use `pkg> generate`.

```julia-repl
(v1.0) pkg> generate HelloWorld
```

This creates a new project `HelloWorld` with the following files (visualized with the external [`tree` command](https://linux.die.net/man/1/tree)):

```julia-repl
julia> cd("HelloWorld")

shell> tree .
.
├── Project.toml
└── src
    └── HelloWorld.jl

1 directory, 2 files
```

The `Project.toml` file contains the name of the package, its unique UUID, its version, the authors and potential dependencies:

```toml
name = "HelloWorld"
uuid = "b4cd1eb8-1e24-11e8-3319-93036a3eb9f3"
version = "0.1.0"
authors = ["Some One <someone@email.com>"]

[deps]
```

The content of `src/HelloWorld.jl` is:

```julia
module HelloWorld

greet() = print("Hello World!")

end # module
```

We can now activate the project and load the package:

```julia-repl
pkg> activate .

julia> import HelloWorld

julia> HelloWorld.greet()
Hello World!
```

## Adding dependencies to the project

Let’s say we want to use the standard library package `Random` and the registered package `JSON` in our project.
We simply `add` these packages (note how the prompt now shows the name of the newly generated project,
since we `activate`d it):

```julia-repl
(HelloWorld) pkg> add Random JSON
 Resolving package versions...
  Updating "~/Documents/HelloWorld/Project.toml"
 [682c06a0] + JSON v0.17.1
 [9a3f8284] + Random
  Updating "~/Documents/HelloWorld/Manifest.toml"
 [34da2185] + Compat v0.57.0
 [682c06a0] + JSON v0.17.1
 [4d1e1d77] + Nullables v0.0.4
 ...
```

Both `Random` and `JSON` got added to the project’s `Project.toml` file, and the resulting dependencies got added to the `Manifest.toml` file.
The resolver has installed each package with the highest possible version, while still respecting the compatibility that each package enforces on its dependencies.

We can now use both `Random` and `JSON` in our project. Changing `src/HelloWorld.jl` to

```julia
module HelloWorld

import Random
import JSON

greet() = print("Hello World!")
greet_alien() = print("Hello ", Random.randstring(8))

end # module
```

and reloading the package, the new `greet_alien` function that uses `Random` can be called:

```julia-repl
julia> HelloWorld.greet_alien()
Hello aT157rHV
```

## Adding a build step to the package

The build step is executed the first time a package is installed or when explicitly invoked with `build`.
A package is built by executing the file `deps/build.jl`.

```julia-repl
julia> print(read("deps/build.jl", String))
println("I am being built...")

(HelloWorld) pkg> build
  Building HelloWorld → `deps/build.log`
 Resolving package versions...

julia> print(read("deps/build.log", String))
I am being built...
```

If the build step fails, the output of the build step is printed to the console

```julia-repl
julia> print(read("deps/build.jl", String))
error("Ooops")

(HelloWorld) pkg> build
  Building HelloWorld → `deps/build.log`
 Resolving package versions...
┌ Error: Error building `HelloWorld`:
│ ERROR: LoadError: Ooops
│ Stacktrace:
│  [1] error(::String) at ./error.jl:33
│  [2] top-level scope at none:0
│  [3] include at ./boot.jl:317 [inlined]
│  [4] include_relative(::Module, ::String) at ./loading.jl:1071
│  [5] include(::Module, ::String) at ./sysimg.jl:29
│  [6] include(::String) at ./client.jl:393
│  [7] top-level scope at none:0
│ in expression starting at /Users/kristoffer/.julia/dev/Pkg/HelloWorld/deps/build.jl:1
└ @ Pkg.Operations Operations.jl:938
```

## Adding tests to the package

When a package is tested the file `test/runtests.jl` is executed:

```julia-repl
julia> print(read("test/runtests.jl", String))
println("Testing...")

(HelloWorld) pkg> test
   Testing HelloWorld
 Resolving package versions...
Testing...
   Testing HelloWorld tests passed
```

Tests are run in a new Julia process, where the package itself, and any
test-specific dependencies, are available, see below.

### Test-specific dependencies in Julia 1.2 and above

!!! compat "Julia 1.2"
    This section only applies to Julia 1.2 and above. For specifying test dependencies
    on previous Julia versions, see [Test-specific dependencies in Julia 1.0 and 1.1](@ref).

!!! note
    The exact interaction between `Project.toml`, `test/Project.toml` and their corresponding
    `Manifest.toml`s are not fully worked out, and may be subject to change in future versions.
    The old method of adding test-specific dependencies, described in the next section, will
    therefore be supported throughout all Julia 1.X releases.

In Julia 1.2 and later the test environment is given by `test/Project.toml`. Thus, when running
tests, this will be the active project, and only dependencies to the `test/Project.toml` project
can be used. Note that Pkg will add the tested package itself implictly.

!!! note
    If no `test/Project.toml` exists Pkg will use the old style test-setup, as
    described in [Test-specific dependencies in Julia 1.0 and 1.1](@ref).

To add a test-specific dependency, i.e. a dependency that is available only when testing,
it is thus enough to add this dependency to the `test/Project.toml` project. This can be
done from the Pkg REPL by activating this environment, and then use `add` as one normally
does. Lets add the `Test` standard library as a test dependency:

```julia-repl
(HelloWorld) pkg> activate ./test
[ Info: activating environment at `~/HelloWorld/test/Project.toml`.

(test) pkg> add Test
 Resolving package versions...
  Updating `~/HelloWorld/test/Project.toml`
  [8dfed614] + Test
  Updating `~/HelloWorld/test/Manifest.toml`
  [...]
```

We can now use `Test` in the test script and we can see that it gets installed when testing:

```julia-repl
julia> print(read("test/runtests.jl", String))
using Test
@test 1 == 1

(HelloWorld) pkg> test
   Testing HelloWorld
 Resolving package versions...
  Updating `/var/folders/64/76tk_g152sg6c6t0b4nkn1vw0000gn/T/tmpPzUPPw/Project.toml`
  [d8327f2a] + HelloWorld v0.1.0 [`~/.julia/dev/Pkg/HelloWorld`]
  [8dfed614] + Test
  Updating `/var/folders/64/76tk_g152sg6c6t0b4nkn1vw0000gn/T/tmpPzUPPw/Manifest.toml`
  [d8327f2a] + HelloWorld v0.1.0 [`~/.julia/dev/Pkg/HelloWorld`]
   Testing HelloWorld tests passed```
```

### Test-specific dependencies in Julia 1.0 and 1.1

!!! note
    The method of adding test-specific dependencies described in this section will
    be replaced by the method from the previous section in future Julia versions.
    The method in this section will, however, be supported throughout all Julia 1.X
    releases.

In Julia 1.0 and Julia 1.1 test-specific dependencies are added to the main
`Project.toml`. To add `Markdown` and `Test` as test-dependencies, add the following:

```toml
[extras]
Markdown = "d6f4376e-aef5-505a-96c1-9c027394607a"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Markdown", "Test"]
```

## Package naming guidelines

Package names should be sensible to most Julia users, *even to those who are not domain experts*.
The following guidelines applies to the `General` registry, but may be useful for other package
registries as well.

Since the `General` registry belongs to the entire community, people may have opinions about
your package name when you publish it, especially if it's ambiguous or can be confused with
something other than what it is. Usually you will then get suggestions for a new name that
may fit your package better.

1. Avoid jargon. In particular, avoid acronyms unless there is minimal possibility of confusion.

     * It's ok to say `USA` if you're talking about the USA.
     * It's not ok to say `PMA`, even if you're talking about positive mental attitude.
2. Avoid using `Julia` in your package name or prefixing it with `Ju`.

     * It is usually clear from context and to your users that the package is a Julia package.
     * Package names already have a `.jl` extension, which communicates to users that `Package.jl` is a Julia package.
     * Having Julia in the name can imply that the package is connected to, or endorsed by, contributors
       to the Julia language itself.
3. Packages that provide most of their functionality in association with a new type should have pluralized
   names.

     * `DataFrames` provides the `DataFrame` type.
     * `BloomFilters` provides the `BloomFilter` type.
     * In contrast, `JuliaParser` provides no new type, but instead new functionality in the `JuliaParser.parse()`
       function.
4. Err on the side of clarity, even if clarity seems long-winded to you.

     * `RandomMatrices` is a less ambiguous name than `RndMat` or `RMT`, even though the latter are shorter.
5. A less systematic name may suit a package that implements one of several possible approaches to
   its domain.

     * Julia does not have a single comprehensive plotting package. Instead, `Gadfly`, `PyPlot`, `Winston`
       and other packages each implement a unique approach based on a particular design philosophy.
     * In contrast, `SortingAlgorithms` provides a consistent interface to use many well-established
       sorting algorithms.
6. Packages that wrap external libraries or programs should be named after those libraries or programs.

     * `CPLEX.jl` wraps the `CPLEX` library, which can be identified easily in a web search.
     * `MATLAB.jl` provides an interface to call the MATLAB engine from within Julia.
7. Avoid naming a package closely to an existing package
     * `Websocket` is too close to `WebSockets` and can be confusing to users. Rather use a new name such as `SimpleWebsockets`.

## Registering packages

Once a package is ready it can be registered with the [General Registry](https://github.com/JuliaRegistries/General#registering-a-package-in-general) (see also the [FAQ](https://github.com/JuliaRegistries/General#faq)).
Currently packages are submitted via [`Registrator`](https://juliaregistrator.github.io/).
In addition to `Registrator`, [`TagBot`](https://github.com/marketplace/actions/julia-tagbot) helps manage the process of tagging releases.

## Best Practices

Packages should avoid mutating their own state (writing to files within their package directory).
Packages should, in general, not assume that they are located in a writable location (e.g. if installed as part of a system-wide depot) or even a stable one (e.g. if they are bundled into a system image by [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl)).
To support the various usecases in the Julia package ecosystem, the Pkg developers have created a number of auxilliary packages and techniques to help package authors create self-contained, immutable and relocatable packages:

* [`Artifacts`](https://pkgdocs.julialang.org/v1/artifacts/) can be used to bundle chunks of data alongside your package, or even allow them to be downloaded on-demand.
  Prefer artifacts over attempting to open a file via a path such as `joinpath(@__DIR__, "data", "my_dataset.csv")` as this is non-relocatable.
  Once your package has been precompiled, the result of `@__DIR__` will have been baked into your precompiled package data, and if you attempt to distribute this package, it will attempt to load files at the wrong location.
  Artifacts can be bundled and accessed easily using the `artifact"name"` string macro.
  Artifacts are available from Julia 1.3 onward.

* [`Scratch.jl`](https://github.com/JuliaPackaging/Scratch.jl) provides the notion of "scratch spaces", mutable containers of data for packages.
  Scratch spaces are designed for data caches that are completely managed by a package and should be removed when the package itself is uninstalled.
  For important user-generated data, packages should continue to write out to a user-specified path that is not managed by Julia or Pkg.
  Scratch is usable from Julia 1.5 onward.
  
* [`Preferences.jl`](https://github.com/JuliaPackaging/Preferences.jl) allows packages to read and write preferences to the top-level `Project.toml`.
  These preferences can be read at runtime or compile-time, to enable or disable different aspects of package behavior.
  Packages previously would write out files to their own package directories to record options set by the user or environment, but this is highly discouraged now that `Preferences` is available.
  Preferences are available from Julia 1.6 onward.
 
