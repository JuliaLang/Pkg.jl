# [**6.** Apps](@id Apps)

!!! note
    The app support in Pkg is currently considered experimental and some functionality and API may change.

    Some inconveniences that can be encountered are:
    - You need to manually make `~/.julia/bin` available on the PATH environment
      (Pkg tells you how when an app is installed and the directory is not in PATH).

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

function @main(ARGS)
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

!!! note
    In TOML, `reverse = {}` under `[apps]` and a `[apps.reverse]` table are
    equivalent. Pkg may rewrite between these two forms when it writes out the
    project file.

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

function @main(ARGS)
    println("Main app: ", join(ARGS, " "))
end

include("CLI.jl")

end # module
```

```julia
# src/CLI.jl
module CLI

function @main(ARGS)
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

## Apps with their own environment

By default an app runs in the environment of its package: it can load the package and the
dependencies of the package. An app that needs other dependencies (for example an argument
parser or a plotting package that the library itself should not depend on) can instead run in
another project of the same repository, named with the `project` key:

```toml
# Project.toml
name = "MyPackage"
uuid = "..."

[workspace]
projects = ["cli"]

[apps]
mypackage = {}                           # runs MyPackage.main
mypackage-cli = { project = "cli" }      # runs MyPackageCLI.main in the environment of cli/
```

```toml
# cli/Project.toml
name = "MyPackageCLI"
uuid = "..."

[deps]
ArgParse = "c7e460c6-2fb9-53a9-8c5b-16f535851c63"
MyPackage = "..."
```

```julia
# cli/src/MyPackageCLI.jl
module MyPackageCLI

using ArgParse, MyPackage

function @main(ARGS)
    # ...
end

end # module
```

The `project` is the path (relative to the package, with `/` as separator) of a directory in the
package holding a project that is itself a package, that is, it has a `name`, a `uuid` and a
`src/<name>.jl` file with the `@main` entry point. The `submodule` and `julia_flags` keys work
as for other apps, with `submodule` naming a submodule of that package.

Each such project gets an environment of its own when the apps are installed, so apps of the same
package can use different (even incompatible) dependencies and an app only loads what it needs.
Dependencies on packages in the same repository (the package itself and the projects of its
workspace) are loaded from the installed package, so `mypackage-cli` above always runs with the
version of `MyPackage` that it was installed with. For this to also work when developing the
package, make the project part of the [workspace](@ref Workspaces) of the package as above, or
give it a `[sources]` entry such as `MyPackage = {path = ".."}`.

## Shipping a manifest

By default the dependencies of an app are resolved when it is installed, to the latest versions
that are compatible. To instead have the app run with the versions it was tested with, commit
the `Manifest.toml` of the package (for an app with its own `project`, the manifest of that
project or of the workspace it is part of). When a package has a manifest, the apps are installed
with the versions recorded in it, and `app update` only changes them when a new version of the
package comes with a new manifest.

A manifest is written for one machine and one Julia version, so not all of it carries over:

- Paths in it that lead to a place inside the package (a package in a subdirectory, the other
  projects of a workspace) lead into the installed package. Other paths, such as a package
  developed next to the repository, only exist on the machine of the author: they are ignored with
  a warning and the dependency is then taken from a registry. (They are followed when the app is
  installed from a local path.)
- The versions of the standard libraries are those of the Julia that the app is installed with. A
  manifest for a specific Julia version (`Manifest-v1.12.toml`) is preferred when it matches.
- If the recorded versions can not be used with the running Julia, the latest compatible versions
  are installed instead, with a warning.
- Registries named in the manifest are not installed.

Developed apps (`app develop`) run in the project they are developed in, with its manifest as it is.

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

### The Julia Executable

By default, apps run with the same Julia executable that was used to install them.
If that Julia installation is removed, the app runs with another Julia:

- When the Julia was installed with [juliaup](https://github.com/JuliaLang/juliaup), the app runs
  with the juliaup channel of the same minor version (for example `julia +1.12`), which picks up the
  patch release that replaced it.
- Otherwise the app runs with the `julia` in `PATH` and prints a warning.

Versions of juliaup that support it also keep the Julia versions that apps use installed when a
channel is updated or removed, until no app uses them anymore (juliaup reads the `julia_command`
of the apps in `environments/apps/AppManifest.toml` of the depots in `JULIA_DEPOT_PATH`).

To make apps use the running Julia instead of the one they were installed with, without changing
the versions of their packages, use `pkg> app relink [name]` (all apps if no name is given).
Apps whose package does not support the running Julia according to its `julia` compat are skipped
with a warning, use `pkg> app update name` to get a version of the package that does.
`pkg> app status` marks apps whose Julia no longer exists.

You can also override the Julia executable globally using the `JULIA_APPS_JULIA_CMD` environment variable:

```bash
# Use a different Julia version for all apps
export JULIA_APPS_JULIA_CMD=/path/to/different/julia
myapp input.txt

# On Windows
set JULIA_APPS_JULIA_CMD=C:\path\to\different\julia.exe
myapp input.txt
```

## Installing Julia apps

The installation of Julia apps is similar to [installing Julia libraries](@ref Managing-Packages) but instead of using e.g. `Pkg.add` or `pkg> add` one uses `Pkg.Apps.add` or `pkg> app add`.
Apps can be installed from a registry, a git URL, or a local path:

```julia-repl
pkg> app add Runic          # from a registry
pkg> app add Runic@1.5      # specific version
pkg> app add https://github.com/fredrikekre/Runic.jl
pkg> app add path/to/Package  # local path (must be a git repository)
```

The apps are installed as small launcher scripts in `~/.julia/bin`. If that directory is not in
`PATH`, Pkg prints the command that adds it for your shell.

### Managing installed apps

```julia-repl
pkg> app status             # the installed apps, their package and the julia that runs them
pkg> app update             # update all apps (or `app update Runic`)
pkg> app rm Runic           # remove all apps of a package
pkg> app rm git-runic       # remove a single app
```

`app update` installs the latest version of the package and of its dependencies and shows what
changed. An update (or a new `app add`) that fails, for example because the new version cannot be
resolved, leaves the installed apps as they were. An app that was removed on its own with
`app rm` stays removed when its package is updated; `app add` the package again to get it back.

If two packages provide an app with the same name, the one installed last replaces the other.

### Developing apps

To install an app from a local package such that changes to the package are immediately reflected in the app, use `Pkg.Apps.develop` or `pkg> app develop`:

```julia-repl
pkg> app develop path/to/Package
```

The apps then run directly from that directory, in the environment of the project there.
While working on an app it can also be run without installing it:

```
$ julia --project=path/to/Package -m MyPackage arg1 arg2
```

## Apps API Reference

```@docs
Pkg.Apps.add
Pkg.Apps.develop
Pkg.Apps.update
Pkg.Apps.status
Pkg.Apps.rm
Pkg.Apps.relink
```
