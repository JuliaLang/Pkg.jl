# This file is a part of Julia. License is MIT: https://julialang.org/license

module Pkg

# In Pkg tests we want to avoid Pkg being re-precompiled by subprocesses, so this is enabled in the test suite
if Base.get_bool_env("JULIA_PKG_DISALLOW_PKG_PRECOMPILATION", false) == true
    error("Precompililing Pkg is disallowed. JULIA_PKG_DISALLOW_PKG_PRECOMPILATION=$(ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"])")
end

if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@max_methods"))
    @eval Base.Experimental.@max_methods 1
end

import Random
import TOML
using Dates

export @pkg_str
export PackageSpec
export PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT
export UpgradeLevel, UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH
export PreserveLevel, PRESERVE_TIERED_INSTALLED, PRESERVE_TIERED, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_NONE
export Registry, RegistrySpec

public activate, add, build, compat, develop, free, gc, generate, instantiate,
       pin, precompile, redo, rm, resolve, status, test, undo, update, why

depots() = Base.DEPOT_PATH
function depots1(depot_list::Union{String, Vector{String}}=depots())
    # Get the first depot from a list, with proper error handling
    if depot_list isa String
        return depot_list
    else
        isempty(depot_list) && Pkg.Types.pkgerror("no depots provided")
        return depot_list[1]
    end
end

function pkg_server()
    server = get(ENV, "JULIA_PKG_SERVER", "https://pkg.julialang.org")
    isempty(server) && return nothing
    startswith(server, r"\w+://") || (server = "https://$server")
    return rstrip(server, '/')
end

logdir(depot = depots1()) = joinpath(depot, "logs")
devdir(depot = depots1()) = get(ENV, "JULIA_PKG_DEVDIR", joinpath(depot, "dev"))
envdir(depot = depots1()) = joinpath(depot, "environments")
const UPDATED_REGISTRY_THIS_SESSION = Ref(false)
const OFFLINE_MODE = Ref(false)
const RESPECT_SYSIMAGE_VERSIONS = Ref(true)
# For globally overriding in e.g. tests
const DEFAULT_IO = Ref{Union{IO,Nothing}}(nothing)

# See discussion in https://github.com/JuliaLang/julia/pull/52249
function unstableio(@nospecialize(io::IO))
    # Needed to prevent specialization https://github.com/JuliaLang/julia/pull/52249#discussion_r1401199265
    _io = Base.inferencebarrier(io)
    IOContext{IO}(
        _io,
        get(_io,:color,false) ? Base.ImmutableDict{Symbol,Any}(:color, true) : Base.ImmutableDict{Symbol,Any}()
    )
end
stderr_f() = something(DEFAULT_IO[], unstableio(stderr))
stdout_f() = something(DEFAULT_IO[], unstableio(stdout))
const PREV_ENV_PATH = Ref{String}("")

usable_io(io) = (io isa Base.TTY) || (io isa IOContext{IO} && io.io isa Base.TTY)
can_fancyprint(io::IO) = (usable_io(io)) && (get(ENV, "CI", nothing) != "true")
should_autoprecompile() = Base.JLOptions().use_compiled_modules == 1 && Base.get_bool_env("JULIA_PKG_PRECOMPILE_AUTO", true)

include("utils.jl")
include("MiniProgressBars.jl")
include("GitTools.jl")
include("PlatformEngines.jl")
include("Versions.jl")
include("Registry/Registry.jl")
include("Resolve/Resolve.jl")
include("Types.jl")
include("BinaryPlatformsCompat.jl")
include("Artifacts.jl")
include("Operations.jl")
include("API.jl")
include("Apps/Apps.jl")
include("REPLMode/REPLMode.jl")

import .REPLMode: @pkg_str
import .Types: UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH, UPLEVEL_FIXED
import .Types: PKGMODE_MANIFEST, PKGMODE_PROJECT
import .Types: PRESERVE_TIERED_INSTALLED, PRESERVE_TIERED, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_NONE

# Import artifacts API
using .Artifacts, .PlatformEngines


"""
    PackageMode

An enum with the instances

  * `PKGMODE_MANIFEST`
  * `PKGMODE_PROJECT`

Determines if operations should be made on a project or manifest level.
Used as an argument to [`Pkg.rm`](@ref), [`Pkg.update`](@ref) and [`Pkg.status`](@ref).
"""
const PackageMode = Types.PackageMode


"""
    UpgradeLevel

An enum with the instances

  * `UPLEVEL_FIXED`
  * `UPLEVEL_PATCH`
  * `UPLEVEL_MINOR`
  * `UPLEVEL_MAJOR`

Determines how much a package is allowed to be updated.
Used as an argument to  [`PackageSpec`](@ref) or as an argument to [`Pkg.update`](@ref).
"""
const UpgradeLevel = Types.UpgradeLevel

const PreserveLevel = Types.PreserveLevel

# Define new variables so tab comleting Pkg. works.
"""
    Pkg.add(pkg::Union{String, Vector{String}}; preserve=PRESERVE_TIERED, target::Symbol=:deps)
    Pkg.add(pkg::Union{PackageSpec, Vector{PackageSpec}}; preserve=PRESERVE_TIERED, target::Symbol=:deps)

Add a package to the current project. This package will be available by using the
`import` and `using` keywords in the Julia REPL, and if the current project is
a package, also inside that package.

If the active environment is a package (the Project has both `name` and `uuid` fields) compat entries will be
added automatically with a lower bound of the added version.

To add as a weak dependency (in the `[weakdeps]` field) set the kwarg `target=:weakdeps`.
To add as an extra dep (in the `[extras]` field) set `target=:extras`.

## Resolution Tiers
`Pkg` resolves the set of packages in your environment using a tiered algorithm.
The `preserve` keyword argument allows you to key into a specific tier in the resolve algorithm.
The following table describes the argument values for `preserve` (in order of strictness):

| Value                       | Description                                                                        |
|:----------------------------|:-----------------------------------------------------------------------------------|
| `PRESERVE_ALL_INSTALLED`    | Like `PRESERVE_ALL` and only add those already installed                           |
| `PRESERVE_ALL`              | Preserve the state of all existing dependencies (including recursive dependencies) |
| `PRESERVE_DIRECT`           | Preserve the state of all existing direct dependencies                             |
| `PRESERVE_SEMVER`           | Preserve semver-compatible versions of direct dependencies                         |
| `PRESERVE_NONE`             | Do not attempt to preserve any version information                                 |
| `PRESERVE_TIERED_INSTALLED` | Like `PRESERVE_TIERED` except `PRESERVE_ALL_INSTALLED` is tried first              |
| `PRESERVE_TIERED`           | Use the tier that will preserve the most version information while                 |
|                             | allowing version resolution to succeed (this is the default)                       |

!!! note
    To change the default strategy to `PRESERVE_TIERED_INSTALLED` set the env var `JULIA_PKG_PRESERVE_TIERED_INSTALLED`
    to true.

After the installation of new packages the project will be precompiled. For more information see `pkg> ?precompile`.

With the `PRESERVE_ALL_INSTALLED` strategy the newly added packages will likely already be precompiled, but if not this
may be because either the combination of package versions resolved in this environment has not been resolved and
precompiled before, or the precompile cache has been deleted by the LRU cache storage
(see `JULIA_MAX_NUM_PRECOMPILE_FILES`).

!!! compat "Julia 1.9"
    The `PRESERVE_TIERED_INSTALLED` and `PRESERVE_ALL_INSTALLED` strategies requires at least Julia 1.9.

!!! compat "Julia 1.11"
    The `target` kwarg requires at least Julia 1.11.

# Examples
```julia
Pkg.add("Example") # Add a package from registry
Pkg.add("Example", target=:weakdeps) # Add a package as a weak dependency
Pkg.add("Example", target=:extras) # Add a package to the `[extras]` list
Pkg.add("Example"; preserve=Pkg.PRESERVE_ALL) # Add the `Example` package and strictly preserve existing dependencies
Pkg.add(name="Example", version="0.3") # Specify version; latest release in the 0.3 series
Pkg.add(name="Example", version="0.3.1") # Specify version; exact release
Pkg.add(url="https://github.com/JuliaLang/Example.jl", rev="master") # From url to remote gitrepo
Pkg.add(url="/remote/mycompany/juliapackages/OurPackage") # From path to local gitrepo
Pkg.add(url="https://github.com/Company/MonoRepo", subdir="juliapkgs/Package.jl)") # With subdir
```

After the installation of new packages the project will be precompiled. See more at [Environment Precompilation](@ref).

See also [`PackageSpec`](@ref), [`Pkg.develop`](@ref).
"""
const add = API.add

"""
    Pkg.precompile(; strict::Bool=false, timing::Bool=false)
    Pkg.precompile(pkg; strict::Bool=false, timing::Bool=false)
    Pkg.precompile(pkgs; strict::Bool=false, timing::Bool=false)

Precompile all or specific dependencies of the project in parallel.

Set `timing=true` to show the duration of the precompilation of each dependency.

!!! note
    Errors will only throw when precompiling the top-level dependencies, given that
    not all manifest dependencies may be loaded by the top-level dependencies on the given system.
    This can be overridden to make errors in all dependencies throw by setting the kwarg `strict` to `true`

!!! note
    This method is called automatically after any Pkg action that changes the manifest.
    Any packages that have previously errored during precompilation won't be retried in auto mode
    until they have changed. To disable automatic precompilation set `ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0`.
    To manually control the number of tasks used set `ENV["JULIA_NUM_PRECOMPILE_TASKS"]`.

!!! compat "Julia 1.8"
    Specifying packages to precompile requires at least Julia 1.8.

!!! compat "Julia 1.9"
    Timing mode requires at least Julia 1.9.

# Examples
```julia
Pkg.precompile()
Pkg.precompile("Foo")
Pkg.precompile(["Foo", "Bar"])
```
"""
const precompile = API.precompile

"""
    Pkg.rm(pkg::Union{String, Vector{String}}; mode::PackageMode = PKGMODE_PROJECT)
    Pkg.rm(pkg::Union{PackageSpec, Vector{PackageSpec}}; mode::PackageMode = PKGMODE_PROJECT)

Remove a package from the current project. If `mode` is equal to
`PKGMODE_MANIFEST` also remove it from the manifest including all
recursive dependencies of `pkg`.

See also [`PackageSpec`](@ref), [`PackageMode`](@ref).
"""
const rm = API.rm

"""
    Pkg.why(pkg::Union{String, Vector{String}}; workspace::Bool=false)
    Pkg.why(pkg::Union{PackageSpec, Vector{PackageSpec}}; workspace::Bool=false)

Show the reason why this package is in the manifest.
The output is all the different ways to reach the package
through the dependency graph starting from the dependencies.
If `workspace` is true, this will consider all projects in the workspace and not just the active one.

!!! compat "Julia 1.9"
    This function requires at least Julia 1.9.
"""
const why = API.why

"""
    Pkg.update(; level::UpgradeLevel=UPLEVEL_MAJOR, mode::PackageMode = PKGMODE_PROJECT, preserve::PreserveLevel)
    Pkg.update(pkg::Union{String, Vector{String}})
    Pkg.update(pkg::Union{PackageSpec, Vector{PackageSpec}})

If no positional argument is given, update all packages in the manifest if `mode` is `PKGMODE_MANIFEST` and packages in both manifest and project if `mode` is `PKGMODE_PROJECT`.
If no positional argument is given, `level` can be used to control by how much packages are allowed to be upgraded (major, minor, patch, fixed).

If packages are given as positional arguments, the `preserve` argument can be used to control what other packages are allowed to update:
- `PRESERVE_ALL` (default): Only allow `pkg` to update.
- `PRESERVE_DIRECT`: Only allow `pkg` and indirect dependencies that are not a direct dependency in the project to update.
- `PRESERVE_NONE`: Allow `pkg` and all its indirect dependencies to update.

After any package updates the project will be precompiled. See more at [Environment Precompilation](@ref).

See also [`PackageSpec`](@ref), [`PackageMode`](@ref), [`UpgradeLevel`](@ref).
"""
const update = API.up

"""
    Pkg.test(; kwargs...)
    Pkg.test(pkg::Union{String, Vector{String}; kwargs...)
    Pkg.test(pkgs::Union{PackageSpec, Vector{PackageSpec}}; kwargs...)

**Keyword arguments:**
  - `coverage::Union{Bool,String}=false`: enable or disable generation of coverage statistics for the tested package.
    If a string is passed it is passed directly to `--code-coverage` in the test process so e.g. "user" will test all user code.
  - `allow_reresolve::Bool=true`: allow Pkg to reresolve the package versions in the test environment
  - `julia_args::Union{Cmd, Vector{String}}`: options to be passed the test process.
  - `test_args::Union{Cmd, Vector{String}}`: test arguments (`ARGS`) available in the test process.

!!! compat "Julia 1.9"
    `allow_reresolve` requires at least Julia 1.9.

!!! compat "Julia 1.9"
    Passing a string to `coverage` requires at least Julia 1.9.

Run the tests for the given package(s), or for the current project if no positional argument is given to `Pkg.test`
(the current project would need to be a package). The package is tested by running its `test/runtests.jl` file.

The tests are run in a temporary environment that also includes the test specific dependencies
of the package. The versions of dependencies in the current project are used for the
test environment unless there is a compatibility conflict between the version of the dependencies and
the test-specific dependencies. In that case, if `allow_reresolve` is `false` an error is thrown and
if `allow_reresolve` is `true` a feasible set of versions of the dependencies is resolved and used.

Test-specific dependnecies are declared in the project file as:

```toml
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

The tests are executed in a new process with `check-bounds=yes` and by default `startup-file=no`.
If using the startup file (`~/.julia/config/startup.jl`) is desired, start julia with `--startup-file=yes`.

Inlining of functions during testing can be disabled (for better coverage accuracy)
by starting julia with `--inline=no`. The tests can be run as if different command line arguments were
passed to julia by passing the arguments instead to the `julia_args` keyword argument, e.g.

```julia
Pkg.test("foo"; julia_args=["--inline"])
```

To pass some command line arguments to be used in the tests themselves, pass the arguments to the
`test_args` keyword argument. These could be used to control the code being tested, or to control the
tests in some way. For example, the tests could have optional additional tests:
```julia
if "--extended" in ARGS
    @test some_function()
end
```
which could be enabled by testing with
```julia
Pkg.test("foo"; test_args=["--extended"])
```
"""
const test = API.test

"""
    Pkg.gc(; collect_delay::Period=Day(7), io::IO=stderr)

Garbage-collect package and artifact installations by sweeping over all known
`Manifest.toml` and `Artifacts.toml` files, noting those that have been deleted, and then
finding artifacts and packages that are thereafter not used by any other projects,
marking them as "orphaned".  This method will only remove orphaned objects (package
versions, artifacts, and scratch spaces) that have been continually un-used for a period
of `collect_delay`; which defaults to seven days.

To disable automatic garbage collection, you can set the environment variable
`JULIA_PKG_GC_AUTO` to `"false"` before starting Julia or call `API.auto_gc(false)`.
"""
const gc = API.gc


"""
    Pkg.build(; verbose = false, io::IO=stderr)
    Pkg.build(pkg::Union{String, Vector{String}}; verbose = false, io::IO=stderr)
    Pkg.build(pkgs::Union{PackageSpec, Vector{PackageSpec}}; verbose = false, io::IO=stderr)

Run the build script in `deps/build.jl` for `pkg` and all of its dependencies in
depth-first recursive order.
If no argument is given to `build`, the current project is built, which thus needs
to be a package.
This function is called automatically on any package that gets installed
for the first time.
`verbose = true` prints the build output to `stdout`/`stderr` instead of
redirecting to the `build.log` file.
"""
const build = API.build

"""
    Pkg.pin(pkg::Union{String, Vector{String}}; io::IO=stderr, all_pkgs::Bool=false)
    Pkg.pin(pkgs::Union{PackageSpec, Vector{PackageSpec}}; io::IO=stderr, all_pkgs::Bool=false)

Pin a package to the current version (or the one given in the `PackageSpec`) or to a certain
git revision. A pinned package is never automatically updated: if `pkg` is tracking a path,
or a repository, those remain tracked but will not update.
To get updates from the origin path or remote repository the package must first be freed.

!!! compat "Julia 1.7"
    The `all_pkgs` kwarg was introduced in julia 1.7.

# Examples
```julia
# Pin a package to its current version
Pkg.pin("Example")

# Pin a package to a specific version
Pkg.pin(name="Example", version="0.3.1")

# Pin all packages in the project
Pkg.pin(all_pkgs = true)
```
"""
const pin = API.pin

"""
    Pkg.free(pkg::Union{String, Vector{String}}; io::IO=stderr, all_pkgs::Bool=false)
    Pkg.free(pkgs::Union{PackageSpec, Vector{PackageSpec}}; io::IO=stderr, all_pkgs::Bool=false)

If `pkg` is pinned, remove the pin.
If `pkg` is tracking a path, e.g. after [`Pkg.develop`](@ref), go back to tracking registered versions.
To free all dependencies set `all_pkgs=true`.

!!! compat "Julia 1.7"
    The `all_pkgs` kwarg was introduced in julia 1.7.

# Examples
```julia
# Free a single package (remove pin or stop tracking path)
Pkg.free("Package")

# Free multiple packages
Pkg.free(["PackageA", "PackageB"])

# Free all packages in the project
Pkg.free(all_pkgs = true)
```


"""
const free = API.free


"""
    Pkg.develop(pkg::Union{String, Vector{String}}; io::IO=stderr, preserve=PRESERVE_TIERED, installed=false)
    Pkg.develop(pkgs::Union{PackageSpec, Vector{PackageSpec}}; io::IO=stderr, preserve=PRESERVE_TIERED, installed=false)

Make a package available for development by tracking it by path.
If `pkg` is given with only a name or by a URL, the package will be downloaded
to the location specified by the environment variable `JULIA_PKG_DEVDIR`, with
`joinpath(DEPOT_PATH[1],"dev")` being the default.

If `pkg` is given as a local path, the package at that path will be tracked.

The preserve strategies offered by `Pkg.add` are also available via the `preserve` kwarg.
See [`Pkg.add`](@ref) for more information.

# Examples
```julia
# By name
Pkg.develop("Example")

# By url
Pkg.develop(url="https://github.com/JuliaLang/Compat.jl")

# By path
Pkg.develop(path="MyJuliaPackages/Package.jl")
```

See also [`PackageSpec`](@ref), [`Pkg.add`](@ref).

"""
const develop = API.develop

"""
    Pkg.generate(pkgname::String)

Create a minimal project called `pkgname` in the current folder. For more featureful package creation, please see `PkgTemplates.jl`.
"""
const generate = API.generate

"""
    Pkg.dependencies()::Dict{UUID, PackageInfo}

This feature is considered experimental.

Query the dependency graph of the active project.
The result is a `Dict` that maps a package UUID to a `PackageInfo` struct representing the dependency (a package).

# `PackageInfo` fields

| Field                 | Description                                                                       |
|:------------------    |:----------------------------------------------------------------------------------|
| `name`                | The name of the package                                                           |
| `version`             | The version of the package (this is `Nothing` for stdlibs)                        |
| `tree_hash`           | A file hash of the package directory tree                                         |
| `is_direct_dep`       | The package is a direct dependency                                                |
| `is_pinned`           | Whether a package is pinned                                                       |
| `is_tracking_path`    | Whether a package is tracking a path                                              |
| `is_tracking_repo`    | Whether a package is tracking a repository                                        |
| `is_tracking_registry`| Whether a package is being tracked by registry i.e. not by path nor by repository |
| `git_revision`        | The git revision when tracking by repository                                      |
| `git_source`          | The git source when tracking by repository                                        |
| `source`              | The directory containing the source code for that package                         |
| `dependencies`        | The dependencies of that package as a vector of UUIDs                             |
"""
const dependencies = API.dependencies

"""
    Pkg.project()::ProjectInfo

This feature is considered experimental.

Request a `ProjectInfo` struct which contains information about the active project.

# `ProjectInfo` fields

| Field          | Description                                                                                 |
|:---------------|:--------------------------------------------------------------------------------------------|
| `name`         | The project's name                                                                          |
| `uuid`         | The project's UUID                                                                          |
| `version`      | The project's version                                                                       |
| `ispackage`    | Whether the project is a package (has a name and uuid)                                      |
| `dependencies` | The project's direct dependencies as a `Dict` which maps dependency name to dependency UUID |
| `path`         | The location of the project file which defines the active project                           |
"""
const project = API.project

"""
    Pkg.instantiate(; verbose = false, workspace=false, io::IO=stderr, julia_version_strict=false)

If a `Manifest.toml` file exists in the active project, download all
the packages declared in that manifest.
Otherwise, resolve a set of feasible packages from the `Project.toml` files
and install them.
`verbose = true` prints the build output to `stdout`/`stderr` instead of
redirecting to the `build.log` file.
`workspace=true` will also instantiate all projects in the workspace.
If no `Project.toml` exist in the current active project, create one with all the
dependencies in the manifest and instantiate the resulting project.
`julia_version_strict=true` will turn manifest version check failures into errors instead of logging warnings.

After packages have been installed the project will be precompiled.
See more at [Environment Precompilation](@ref).

!!! compat "Julia 1.12"
    The `julia_version_strict` keyword argument requires at least Julia 1.12.
"""
const instantiate = API.instantiate

"""
    Pkg.resolve(; io::IO=stderr)

Update the current manifest with potential changes to the dependency graph
from packages that are tracking a path.
"""
const resolve = API.resolve

"""
    Pkg.status([pkgs...]; outdated::Bool=false, mode::PackageMode=PKGMODE_PROJECT, diff::Bool=false,
               compat::Bool=false, extensions::Bool=false, workspace::Bool=false, io::IO=stdout)


Print out the status of the project/manifest.

Packages marked with `⌃` have new versions that can be installed, e.g. via [`Pkg.update`](@ref).
Those marked with `⌅` have new versions available, but cannot be installed due to compatibility conflicts with other packages. To see why, set the
keyword argument `outdated=true`.

Setting `outdated=true` will only show packages that are not on the latest version,
their maximum version and why they are not on the latest version (either due to other
packages holding them back due to compatibility constraints, or due to compatibility in the project file).
As an example, a status output like:
```julia-repl
julia> Pkg.status(; outdated=true)
Status `Manifest.toml`
⌃ [a8cc5b0e] Crayons v2.0.0 [<v3.0.0], (<v4.0.4)
⌅ [b8a86587] NearestNeighbors v0.4.8 (<v0.4.9) [compat]
⌅ [2ab3a3ac] LogExpFunctions v0.2.5 (<v0.3.0): SpecialFunctions
```

means that the latest version of Crayons is 4.0.4 but the latest version compatible
with the `[compat]` section in the current project is 3.0.0.
The latest version of NearestNeighbors is 0.4.9 but due to compat constrains in the project
it is held back to 0.4.8.
The latest version of LogExpFunctions is 0.3.0 but SpecialFunctions
is holding it back to 0.2.5.

If `mode` is `PKGMODE_PROJECT`, print out status only about the packages
that are in the project (explicitly added). If `mode` is `PKGMODE_MANIFEST`,
print status also about those in the manifest (recursive dependencies). If there are
any packages listed as arguments, the output will be limited to those packages.

Setting `ext=true` will show dependencies with extensions and what extension dependencies
of those that are currently loaded.

Setting `diff=true` will, if the environment is in a git repository, limit
the output to the difference as compared to the last git commit.

Setting `workspace=true` will show the (merged) status of packages
in the workspace.

See [`Pkg.project`](@ref) and [`Pkg.dependencies`](@ref) to get the project/manifest
status as a Julia object instead of printing it.

!!! compat "Julia 1.8"
    The `⌃` and `⌅` indicators were added in Julia 1.8.
    The `outdated` keyword argument requires at least Julia 1.8.

"""
const status = API.status

"""
    Pkg.compat()

Interactively edit the [compat] entries within the current Project.

    Pkg.compat(pkg::String, compat::String)

Set the [compat] string for the given package within the current Project.

See [Compatibility](@ref) for more information on the project [compat] section.
"""
const compat = API.compat

"""
    Pkg.activate([s::String]; shared::Bool=false, io::IO=stderr)
    Pkg.activate(; temp::Bool=false, shared::Bool=false, io::IO=stderr)

Activate the environment at `s`. The active environment is the environment
that is modified by executing package commands.
The logic for what path is activated is as follows:

  * If `shared` is `true`, the first existing environment named `s` from the depots
    in the depot stack will be activated. If no such environment exists,
    create and activate that environment in the first depot.
  * If `temp` is `true` this will create and activate a temporary environment which will
    be deleted when the julia process is exited.
  * If `s` is an existing path, then activate the environment at that path.
  * If `s` is a package in the current project and `s` is tracking a path, then
    activate the environment at the tracked path.
  * Otherwise, `s` is interpreted as a non-existing path, which is then activated.

If no argument is given to `activate`, then use the first project found in `LOAD_PATH`
(ignoring `"@"`). For the default value of `LOAD_PATH`, the result is to activate the
`@v#.#` environment.

# Examples
```julia
Pkg.activate()
Pkg.activate("local/path")
Pkg.activate("MyDependency")
Pkg.activate(; temp=true)
```

See also [`LOAD_PATH`](https://docs.julialang.org/en/v1/base/constants/#Base.LOAD_PATH).
"""
const activate = API.activate

"""
    Pkg.offline(b::Bool=true)

Enable (`b=true`) or disable (`b=false`) offline mode.

In offline mode Pkg tries to do as much as possible without connecting
to internet. For example, when adding a package Pkg only considers
versions that are already downloaded in version resolution.

To work in offline mode across Julia sessions you can set the environment
variable `JULIA_PKG_OFFLINE` to `"true"` before starting Julia.
"""
offline(b::Bool=true) = (OFFLINE_MODE[] = b; nothing)

"""
    Pkg.respect_sysimage_versions(b::Bool=true)

Enable (`b=true`) or disable (`b=false`) respecting versions that are in the
sysimage (enabled by default).

If this option is enabled, Pkg will only install packages that have been put into the sysimage
(e.g. via PackageCompiler) at the version of the package in the sysimage.
Also, trying to add a package at a URL or `develop` a package that is in the sysimage
will error.
"""
respect_sysimage_versions(b::Bool=true) = (RESPECT_SYSIMAGE_VERSIONS[] = b; nothing)

"""
    PackageSpec(name::String, [uuid::UUID, version::VersionNumber])
    PackageSpec(; name, url, path, subdir, rev, version, mode, level)

A `PackageSpec` is a representation of a package with various metadata.
This includes:

  * The `name` of the package.
  * The package's unique `uuid`.
  * A `version` (for example when adding a package). When upgrading, can also be an instance of
    the enum [`UpgradeLevel`](@ref). If the version is given as a `String` this means that unspecified versions
    are "free", for example `version="0.5"` allows any version `0.5.x` to be installed. If given as a `VersionNumber`,
    the exact version is used, for example `version=v"0.5.3"`.
  * A `url` and an optional git `rev`ision. `rev` can be a branch name or a git commit SHA1.
  * A local `path`. This is equivalent to using the `url` argument but can be more descriptive.
  * A `subdir` which can be used when adding a package that is not in the root of a repository.

Most functions in Pkg take a `Vector` of `PackageSpec` and do the operation on all the packages
in the vector.

Many functions that take a `PackageSpec` or a `Vector{PackageSpec}` can be called with a more concise notation with `NamedTuple`s.
For example, `Pkg.add` can be called either as the explicit or concise versions as:

| Explicit                                                            | Concise                                        |
|:--------------------------------------------------------------------|:-----------------------------------------------|
| `Pkg.add(PackageSpec(name="Package"))`                              | `Pkg.add(name = "Package")`                    |
| `Pkg.add(PackageSpec(url="www.myhost.com/MyPkg")))`                 | `Pkg.add(url="www.myhost.com/MyPkg")`                    |
|` Pkg.add([PackageSpec(name="Package"), PackageSpec(path="/MyPkg"])` | `Pkg.add([(;name="Package"), (;path="/MyPkg")])`|

Below is a comparison between the REPL mode and the functional API:

| `REPL`               | `API`                                                 |
|:---------------------|:------------------------------------------------------|
| `Package`            | `PackageSpec("Package")`                              |
| `Package@0.2`        | `PackageSpec(name="Package", version="0.2")`          |
| -                    | `PackageSpec(name="Package", version=v"0.2.1")`       |
| `Package=a67d...`    | `PackageSpec(name="Package", uuid="a67d...")`         |
| `Package#master`     | `PackageSpec(name="Package", rev="master")`           |
| `local/path#feature` | `PackageSpec(path="local/path"; rev="feature")`       |
| `www.mypkg.com`      | `PackageSpec(url="www.mypkg.com")`                    |
| `--major Package`    | `PackageSpec(name="Package", version=UPLEVEL_MAJOR)` |

"""
const PackageSpec = Types.PackageSpec

"""
    setprotocol!(;
        domain::AbstractString = "github.com",
        protocol::Union{Nothing, AbstractString}=nothing
    )

Set the protocol used to access hosted packages when `add`ing a url or `develop`ing a package.
Defaults to delegating the choice to the package developer (`protocol === nothing`).
Other choices for `protocol` are `"https"` or `"git"`.

# Examples
```julia-repl
julia> Pkg.setprotocol!(domain = "github.com", protocol = "ssh")

# Use HTTPS for GitHub (default, good for most users)  
julia> Pkg.setprotocol!(domain = "github.com", protocol = "https")

# Reset to default (let package developer decide)
julia> Pkg.setprotocol!(domain = "github.com", protocol = nothing)

# Set protocol for custom domain without specifying protocol
julia> Pkg.setprotocol!(domain = "gitlab.mycompany.com")

# Use Git protocol for a custom domain
julia> Pkg.setprotocol!(domain = "gitlab.mycompany.com", protocol = "git")
```
"""
const setprotocol! = API.setprotocol!

"""
    undo()

Undoes the latest change to the active project. Only states in the current session are stored,
up to a maximum of $(API.max_undo_limit) states.

See also: [`redo`](@ref).
"""
const undo = API.undo

"""
    redo()

Redoes the changes from the latest [`undo`](@ref).
"""
const redo = API.redo

"""
    RegistrySpec(name::String)
    RegistrySpec(; name, uuid, url, path)

A `RegistrySpec` is a representation of a registry with various metadata, much like
[`PackageSpec`](@ref).
This includes:

  * The `name` of the registry.
  * The registry's unique `uuid`.
  * The `url` to the registry.
  * A local `path`.

Most registry functions in Pkg take a `Vector` of `RegistrySpec` and do the operation
on all the registries in the vector.

Many functions that take a `RegistrySpec` can be called with a more concise notation with keyword arguments.
For example, `Pkg.Registry.add` can be called either as the explicit or concise versions as:

| Explicit                                                            | Concise                                        |
|:--------------------------------------------------------------------|:-----------------------------------------------|
| `Pkg.Registry.add(RegistrySpec(name="General"))`                                        | `Pkg.Registry.add(name = "General")`                                      |
| `Pkg.Registry.add(RegistrySpec(url="https://github.com/JuliaRegistries/General.git")))` | `Pkg.Registry.add(url = "https://github.com/JuliaRegistries/General.git")`|

Below is a comparison between the REPL mode and the functional API::

| `REPL`               | `API`                                             |
|:---------------------|:--------------------------------------------------|
| `MyRegistry`         | `RegistrySpec("MyRegistry")`                      |
| `MyRegistry=a67d...` | `RegistrySpec(name="MyRegistry", uuid="a67d...")` |
| `local/path`         | `RegistrySpec(path="local/path")`                 |
| `www.myregistry.com` | `RegistrySpec(url="www.myregistry.com")`          |
"""
const RegistrySpec = Registry.RegistrySpec

"""
    upgrade_manifest()
    upgrade_manifest(manifest_path::String)

Upgrades the format of the current or specified manifest file from v1.0 to v2.0 without re-resolving.
"""
const upgrade_manifest = API.upgrade_manifest

"""
    is_manifest_current(path::AbstractString)

Returns whether the manifest for the project at `path` was resolved from the current project file.
For instance, if the project had compat entries changed, but the manifest wasn't re-resolved, this would return false.

If the manifest doesn't have the project hash recorded, or if there is no manifest file, `nothing` is returned.

This function can be used in tests to verify that the manifest is synchronized with the project file:

```julia
using Pkg, Test
@test Pkg.is_manifest_current(pwd())  # Check current project
@test Pkg.is_manifest_current("/path/to/project")  # Check specific project
```
"""
const is_manifest_current = API.is_manifest_current

function __init__()
    if !isassigned(Base.PKG_PRECOMPILE_HOOK)
        # allows Base to use Pkg.precompile during loading
        # disable via `Base.PKG_PRECOMPILE_HOOK[] = Returns(nothing)`
        Base.PKG_PRECOMPILE_HOOK[] = precompile
    end
    OFFLINE_MODE[] = Base.get_bool_env("JULIA_PKG_OFFLINE", false)
    _auto_gc_enabled[] = Base.get_bool_env("JULIA_PKG_GC_AUTO", true)
    return nothing
end

################
# Deprecations #
################

function installed()
    @warn "`Pkg.installed()` is deprecated. Use `Pkg.dependencies()` instead." maxlog=1
    deps = dependencies()
    installs = Dict{String, VersionNumber}()
    for (uuid, dep) in deps
        dep.is_direct_dep || continue
        dep.version === nothing && continue
        installs[dep.name] = dep.version::VersionNumber
    end
    return installs
end

function dir(pkg::String, paths::AbstractString...)
    @warn "`Pkg.dir(pkgname, paths...)` is deprecated; instead, do `import $pkg; joinpath(dirname(pathof($pkg)), \"..\", paths...)`." maxlog=1
    pkgid = Base.identify_package(pkg)
    pkgid === nothing && return nothing
    path = Base.locate_package(pkgid)
    path === nothing && return nothing
    return abspath(path, "..", "..", paths...)
end

###########
# AUTO GC #
###########

const DEPOT_ORPHANAGE_TIMESTAMPS = Dict{String,Float64}()
const _auto_gc_enabled = Ref{Bool}(true)
function _auto_gc(ctx::Types.Context; collect_delay::Period = Day(7))
    if !_auto_gc_enabled[]
        return
    end

    # If we don't know the last time this depot was GC'ed (because this is the
    # first time we've looked this session), or it looks like we might want to
    # collect; let's go ahead and hit the filesystem to find the mtime of the
    # `orphaned.toml` file, which should tell us how long since the last time
    # we GC'ed.
    orphanage_path = joinpath(logdir(depots1()), "orphaned.toml")
    delay_secs = Second(collect_delay).value
    curr_time = time()
    if curr_time - get(DEPOT_ORPHANAGE_TIMESTAMPS, depots1(), 0.0) >= delay_secs
        DEPOT_ORPHANAGE_TIMESTAMPS[depots1()] = mtime(orphanage_path)
    end

    if curr_time - DEPOT_ORPHANAGE_TIMESTAMPS[depots1()] > delay_secs
        printpkgstyle(ctx.io, :Info, "We haven't cleaned this depot up for a bit, running Pkg.gc()...", color = Base.info_color())
        try
            Pkg.gc(ctx; collect_delay)
            DEPOT_ORPHANAGE_TIMESTAMPS[depots1()] = curr_time
        catch ex
            @error("GC failed", exception=ex)
        end
    end
end


##################
# Precompilation #
##################

function _auto_precompile(ctx::Types.Context, pkgs::Vector{PackageSpec}=PackageSpec[]; warn_loaded = true, already_instantiated = false)
    if should_autoprecompile()
        Pkg.precompile(ctx, pkgs; internal_call=true, warn_loaded = warn_loaded, already_instantiated = already_instantiated)
    end
end

include("precompile.jl")

# Reset globals that might have been mutated during precompilation.
DEFAULT_IO[] = nothing
Pkg.UPDATED_REGISTRY_THIS_SESSION[] = false
PREV_ENV_PATH[] = ""
Types.STDLIB[] = nothing

end # module
