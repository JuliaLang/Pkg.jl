# **9.** Glossary

**Project:** a source tree with a standard layout, including a `src` directory
for the main body of Julia code, a `test` directory for testing the project,
`docs` for documentation files, and optionally a `deps` directory for a build
script and its outputs. A project will typically also have a project file and
may optionally have a manifest file:

- **Project file:** a file in the root directory of a project, named
  `Project.toml` (or `JuliaProject.toml`) describing metadata about the project,
  including its name, UUID (for packages), authors, license, and the names and
  UUIDs of packages and libraries that it depends on.

- **Manifest file:** a file in the root directory of a project, named
  `Manifest.toml` (or `JuliaManifest.toml`) describing a complete dependency graph
  and exact versions of each package and library used by a project.

**Package:** a project which provides reusable functionality that can be used by
other Julia projects via `import X` or `using X`. A package should have a
project file with a `uuid` entry giving its package UUID. This UUID is used to
identify the package in projects that depend on it.

!!! note
    For legacy reasons it is possible to load a package without a project file or
    UUID from the REPL or the top-level of a script. It is not possible, however,
    to load a package without a project file or UUID from a project with them. Once
    you've loaded from a project file, everything needs a project file and UUID.

**Application:** a project which provides standalone functionality not intended
to be reused by other Julia projects. For example a web application or a
commmand-line utility, or simulation/analytics code accompanying a scientific paper.
An application may have a UUID but does not need one.
An application may also provide global configuration options for packages it
depends on. Packages, on the other hand, may not provide global configuration
since that could conflict with the configuration of the main application.

!!! note
    **Projects _vs._ Packages _vs._ Applications:**

    1. **Project** is an umbrella term: packages and applications are kinds of projects.
    2. **Packages** should have UUIDs, applications can have a UUIDs but don't need them.
    3. **Applications** can provide global configuration, whereas packages cannot.

**Library (future work):** a compiled binary dependency (not written in Julia)
packaged to be used by a Julia project. These are currently typically built in-
place by a `deps/build.jl` script in a project’s source tree, but in the future
we plan to make libraries first-class entities directly installed and upgraded
by the package manager.

**Environment:** the combination of the top-level name map provided by a project
file combined with the dependency graph and map from packages to their entry points
provided by a manifest file. For more detail see the manual section on code loading.

- **Explicit environment:** an environment in the form of an explicit project
  file and an optional corresponding manifest file together in a directory. If the
  manifest file is absent then the implied dependency graph and location maps are
  empty.

- **Implicit environment:** an environment provided as a directory (without a
  project file or manifest file) containing packages with entry points of the form
  `X.jl`, `X.jl/src/X.jl` or `X/src/X.jl`. The top-level name map is implied by
  these entry points. The dependency graph is implied by the existence of project
  files inside of these package directories, e.g. `X.jl/Project.toml` or
  `X/Project.toml`. The dependencies of the `X` package are the dependencies in
  the corresponding project file if there is one. The location map is implied by
  the entry points themselves.

**Registry:** a source tree with a standard layout recording metadata about a
registered set of packages, the tagged versions of them which are available, and
which versions of packages are compatible or incompatible with each other. A
registry is indexed by package name and UUID, and has a directory for each
registered package providing the following metadata about it:

- name – e.g. `DataFrames`
- UUID – e.g. `a93c6f00-e57d-5684-b7b6-d8193f3e46c0`
- authors – e.g. `Jane Q. Developer <jane@example.com>`
- license – e.g. MIT, BSD3, or GPLv2
- repository – e.g. `https://github.com/JuliaData/DataFrames.jl.git`
- description – a block of text summarizing the functionality of a package
- keywords – e.g. `data`, `tabular`, `analysis`, `statistics`
- versions – a list of all registered version tags

For each registered version of a package, the following information is provided:

- its semantic version number – e.g. `v1.2.3`
- its git tree SHA-1 hash – e.g. `7ffb18ea3245ef98e368b02b81e8a86543a11103`
- a map from names to UUIDs of dependencies
- which versions of other packages it is compatible/incompatible with

Dependencies and compatibility are stored in a compressed but human-readable
format using ranges of package versions.

**Depot:** a directory on a system where various package-related resources live,
including:

- `environments`: shared named environments (e.g. `v1.0`, `devtools`)
- `clones`: bare clones of package repositories
- `compiled`: cached compiled package images (`.ji` files)
- `config`: global configuration files (e.g. `startup.jl`)
- `dev`: default directory for package development
- `logs`: log files (e.g. `manifest_usage.toml`, `repl_history.jl`)
- `packages`: installed package versions
- `registries`: clones of registries (e.g. `General`)

**Load path:** a stack of environments where package identities, their
dependencies, and entry-points are searched for. The load path is controlled in
Julia by the `LOAD_PATH` global variable which is populated at startup based on
the value of the `JULIA_LOAD_PATH` environment variable. The first entry is your
primary environment, often the current project, while later entries provide
additional packages one may want to use from the REPL or top-level scripts.

**Depot path:** a stack of depot locations where the package manager, as well as
Julia's code loading mechanisms, look for registries, installed packages, named
environments, repo clones, cached compiled package images, and configuration
files. The depot path is controlled by the Julia `DEPOT_PATH` global variable
which is populated at startup based on the value of the `JULIA_DEPOT_PATH`
environment variable. The first entry is the “user depot” and should be writable
by and owned by the current user. The user depot is where: registries are
cloned, new package versions are installed, named environments are created and
updated, package repos are cloned, newly compiled package image files are saved,
log files are written, development packages are checked out by default, and
global configuration data is saved. Later entries in the depot path are treated
as read-only and are appropriate for registries, packages, etc. installed and
managed by system administrators.
