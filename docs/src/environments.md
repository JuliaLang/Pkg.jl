# **4.** Working with Environments

## Creating your own projects

So far we have added packages to the default project at `~/.julia/environments/v1.0`. It is however easy to create other, independent, projects.
It should be pointed out that when two projects use the same package at the same version, the content of this package is not duplicated.
In order to create a new project, create a directory for it and then activate that directory to make it the "active project", which package operations manipulate:

```julia-repl
julia> mkdir("MyProject")

julia> cd("MyProject")
/Users/kristoffer/MyProject

(v1.0) pkg> activate .

(MyProject) pkg> st
    Status `Project.toml`
```

Note that the REPL prompt changed when the new project is activated. Since this is a newly created project, the status command shows that it contains no packages, and in fact, it has no project or manifest file until we add a package to it:

```julia-repl
julia> readdir()
0-element Array{String,1}

(MyProject) pkg> add Example
  Updating registry at `~/.julia/registries/General`
  Updating git-repo `https://github.com/JuliaRegistries/General.git`
 Resolving package versions...
  Updating `Project.toml`
  [7876af07] + Example v0.5.1
  Updating `Manifest.toml`
  [7876af07] + Example v0.5.1
  [8dfed614] + Test

julia> readdir()
2-element Array{String,1}:
 "Manifest.toml"
 "Project.toml"

julia> print(read("Project.toml", String))
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"

julia> print(read("Manifest.toml", String))
[[Example]]
deps = ["Test"]
git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "0.5.1"

[[Test]]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
```

This new environment is completely separate from the one we used earlier.


## Precompiling a project

The REPL command `precompile` can be used to precompile all the dependencies in the project. You can for example do

```julia-repl
(HelloWorld) pkg> update; precompile
```

to update the dependencies and then precompile them.

## Using someone else's project

Simply clone their project using e.g. `git clone`, `cd` to the project directory and call

```julia-repl
(v1.0) pkg> activate .

(SomeProject) pkg> instantiate
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
