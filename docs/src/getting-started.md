# **2.** Getting Started

What follows is a quick overview of the basic features of Pkg.
It should help new users become familiar with basic Pkg features such as adding and removing packages and
working with environments.

!!! note
    Some Pkg output is omitted in this section in order to keep this basic guide focused.
    This will help maintain a good pace and not get bogged down in details.
    If you require more details, refer to subsequent sections of the Pkg manual.

!!! note
    This guide uses the Pkg REPL to execute Pkg commands.
    For non-interactive use, we recommend the Pkg API.
    The Pkg API is fully documented in the [API Reference](@ref) section of the Pkg documentation.
## Basic Usage

Pkg comes with a REPL.
Enter the Pkg REPL by pressing `]` from the Julia REPL.
To get back to the Julia REPL, press `Ctrl+C` or backspace (when the REPL cursor is at the beginning of the input).

Upon entering the Pkg REPL, you should see the following prompt:

```julia-repl
(@v1.8) pkg>
```

To add a package, use `add`:

```julia-repl
(@v1.8) pkg> add Example
   Resolving package versions...
   Installed Example ─ v0.5.3
    Updating `~/.julia/environments/v1.8/Project.toml`
  [7876af07] + Example v0.5.3
    Updating `~/.julia/environments/v1.8/Manifest.toml`
  [7876af07] + Example v0.5.3
```

After the package is installed, it can be loaded into the Julia session:

```julia-repl
julia> import Example

julia> Example.hello("friend")
"Hello, friend"
```

We can also specify multiple packages at once to install:

```julia-repl
(@v1.8) pkg> add JSON StaticArrays
```

The `status` command (or the shorter `st` command) can be used to see installed packages.

```julia-repl
(@v1.8) pkg> st
Status `~/.julia/environments/v1.6/Project.toml`
  [7876af07] Example v0.5.3
  [682c06a0] JSON v0.21.3
  [90137ffa] StaticArrays v1.5.9
```

!!! note
    Some Pkg REPL commands have a short and a long version of the command, for example `status` and `st`.

To remove packages, use `rm` (or `remove`):

```julia-repl
(@v1.8) pkg> rm JSON StaticArrays
```

Use `up` (or `update`) to update the installed packages

```julia-repl
(@v1.8) pkg> up
```

If you have been following this guide it is likely that the packages installed are at the latest version
so `up` will not do anything. Below we show the status output in the case where we delibirately have installed
an old version of the Example package and then upgrade it:

```julia-repl
(@v1.8) pkg> st
Status `~/.julia/environments/v1.8/Project.toml`
⌃ [7876af07] Example v0.5.1
Info Packages marked with ⌃ have new versions available and may be upgradable.

(@v1.8) pkg> up
    Updating `~/.julia/environments/v1.8/Project.toml`
  [7876af07] ↑ Example v0.5.1 ⇒ v0.5.3
```

We can see that the status output tells us that there is a newer version available and that `up` upgrades the package.

## Getting Started with Environments

Up to this point, we have covered basic package management: adding, updating and removing packages.

You may have noticed the `(@v1.8)` in the REPL prompt.
This lets us know `v1.8` is the **active environment**.
The active environment is the environment that will be modified by Pkg commands such as `add`, `rm` and `update`.


Let's set up a new environment so we may experiment.
To set the active environment, use `activate`:

```julia-repl
(@v1.8) pkg> activate tutorial
[ Info: activating new environment at `/tmp/tutorial/Project.toml`.
```

Pkg lets us know we are creating a new environment and that this environment
will be stored in the `/tmp/tutorial` directory.

Pkg has also updated the REPL prompt in order to reflect the new
active environment:

```julia-repl
(tutorial) pkg>
```

We can ask for information about the active environment by using `status`:

```julia-repl
(tutorial) pkg> status
    Status `/tmp/tutorial/Project.toml`
   (empty environment)
```

`/tmp/tutorial/Project.toml` is the location of the active environment's **project file**.
A project file is where Pkg stores metadata for an environment.
Notice this new environment is empty.
Let us add a package and observe:

```julia-repl
(tutorial) pkg> add Example
...

(tutorial) pkg> status
    Status `/tmp/tutorial/Project.toml`
  [7876af07] Example v0.5.1
```

We can see `tutorial` now contains `Example` as a dependency.

## Modifying A Dependency

Say we are working on `Example` and feel it needs new functionality.
How can we modify the source code?
We can use `develop` to set up a git clone of the `Example` package.

```julia-repl
(tutorial) pkg> develop --local Example
...

(tutorial) pkg> status
    Status `/tmp/tutorial/Project.toml`
  [7876af07] Example v0.5.1+ [`dev/Example`]
```

Notice the feedback has changed.
`dev/Example` refers to the location of the newly created clone.
If we look inside the `/tmp/tutorial` directory, we will notice the following files:

```
tutorial
├── dev
│   └── Example
├── Manifest.toml
└── Project.toml
```

Instead of loading a registered version of `Example`,
Julia will load the source code contained in `tutorial/dev/Example`.

Let's try it out.
First we modify the file at `tutorial/dev/Example/src/Example.jl` and add a simple function:

```julia
plusone(x::Int) = x + 1
```

Now we can go back to the Julia REPL and load the package:

```julia-repl
julia> import Example
```

!!! warning
    A package can only be loaded once per Julia session.
    If you have run `import Example` in the current Julia session, you will
    have to restart Julia and rerun `activate tutorial` in the Pkg REPL.
    [Revise.jl](https://github.com/timholy/Revise.jl/) can make this process
    significantly more pleasant, but setting it up is beyond the scope of this guide.

Julia should load our new code. Let's test it:

```julia-repl
julia> Example.plusone(1)
2
```

Say we have a change of heart and decide the world is not ready for such elegant code.
We can tell Pkg to stop using the local clone and use a registered version instead.
We do this with `free`:

```julia-repl
(tutorial) pkg> free Example
```

When you are done experimenting with `tutorial`, you can return to the **default
environment** by running `activate` with no arguments:

```julia-repl
(tutorial) pkg> activate

(@v1.8) pkg>
```

## Unregistered packages

So far, we have only added "registered" packages which can be added by their name[^1].

[^1]: [JuliaHub](https://juliahub.com/ui/Packages) is a good resource for exploring registered packages.

Pkg also supports working with unregistered packages.
To add an unregistered package, specify a URL:

```julia-repl
(@v1.8) pkg> add https://github.com/JuliaLang/Example.jl
```

Use `rm` to remove this package by name:

```julia-repl
(@v1.8) pkg> rm Example
```

## Asking for Help

If you are ever stuck, you can ask `Pkg` for help:

```julia-repl
(@v1.8) pkg> ?
```

You should see a list of available commands along with short descriptions.
You can ask for more detailed help by specifying a command:

```julia-repl
(@v1.8) pkg> ?develop
```

This guide should help you get started with `Pkg`.
`Pkg` has much more to offer in terms of powerful package management,
read the full manual to learn more!
