# **5.** Creating Packages

A package is a project with a `name`, `uuid` and `version` entry in the `Project.toml` file, and a `src/PackageName.jl` file that defines the module `PackageName`.
This file is executed when the package is loaded.

### Generating files for a package

To generate files for a new package, use `pkg> generate`.

```
(v1.0) pkg> generate HelloWorld
```

This creates a new project `HelloWorld` with the following files (visualized with the external [`tree` command](https://linux.die.net/man/1/tree)):

```jl
shell> cd HelloWorld

shell> tree .
.
├── Project.toml
└── src
    └── HelloWorld.jl

1 directory, 2 files
```

The `Project.toml` file contains the name of the package, its unique UUID, its version, the author and potential dependencies:

```toml
name = "HelloWorld"
uuid = "b4cd1eb8-1e24-11e8-3319-93036a3eb9f3"
version = "0.1.0"
author = ["Some One <someone@email.com>"]

[deps]
```

The content of `src/HelloWorld.jl` is:

```jl
module HelloWorld

greet() = print("Hello World!")

end # module
```

We can now activate the project and load the package:

```jl
pkg> activate .

julia> import HelloWorld

julia> HelloWorld.greet()
Hello World!
```

### Adding dependencies to the project

Let’s say we want to use the standard library package `Random` and the registered package `JSON` in our project.
We simply `add` these packages (note how the prompt now shows the name of the newly generated project,
since we `activate`d it):

```
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

```
module HelloWorld

import Random
import JSON

greet() = print("Hello World!")
greet_alien() = print("Hello ", Random.randstring(8))

end # module
```

and reloading the package, the new `greet_alien` function that uses `Random` can be called:

```
julia> HelloWorld.greet_alien()
Hello aT157rHV
```

If you have an *existing* package from an older version of Julia (using a `REQUIRE` file rather than `Project.toml`), then you can generate a `Project.toml` file by running the [`gen_project.jl`](https://github.com/JuliaLang/Pkg.jl/blob/master/bin/gen_project.jl) script with `julia gen_project.jl` in the development directory of your package.  This has to be done (once) before a new release can be registered for an older package.  (Delete `REQUIRE` and commit the resulting `Project.toml` after checking it for correctness and adding a `version = "..."` line.)

### Adding a build step to the package

The build step is executed the first time a package is installed or when explicitly invoked with `build`.
A package is built by executing the file `deps/build.jl`.

```
shell> cat deps/build.jl
println("I am being built...")

(HelloWorld) pkg> build
  Building HelloWorld → `deps/build.log`
 Resolving package versions...

shell> cat deps/build.log
I am being built...
```

If the build step fails, the output of the build step is printed to the console

```
shell> cat deps/build.jl
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

### Adding tests to the package

When a package is tested the file `test/runtests.jl` is executed:

```
shell> cat test/runtests.jl
println("Testing...")

(HelloWorld) pkg> test
   Testing HelloWorld
 Resolving package versions...
Testing...
   Testing HelloWorld tests passed
```

Tests are run in a new Julia process, where the package itself, and any
test-specific dependencies, are available, see below.

#### Test-specific dependencies in Julia 1.2 and above

!!! compat "Julia 1.2"
    This section only applies to Julia 1.2 and above. For specifying test dependencies
    on previous Julia versions, see [Test-specific dependencies in Julia 1.0 and 1.1](@ref).

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

```
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

```
shell> cat test/runtests.jl
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

#### Test-specific dependencies in Julia 1.0 and 1.1

In Julia 1.0 and Julia 1.1 test-specific dependencies are added to the main
`Project.toml`. To add `Markdown` and `Test` as test-dependencies, add the following:

```
[extras]
Markdown = "d6f4376e-aef5-505a-96c1-9c027394607a"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Markdown", "Test"]
```

### Package naming guidelines

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
2. Avoid using `Julia` in your package name.

     * It is usually clear from context and to your users that the package is a Julia package.
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

### Registering packages

Once a package is ready it can be registered with the [General Registry](https://github.com/JuliaRegistries/General).
Currently packages are submitted via [`Registrator`](https://juliaregistrator.github.io/).
In addition to `Registrator`, [`TagBot`](https://github.com/apps/julia-tagbot) helps manage the process of tagging releases.
