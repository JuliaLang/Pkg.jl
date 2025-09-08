# [**6.** Apps](@id Apps)

!!! note
    The app support in Pkg is currently considered experimental and some functionality and API may change.

    Some inconveniences that can be encountered are:
    - You need to manually make `~/.julia/bin` available on the PATH environment.
    - The path to the julia executable used is the same as the one used to install the app. If this
      julia installation gets removed, you might need to reinstall the app.

Apps are Julia packages that are intended to be run as "standalone programs" (by e.g. typing the name of the app in the terminal possibly together with some arguments or flags/options).
This is in contrast to most Julia packages that are used as "libraries" and are loaded by other files or in the Julia REPL.

## Creating a Julia app

A Julia app is structured similar to a standard Julia library with the following additions:

- A `@main` entry point in the package module (see the [Julia help on `@main`](https://docs.julialang.org/en/v1/manual/command-line-interface/#The-Main.main-entry-point) for details)
- An `[apps]` section in the `Project.toml` file listing the executable names that the package provides.

A very simple example of an app that prints the reversed input arguments would be:

```julia
# src/MyReverseApp.jl
module MyReverseApp

function (@main)(ARGS)
    for arg in ARGS
        print(stdout, reverse(arg), " ")
    end
    return
end

end # module
```

```toml
# Project.toml

# standard fields here

[apps]
reverse = {}
```
The empty table `{}` is to allow for giving metadata about the app.

After installing this app one could run:

```
$ reverse some input string
 emos tupni gnirts
```

directly in the terminal.

## Multiple Apps per Package

A single package can define multiple apps by using submodules. Each app can have its own entry point in a different submodule of the package.

```julia
# src/MyMultiApp.jl
module MyMultiApp

function (@main)(ARGS)
    println("Main app: ", join(ARGS, " "))
end

include("CLI.jl")

end # module
```

```julia
# src/CLI.jl
module CLI

function (@main)(ARGS)
    println("CLI submodule: ", join(ARGS, " "))
end

end # module CLI
```

```toml
# Project.toml

# standard fields here

[apps]
main-app = {}
cli-app = { submodule = "CLI" }
```

This will create two executables:
- `main-app` that runs `julia -m MyMultiApp`
- `cli-app` that runs `julia -m MyMultiApp.CLI`

## Configuring Julia Flags

Apps can specify default Julia command-line flags that will be passed to the Julia process when the app is run. This is useful for configuring performance settings, threading, or other Julia options specific to your application.

### Default Julia Flags

You can specify default Julia flags in the `Project.toml` file using the `julia_flags` field:

```toml
# Project.toml

[apps]
myapp = { julia_flags = ["--threads=4", "--optimize=2"] }
performance-app = { julia_flags = ["--threads=auto", "--startup-file=yes", "--depwarn=no"] }
debug-app = { submodule = "Debug", julia_flags = ["--check-bounds=yes", "--optimize=0"] }
```

With this configuration:
- `myapp` will run with 4 threads and optimization level 2
- `performance-app` will run with automatic thread detection, startup file enabled, and deprecation warnings disabled
- `debug-app` will run with bounds checking enabled and no optimization

### Runtime Julia Flags

You can override or add to the default Julia flags at runtime using the `--` separator. Everything before `--` will be passed as flags to Julia, and everything after `--` will be passed as arguments to your app:

```bash
# Uses default flags from Project.toml
myapp input.txt output.txt

# Override thread count, keep other defaults
myapp --threads=8 -- input.txt output.txt

# Add additional flags
myapp --threads=2 --optimize=3 --check-bounds=yes -- input.txt output.txt

# Only Julia flags, no app arguments
myapp --threads=1 --
```

The final Julia command will combine:
1. Fixed flags (like `--startup-file=no` and `-m ModuleName`)
2. Default flags from `julia_flags` in Project.toml
3. Runtime flags specified before `--`
4. App arguments specified after `--`

## Installing Julia apps

The installation of Julia apps is similar to [installing Julia libraries](@ref Managing-Packages) but instead of using e.g. `Pkg.add` or `pkg> add` one uses `Pkg.Apps.add` or `pkg> app add` (`develop` is also available).
