# [**11.** `Project.toml` and `Manifest.toml`](@id Project-and-Manifest)

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

The project file describes the project on a high level, for example, the package/project
dependencies and compatibility constraints are listed in the project file. The file entries
are described below.


### The `authors` field

For a package, the optional `authors` field is a TOML array describing the package authors.
Entries in the array can either be a string in the form `"NAME"` or `"NAME <EMAIL>"`, or a table keys following the [Citation File Format schema](https://github.com/citation-file-format/citation-file-format/blob/main/schema-guide.md) for either a
[`person`](https://github.com/citation-file-format/citation-file-format/blob/main/schema-guide.md#definitionsperson) or an [`entity`](https://github.com/citation-file-format/citation-file-format/blob/main/schema-guide.md#definitionsentity).

For example:
```toml
authors = [
  "Some One <someone@email.com>",
  "Foo Bar <foo@bar.com>",
  {given-names = "Baz", family-names = "Qux", email = "bazqux@example.com", orcid = "https://orcid.org/0000-0000-0000-0000", website = "https://github.com/bazqux"},
]
```

If all authors are specified by tables, it is possible to use [the TOML Array of Tables syntax](https://toml.io/en/v1.0.0#array-of-tables)
```toml
[[authors]]
given-names = "Some"
family-names = "One"
email = "someone@email.com"

[[authors]]
given-names = "Foo"
family-names = "Bar"
email = "foo@bar.com"

[[authors]]
given-names = "Baz"
family-names = "Qux"
email = "bazqux@example.com"
orcid = "https://orcid.org/0000-0000-0000-0000"
website = "https://github.com/bazqux"
```

### The `name` field

The name of the package/project is determined by the `name` field, for example:
```toml
name = "Example"
```
The name must be a valid [identifier](https://docs.julialang.org/en/v1/base/base/#Base.isidentifier)
(a sequence of Unicode characters that does not start with a number and is neither `true` nor `false`).
For packages, it is recommended to follow the
[package naming rules](@ref Package-naming-guidelines). The `name` field is mandatory
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

#### Why UUIDs are important

UUIDs serve several critical purposes in the Julia package ecosystem:

- **Unique identification**: UUIDs uniquely identify packages across all registries and repositories, preventing naming conflicts. Two different packages can have the same name (e.g., in different registries), but their UUIDs will always be different.
- **Multiple registries**: UUIDs enable the use of multiple package registries (including private registries) without conflicts, as each package is uniquely identified by its UUID regardless of which registry it comes from.


### The `version` field

`version` is a string with the version number for the package/project. It should consist of
three numbers, major version, minor version, and patch number, separated with a `.`, for example:
```toml
version = "1.2.5"
```
Julia uses [Semantic Versioning](https://semver.org/) (SemVer) and the `version` field
should follow SemVer. The basic rules are:
* Before 1.0.0, anything goes, but when you make breaking changes the minor version should
  be incremented.
* After 1.0.0 only make breaking changes when incrementing the major version.
* After 1.0.0 no new public API should be added without incrementing the minor version.
  This includes, in particular, new types, functions, methods, and method overloads, from
  `Base` or other packages.
See also the section on [Compatibility](@ref).

Note that Pkg.jl deviates from the SemVer specification when it comes to versions pre-1.0.0. See
the section on [pre-1.0 behavior](@ref compat-pre-1.0) for more details.


### The `readonly` field

The `readonly` field is a boolean that, when set to `true`, marks the environment as read-only. This prevents any modifications to the environment, including adding, removing, or updating packages. For example:

```toml
readonly = true
```

When an environment is marked as readonly, Pkg will throw an error if any operation that would modify the environment is attempted.
If the `readonly` field is not present or set to `false` (the default), the environment can be modified normally.

You can also programmatically check and modify the readonly state using the [`Pkg.readonly`](@ref) function:

```julia
# Check if current environment is readonly
is_readonly = Pkg.readonly()

# Enable readonly mode
previous_state = Pkg.readonly(true)

# Disable readonly mode
Pkg.readonly(false)
```

When readonly mode is enabled, the status display will show `(readonly)` next to the project name to indicate the environment is protected from modifications.


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

### The `[sources]` section

Specifying a path or repo (+ branch) for a dependency is done in the `[sources]` section.
These are especially useful for controlling unregistered dependencies without having to bundle a
corresponding manifest file.

Each entry in the `[sources]` section supports the following keys:

- **`url`**: The URL of the Git repository. Cannot be used with `path`.
- **`rev`**: The Git revision (branch name, tag, or commit hash) to use. Only valid with `url`.
- **`subdir`**: A subdirectory within the repository containing the package.
- **`path`**: A local filesystem path to the package. Cannot be used with `url` or `rev`. This will `dev` the package.

This might in practice look something like:

```toml
[sources]
Example = {url = "https://github.com/JuliaLang/Example.jl", rev = "custom_branch"}
WithinMonorepo = {url = "https://github.org/author/BigProject", subdir = "SubPackage"}
SomeDependency = {path = "deps/SomeDependency.jl"}
```

Note that this information is only used when this environment is active, i.e. it is not used if this project is a package that is being used as a dependency.

!!! tip "Test-specific dependencies"
    A use case for `[sources]` with `path` is in `test/Project.toml` to reference the parent package using `path = ".."`. This allows test dependencies to be managed independently with their own manifest file. See [Test-specific dependencies](@ref) for more details on this and other approaches.

### The `[weakdeps]` section

Weak dependencies are optional dependencies that will not automatically install when the package is installed,
but for which you can still specify compatibility constraints. Weak dependencies are typically used in conjunction
with package extensions (see [`[extensions]`](@ref extensions-section) below), which allow conditional loading of code
when the weak dependency is available in the environment.

Example:
```toml
[weakdeps]
SomePackage = "b3785f31-9d33-4cdf-bc73-f646780f1739"

[compat]
SomePackage = "1.2"
```

For more details on using weak dependencies and extensions, see the
[Weak dependencies](@ref Weak-dependencies) section in the Creating Packages guide.

!!! compat
    Weak dependencies require Julia 1.9+.

### [The `[extensions]` section](@id extensions-section)

Extensions allow packages to provide optional functionality that is only loaded when certain other packages
(typically listed in `[weakdeps]`) are available. Each entry in the `[extensions]` section maps an extension
name to one or more package dependencies required to load that extension.

Example:
```toml
[weakdeps]
Contour = "d38c429a-6771-53c6-b99e-75d170b6e991"

[extensions]
ContourExt = "Contour"
```

The extension code itself should be placed in an `ext/` directory at the package root, with the file name
matching the extension name (e.g., `ext/ContourExt.jl`). For more details on creating and using extensions,
see the [Conditional loading of code in packages (Extensions)](@ref Conditional-loading-of-code-in-packages-(Extensions)) section in the Creating Packages guide.

!!! compat
    Extensions require Julia 1.9+.

### The `[compat]` section

Compatibility constraints for dependencies can be listed in the `[compat]` section. This applies to
packages listed under `[deps]`, `[weakdeps]`, and `[extras]`.

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

### [The `[workspace]` section](@id Workspaces)

A project file can define a workspace by giving a set of projects that is part of that workspace.
Each project in a workspace can include their own dependencies, compatibility information, and even function as full packages.

When the package manager resolves dependencies, it considers the requirements of all the projects in the workspace. The compatible versions identified during this process are recorded in a single manifest file located next to the base project file.

A workspace is defined in the base project by giving a list of the projects in it:

```toml
[workspace]
projects = ["test", "docs", "benchmarks", "PrivatePackage"]
```

This structure is particularly beneficial for developers using a monorepo approach, where a large number of unregistered packages may be involved. It's also useful for adding test-specific dependencies to a package by including a `test` project in the workspace (see [Test-specific dependencies](@ref adding-tests-to-packages)), or for adding documentation or benchmarks with their own dependencies.

Workspace can be nested: a project that itself defines a workspace can also be part of another workspace.
In this case, the workspaces are "merged" with a single manifest being stored alongside the "root project" (the project that doesn't have another workspace including it).

### The `[extras]` section (legacy)

!!! warning
    The `[extras]` section is a legacy feature maintained for compatibility. For Julia 1.13+,
    using [workspaces](@ref Workspaces) is the recommended approach for managing test-specific
    and other optional dependencies.

The `[extras]` section lists additional dependencies that are not regular dependencies of the package,
but may be used in specific contexts like testing. These are typically used in conjunction with the
`[targets]` section.

Example:
```toml
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
Markdown = "d6f4376e-aef5-505a-96c1-9c027394607a"
```

For more information, see the [Test-specific dependencies](@ref adding-tests-to-packages) section.

### The `[targets]` section (legacy)

!!! warning
    The `[targets]` section is a legacy feature maintained for compatibility. For Julia 1.13+,
    using [workspaces](@ref Workspaces) is the recommended approach for managing test-specific
    and build dependencies.

The `[targets]` section specifies which packages from `[extras]` should be available in specific
contexts. The only supported targets are `test` (for test dependencies) and `build` (for build-time
dependencies used by `deps/build.jl` scripts).

Example:
```toml
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
Markdown = "d6f4376e-aef5-505a-96c1-9c027394607a"

[targets]
test = ["Test", "Markdown"]
```

For more information, see the [Test-specific dependencies](@ref adding-tests-to-packages) section.

## `Manifest.toml`

The manifest file is an absolute record of the state of the packages in the environment.
It includes exact information about (direct and indirect) dependencies of the project.
Given a `Project.toml` + `Manifest.toml` pair, it is possible to instantiate the exact same
package environment, which is very useful for reproducibility.
For the details, see [`Pkg.instantiate`](@ref).

!!! note
    The `Manifest.toml` file is generated and maintained by Pkg and, in general, this file
    should *never* be modified manually.

### Different Manifests for Different Julia versions

Starting from Julia v1.10.8, there is an option to name manifest files in the format `Manifest-v{major}.{minor}.toml`.
Julia will then preferentially use the version-specific manifest file if available.
For example, if both `Manifest-v1.11.toml` and `Manifest.toml` exist, Julia 1.11 will prioritize using `Manifest-v1.11.toml`.
However, Julia versions 1.10, 1.12, and all others will default to using `Manifest.toml`.
This feature allows for easier management of different instantiated versions of dependencies for various Julia versions.
Note that there can only be one `Project.toml` file. While `Manifest-v{major}.{minor}.toml` files are not automatically
created by Pkg, users can manually rename a `Manifest.toml` file to match
the versioned format, and Pkg will subsequently maintain it through its operations.


### `Manifest.toml` entries

There are three top-level entries in the manifest which could look like this:

```toml
julia_version = "1.8.2"
manifest_format = "2.0"
project_hash = "4d9d5b552a1236d3c1171abf88d59da3aaac328a"
```

This shows the Julia version the manifest was created on, the "format" of the manifest
and a hash of the project file, so that it is possible to see when the manifest is stale
compared to the project file.

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
[[deps.Example]]
deps = ["DependencyA", "DependencyB"]
git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.3"
```

Note, in particular, that no `repo-url` is present, since that information is included in
the registry where this package was found.

#### Added package by branch

The resulting dependency section when adding a package specified by a branch, e.g.
`pkg> add Example#master` or `pkg> add https://github.com/JuliaLang/Example.jl.git`,
looks like:

```toml
[[deps.Example]]
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
[[deps.Example]]
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
[[deps.Example]]
deps = ["DependencyA", "DependencyB"]
path = "/home/user/.julia/dev/Example/"
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.4"
```

Note that the path to the source code is included, and changes made to that
source tree is directly reflected.

#### Pinned package

Pinned packages are also recorded in the manifest file; the resulting
dependency section e.g. `pkg> add Example; pin Example` looks like:

```toml
[[deps.Example]]
deps = ["DependencyA", "DependencyB"]
git-tree-sha1 = "54c7a512469a38312a058ec9f429e1db1f074474"
pinned = true
uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
version = "1.2.4"
```

The only difference is the addition of the `pinned = true` entry.

#### Multiple packages with the same name

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
case, the full `Manifest.toml` file, with `git-tree-sha1` and `version` fields removed for
clarity, looks like this:

```toml
[[deps.A]]
uuid = "ead4f63c-334e-11e9-00e6-e7f0a5f21b60"

    [deps.A.deps]
    B = "f41f7b98-334e-11e9-1257-49272045fb24"

[[deps.B]]
uuid = "f41f7b98-334e-11e9-1257-49272045fb24"
[[deps.B]]
uuid = "edca9bc6-334e-11e9-3554-9595dbb4349c"
```

There is now an array of the two `B` packages, and the `[deps]` section for `A` has been
expanded to be explicit about which `B` package `A` depends on.
