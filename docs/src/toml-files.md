# [**10.** `Project.toml` and `Manifest.toml`](@id Project-and-Manifest)

Two files that are central to Pkg are `Project.toml` and `Manifest.toml`. `Project.toml`
and `Manifest.toml` are written in [TOML](https://github.com/toml-lang/toml) (hence the
`.toml` extension) and include information about dependencies, versions, package names,
UUIDs etc.

!!! note
    The `Project.toml` and `Manifest.toml` files are not only used by the package manager;
    they are also used by Julia's code loading, and determine e.g. what `using Example`
    should do. For more details see the section about
    [Code Loading](https://docs.julialang.org/en/v1/manual/code-loading/)
    in the Julia manual.


## `Project.toml`

The project file describes the project on a high level, for example the package/project
dependencies and compatibility constraints are listed in the project file. The file entries
are described below.


### The `name` field

The name of the package/project is determined by the `name` field, for example:
```toml
name = "Example"
```
The name can contain word characters `[a-zA-Z0-9_]`, but can not start with a number. For
packages it is recommended to follow the
[package naming guidelines](@ref Package-naming-guidelines). The `name` field is mandatory
for packages.


### The `uuid` field

`uuid` is a string with a [universally unique identifier]
(https://en.wikipedia.org/wiki/Universally_unique_identifier) for the package/project, for example:
```toml
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
```
The `uuid` field is mandatory for packages.

!!! note
    It is recommended that `UUIDs.uuid4()` is used to generate random UUIDs.


### The `version` field

`version` is a string with the version number for the package/project. It should consist of
three numbers, major version, minor version and patch number, separated with a `.`, for example:
```toml
version = "1.2.5"
```
Julia uses [Semantic Versioning](https://semver.org/) (SemVer) and the `version` field
should follow SemVer. The basic rules are:
* Before 1.0.0, anything goes, but when you make breaking changes the minor version should
  be incremented.
* After 1.0.0 only make breaking changes when incrementing the major version.
* After 1.0.0 no new public API should be added without incrementing the minor version.
  This includes, in particular, new types, functions, methods and method overloads, from
  `Base` or other packages.
See also the section on [Compatibility](@ref).

Note that Pkg.jl deviates from the SemVer specification when it comes to versions pre-1.0.0. See
[Pre-1.0 behavior](@ref) for more details.


### The `[deps]` section

All dependencies of the package/project are listed in the `[deps]` section. Each dependency
is listed as a name-uuid pair, for example:

```toml
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
```

Typically it is not needed to manually add entries to the `[deps]` section; this is instead
handled by Pkg operations such as `add`.


### The `[compat]` section

Compatibility constraints for the dependencies listed under `[deps]` can be listed in the
`[compat]` section.
Example:

```toml
[deps]
Example = "7876af07-990d-54b4-ab0e-23690620f79a"

[compat]
Example = "1.2"
```

The [Compatibility](@ref) section describes the different possible compatibility
constraints in detail. It is also possible to list constraints on `julia` itself, although
`julia` is not listed as a dependency in the `[deps]` section:

```toml
[compat]
julia = "1.1"
```


## `Manifest.toml`

The manifest file is an absolute record of the state of the packages in the environment.
It includes exact information about (direct and indirect) dependencies of the project. 
Given a `Project.toml` + `Manifest.toml` pair, it is possible to instantiate the exact same
package environment, which is very useful for reproducibility. 
For the details, see [`Pkg.instantiate`](@ref).

!!! note
    The `Manifest.toml` file is generated and maintained by Pkg and, in general, this file
    should *never* be modified manually.


### `Manifest.toml` entries

Each dependency has its own section in the manifest file, and its content varies depending
on how the dependency was added to the environment. Every
dependency section includes a combination of the following entries:

* `uuid`: the [UUID](https://en.wikipedia.org/wiki/Universally_unique_identifier)
  for the dependency, for example `uuid = "7876af07-990d-54b4-ab0e-23690620f79a"`.
* `deps`: a vector listing the dependencies of the dependency, for example
  `deps = ["Example", "JSON"]`.
* `version`: a version number, for example `version = "1.2.6"`.
* `path`: a file path to the source code, for example `path = /home/user/Example`.
* `repo-url`: a URL to the repository where the source code was found,
  for example `repo-url = "https://github.com/JuliaLang/Example.jl.git"`.
* `repo-rev`: a git revision, for example a branch `repo-rev = "master"`
  or a commit `repo-rev = "66607a62a83cb07ab18c0b35c038fcd62987c9b1"`.
* `git-tree-sha1`: a content hash of the source tree, for example
  `git-tree-sha1 = "ca3820cc4e66f473467d912c4b2b3ae5dc968444"`.


#### Added package

When a package is added from a package registry, for example by invoking `pkg> add Example`
or with a specific version `pkg> add Example@1.2`, the resulting `Manifest.toml` entry looks
like:

```toml
[[Example]]
deps = ["DependencyA", "DependencyB"]
git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.3"
```

Note, in particular, that no `repo-url` is present, since that information is included in
the registry where this package were found.

#### Added package by branch

The resulting dependency section when adding a package specified by a branch, e.g.
`pkg> add Example#master` or `pkg> add https://github.com/JuliaLang/Example.jl.git`,
looks like:

```toml
[[Example]]
deps = ["DependencyA", "DependencyB"]
git-tree-sha1 = "54c7a512469a38312a058ec9f429e1db1f074474"
repo-rev = "master"
repo-url = "https://github.com/JuliaLang/Example.jl.git"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.4"
```

Note that both the branch we are tracking (`master`) and the remote repository url
(`"https://github.com/JuliaLang/Example.jl.git"`) are stored in the manifest.

#### Added package by commit

The resulting dependency section when adding a package specified by a commit, e.g.
`pkg> add Example#cf6ba6cc0be0bb5f56840188563579d67048be34`, looks like:

```toml
[[Example]]
deps = ["DependencyA", "DependencyB"]
git-tree-sha1 = "54c7a512469a38312a058ec9f429e1db1f074474"
repo-rev = "cf6ba6cc0be0bb5f56840188563579d67048be34"
repo-url = "https://github.com/JuliaLang/Example.jl.git"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.4"
```

The only difference from tracking a branch is the content of `repo-rev`.

#### Developed package

The resulting dependency section when adding a package with `develop`,
e.g. `pkg> develop Example` or `pkg> develop /path/to/local/folder/Example`,
looks like:

```toml
[[Example]]
deps = ["DependencyA", "DependencyB"]
path = "/home/user/.julia/dev/Example/"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.4"
```

Note that the path to the source code is included, and changes made to that
source tree is directly reflected.

#### Pinned package

Pinned packages are also recorded in the manifest file; the resulting
dependency section for e.g. `pkg> add Example; pin Example` looks like:

```toml
[[Example]]
deps = ["DependencyA", "DependencyB"]
git-tree-sha1 = "54c7a512469a38312a058ec9f429e1db1f074474"
pinned = true
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.4"
```

The only difference is the addition of the `pinned = true` entry.

#### Multiple package with the same name

Julia differentiates packages based on UUID, which means that the name alone is not enough
to identify a package. It is possible to have multiple packages in the same environment
with the same name, but with different UUID. In such a situation the `Manifest.toml` file
looks a bit different. Consider for example the situation where you have added `A` and `B`
to your environment, and the `Project.toml` file looks as follows:

```toml
[deps]
A = "ead4f63c-334e-11e9-00e6-e7f0a5f21b60"
B = "edca9bc6-334e-11e9-3554-9595dbb4349c"
```

If `A` now depends on `B = "f41f7b98-334e-11e9-1257-49272045fb24"`, i.e. *another* package
named `B` there will be two different `B` packages in the `Manifest.toml` file. In this
case the full `Manifest.toml` file, with `git-tree-sha1` and `version` fields removed for
clarity, looks like:

```toml
[[A]]
uuid = "ead4f63c-334e-11e9-00e6-e7f0a5f21b60"

    [A.deps]
    B = "f41f7b98-334e-11e9-1257-49272045fb24"

[[B]]
uuid = "f41f7b98-334e-11e9-1257-49272045fb24"
[[B]]
uuid = "edca9bc6-334e-11e9-3554-9595dbb4349c"
```

There is now an array of the two `B` packages, and the `[deps]` section for `A` has been
expanded in order to be explicit about which `B` package `A` depends on.
