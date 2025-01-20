# [**?.** Apps](@id Apps)

!!! note
    The app support in Pkg is currently considered experimental and some functionality and API may change.

    Some inconveniences that can be encountered are:
    - You need to manually make `~/.julia/bin` available on the PATH environment.
    - The path to the julia executable used is the same as the one used to install the app. If this
      julia installation gets removed, you might need to reinstall the app.
    - You can only have one app installed per package.

Apps are Julia packages that are intended to be run as a "standalone programs" (by e.g. typing the name of the app in the terminal possibly together with some arguments or flags/options).
This is in contrast to most Julia packages that are used as "libraries" and are loaded by other files or in the Julia REPL.

## Creating a Julia app

A Julia app is structured similar to a standard Julia library with the following additions:

- A `@main` entry point in the package module (see the [Julia help on `@main`](https://docs.julialang.org/en/v1/manual/command-line-interface/#The-Main.main-entry-point) for details)
- An `[app]` section in the `Project.toml` file listing the executable names that the package provides.

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
The empty table `{}` is to allow for giving metadata about the app but it is currently unused.

After installing this app one could run:

```
$ reverse some input string
emos tupni gnirts
```

directly in the terminal.

## Installing Julia apps

The installation of Julia apps are similar to installing julia libraries but instead of using e.g. `Pkg.add` or `pkg> add` one uses `Pkg.Apps.add` or `pkg> app add` (`develop` is also available).
