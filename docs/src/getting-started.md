# **2.** Getting Started

Pkg comes with its own REPL mode, which can be entered from the Julia REPL
by pressing `]`. To get back to the Julia REPL press backspace or ^C.

```
(v1.1) pkg>
```

The prompt displays the current active environment, which is the environment
that Pkg commands will modify. The default environment is based on the current
Julia version, `(v1.1)` in the example above, and is located in
`~/.julia/environments/`.

!!! note
    There are other ways of interacting with Pkg:
    1. The `pkg` string macro, which is available after `using Pkg`. The command
       `pkg"cmd"` is equivalent to executing `cmd` in the Pkg REPL.
    2. The API-mode, which is recommended for non-interactive
       environments. The API mode is documented in full in the API Reference section
       of the Pkg documentation.


To add a package, use the `add` command

```
(v1.1) pkg> add Example
```

Multiple packages may be specified:

```
(v1.1) pkg> add Example JSON StaticArrays
```

To remove a package, use the `rm` command. `rm` also accepts multiple packages:

```
(v1.1) pkg> rm JSON StaticArrays
```

So far, we have specified by names in a registry. If you want to add a package
which is not in a registry, you can specify the location directly, for example
with an URL:

```
(v1.1) pkg> add https://github.com/JuliaLang/Example.jl
```

To remove this package, use `rm` and specify the package by name (not URL!):

```
(v1.1) pkg> rm Example
```

The `update` command can be used to update a installed package:

```
(v1.1) pkg> update Example
```

To update all installed packages simply use `update` without any arguments:

```
(v1.1) pkg> update
```

This should cover most use cases for simple package management:
adding, updating and removing dependencies. But say you are working on a project
and you encounter a bug in one of your dependencies!
How would you access the source? `Pkg` can help you out with `develop`:

```
(v1.1) pkg> develop --local Example
```

The `Example` package is now cloned to the `dev` subdirectory of your project directory.
You can edit `Example`'s source and any changes you make will be visible to your project.

Once upstream `Example` has been patched, you can stop tracking the local clone.
Do this with a `free` command:

```
(v1.1) pkg> free Example
```

Now you are back to using the version of `Example` in the registry.

If you are ever stuck, ask `Pkg` for help:

```
(v1.1) pkg> ?
```

You should see a list of available commands along with short descriptions.
You can ask for more thorough help for a specific command:

```
(v1.1) pkg> ?develop
```

This quickstart should get you started with `Pkg`'s common use cases,
but there is still lots more that `Pkg` has to offer in terms of powerful
package management. Read the full manual to learn more!
