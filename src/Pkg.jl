# This file is a part of Julia. License is MIT: https://julialang.org/license

module Pkg

import Random
import REPL
import TOML
using Dates

export @pkg_str
export PackageSpec
export PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT
export UpgradeLevel, UPLEVEL_MAJOR, UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH
export PreserveLevel, PRESERVE_TIERED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_NONE
export Registry, RegistrySpec

depots() = Base.DEPOT_PATH
function depots1()
    d = depots()
    isempty(d) && Pkg.Types.pkgerror("no depots found in DEPOT_PATH")
    return d[1]
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
stderr_f() = something(DEFAULT_IO[], stderr)
stdout_f() = something(DEFAULT_IO[], stdout)
const PREV_ENV_PATH = Ref{String}("")

can_fancyprint(io::IO) = (io isa Base.TTY) && (get(ENV, "CI", nothing) != "true")

include("../ext/LazilyInitializedFields/LazilyInitializedFields.jl")

include("utils.jl")
include("MiniProgressBars.jl")
include("GitTools.jl")
include("PlatformEngines.jl")
include("Versions.jl")
include("Registry/Registry.jl")
include("Resolve/Resolve.jl")
include("Types.jl")
include("BinaryPlatforms_compat.jl")
include("Artifacts.jl")
include("Operations.jl")
include("API.jl")
include("REPLMode/REPLMode.jl")

import .REPLMode: @pkg_str
import .Types: UPLEVEL_MAJOR, UPLEVEL_MINOR, UPLEVEL_PATCH, UPLEVEL_FIXED
import .Types: PKGMODE_MANIFEST, PKGMODE_PROJECT
import .Types: PRESERVE_TIERED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_NONE

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
    Pkg.add(pkg::Union{String, Vector{String}}; preserve=PRESERVE_TIERED)
    Pkg.add(pkg::Union{PackageSpec, Vector{PackageSpec}}; preserve=PRESERVE_TIERED)

Add a package to the current project. This package will be available by using the
`import` and `using` keywords in the Julia REPL, and if the current project is
a package, also inside that package.

## Resolution Tiers
`Pkg` resolves the set of packages in your environment using a tiered algorithm.
The `preserve` keyword argument allows you to key into a specific tier in the resolve algorithm.
The following table describes the argument values for `preserve` (in order of strictness):

| Value             | Description                                                                         |
|:------------------|:------------------------------------------------------------------------------------|
| `PRESERVE_ALL`    | Preserve the state of all existing dependencies (including recursive dependencies)  |
| `PRESERVE_DIRECT` | Preserve the state of all existing direct dependencies                              |
| `PRESERVE_SEMVER` | Preserve semver-compatible versions of direct dependencies                          |
| `PRESERVE_NONE`   | Do not attempt to preserve any version information                                  |
| `PRESERVE_TIERED` | Use the tier which will preserve the most version information (this is the default) |

# Examples
```julia
Pkg.add("Example") # Add a package from registry
Pkg.add("Example"; preserve=Pkg.PRESERVE_ALL) # Add the `Example` package and preserve existing dependencies
Pkg.add(name="Example", version="0.3") # Specify version; latest release in the 0.3 series
Pkg.add(name="Example", version="0.3.1") # Specify version; exact release
Pkg.add(url="https://github.com/JuliaLang/Example.jl", rev="master") # From url to remote gitrepo
Pkg.add(url="/remote/mycompany/juliapackages/OurPackage") # From path to local gitrepo
Pkg.add(url="https://github.com/Company/MonoRepo", subdir="juliapkgs/Package.jl)") # With subdir
```

After the installation of new packages the project will be precompiled. See more at [Project Precompilation](@ref).

See also [`PackageSpec`](@ref), [`Pkg.develop`](@ref).
"""
const add = API.add

"""
    Pkg.precompile(; strict::Bool=false)
    Pkg.precompile(pkg; strict::Bool=false)
    Pkg.precompile(pkgs; strict::Bool=false)

Precompile all or specific dependencies of the project in parallel.
!!! note
    Errors will only throw when precompiling the top-level dependencies, given that
    not all manifest dependencies may be loaded by the top-level dependencies on the given system.
    This can be overridden to make errors in all dependencies throw by setting the kwarg `strict` to `true`

!!! note
    This method is called automatically after any Pkg action that changes the manifest.
    Any packages that have previously errored during precompilation won't be retried in auto mode
    until they have changed. To disable automatic precompilation set `ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0`.
    To manually control the number of tasks used set `ENV["JULIA_NUM_PRECOMPILE_TASKS"]`.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3. On earlier versions
    you can use `Pkg.API.precompile()` or the `precompile` Pkg REPL command.

!!! compat "Julia 1.8"
    Specifying packages to precompile requires at least Julia 1.8.

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
    Pkg.update(; level::UpgradeLevel=UPLEVEL_MAJOR, mode::PackageMode = PKGMODE_PROJECT)
    Pkg.update(pkg::Union{String, Vector{String}})
    Pkg.update(pkg::Union{PackageSpec, Vector{PackageSpec}})

Update a package `pkg`. If no posistional argument is given, update all packages in the manifest if `mode` is `PKGMODE_MANIFEST` and packages in both manifest and project if `mode` is `PKGMODE_PROJECT`.
If no positional argument is given, `level` can be used to control by how much packages are allowed to be upgraded (major, minor, patch, fixed).

After any package updates the project will be precompiled. See more at [Project Precompilation](@ref).

See also [`PackageSpec`](@ref), [`PackageMode`](@ref), [`UpgradeLevel`](@ref).
"""
const update = API.up

"""
    Pkg.test(; kwargs...)
    Pkg.test(pkg::Union{String, Vector{String}; kwargs...)
    Pkg.test(pkgs::Union{PackageSpec, Vector{PackageSpec}}; kwargs...)

**Keyword arguments:**
  - `coverage::Bool=false`: enable or disable generation of coverage statistics.
  - `allow_reresolve::Bool=true`: allow Pkg to reresolve the package versions in the test environment
  - `julia_args::Union{Cmd, Vector{String}}`: options to be passed the test process.
  - `test_args::Union{Cmd, Vector{String}}`: test arguments (`ARGS`) available in the test process.

!!! compat "Julia 1.3"
    `julia_args` and `test_args` requires at least Julia 1.3.

!!! compat "Julia 1.9"
    `allow_reresolve` requires at least Julia 1.9.

Run the tests for package `pkg`, or for the current project (which thus needs to be a package) if no
positional argument is given to `Pkg.test`. A package is tested by running its
`test/runtests.jl` file.

The tests are run by generating a temporary environment with only the `pkg` package
and its (recursive) dependencies in it. If a manifest file exists and the `allow_reresolve`
keyword argument is set to `false`, the versions in the manifest file are used.
Otherwise a feasible set of packages is resolved and installed.

During the tests, test-specific dependencies are active, which are
given in the project file as e.g.

```
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

The tests are executed in a new process with `check-bounds=yes` and by default `startup-file=no`.
If using the startup file (`~/.julia/config/startup.jl`) is desired, start julia with `--startup-file=yes`.
Inlining of functions during testing can be disabled (for better coverage accuracy)
by starting julia with `--inline=no`.
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
    Pkg.pin(pkg::Union{String, Vector{String}}; io::IO=stderr)
    Pkg.pin(pkgs::Union{PackageSpec, Vector{PackageSpec}}; io::IO=stderr)

Pin a package to the current version (or the one given in the `PackageSpec`) or to a certain
git revision. A pinned package is never updated.

# Examples
```julia
Pkg.pin("Example")
Pkg.pin(name="Example", version="0.3.1")
```
"""
const pin = API.pin

"""
    Pkg.free(pkg::Union{String, Vector{String}}; io::IO=stderr)
    Pkg.free(pkgs::Union{PackageSpec, Vector{PackageSpec}}; io::IO=stderr)

If `pkg` is pinned, remove the pin.
If `pkg` is tracking a path,
e.g. after [`Pkg.develop`](@ref), go back to tracking registered versions.

# Examples
```julia
Pkg.free("Package")
```
"""
const free = API.free


"""
    Pkg.develop(pkg::Union{String, Vector{String}}; io::IO=stderr)
    Pkg.develop(pkgs::Union{Packagespec, Vector{Packagespec}}; io::IO=stderr)

Make a package available for development by tracking it by path.
If `pkg` is given with only a name or by a URL, the package will be downloaded
to the location specified by the environment variable `JULIA_PKG_DEVDIR`, with
`joinpath(DEPOT_PATH[1],"dev")` being the default.

If `pkg` is given as a local path, the package at that path will be tracked.

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

!!! compat "Julia 1.4"
    This feature requires Julia 1.4, and is considered experimental.

Query the dependency graph.
The result is a `Dict` that maps a package UUID to a `PackageInfo` struct representing the dependency (a package).

# `PackageInfo` fields

| Field             | Description                                                |
|:------------------|:-----------------------------------------------------------|
| `name`            | The name of the package                                    |
| `version`         | The version of the package (this is `Nothing` for stdlibs) |
| `is_direct_dep`   | The package is a direct dependency                         |
| `is_tracking_path`| Whether a package is directly tracking a directory         |
| `is_pinned`       | Whether a package is pinned                                |
| `source`          | The directory containing the source code for that package  |
| `dependencies`    | The dependencies of that package as a vector of UUIDs      |
"""
const dependencies = API.dependencies

"""
    Pkg.project()::ProjectInfo

!!! compat "Julia 1.4"
    This feature requires Julia 1.4, and is considered experimental.

Request a `ProjectInfo` struct which contains information about the active project.

# `ProjectInfo` fields

| Field        | Description                                                                                 |
|:-------------|:--------------------------------------------------------------------------------------------|
| name         | The project's name                                                                          |
| uuid         | The project's UUID                                                                          |
| version      | The project's version                                                                       |
| dependencies | The project's direct dependencies as a `Dict` which maps dependency name to dependency UUID |
| path         | The location of the project file which defines the active project                           |
"""
const project = API.project

"""
    Pkg.instantiate(; verbose = false, io::IO=stderr)

If a `Manifest.toml` file exists in the active project, download all
the packages declared in that manifest.
Otherwise, resolve a set of feasible packages from the `Project.toml` files
and install them.
`verbose = true` prints the build output to `stdout`/`stderr` instead of
redirecting to the `build.log` file.
If no `Project.toml` exist in the current active project, create one with all the
dependencies in the manifest and instantiate the resulting project.

After packages have been installed the project will be precompiled.
See more at [Project Precompilation](@ref).
"""
const instantiate = API.instantiate

"""
    Pkg.resolve(; io::IO=stderr)

Update the current manifest with potential changes to the dependency graph
from packages that are tracking a path.
"""
const resolve = API.resolve

"""
    Pkg.status([pkgs...]; outdated::Bool=false, mode::PackageMode=PKGMODE_PROJECT, diff::Bool=false, compat::Bool=false, io::IO=stdout)

Print out the status of the project/manifest.

Packages marked with `⌃` have new versions that can be installed, e.g. via [`Pkg.up`](@ref).
Those marked with `⌅` have new versions available, but cannot be installed due to compatibility conflicts with other packages. To see why, set the
keyword argument `outdated=true`.

Setting `outdated=true` will only show packages that are not on the latest version,
their maximum version and why they are not on the latest version (either due to other
packages holding them back due to compatibility constraints, or due to compatibility in the project file).
As an example, a status output like:
```
pkg> Pkg.status(; outdated=true)
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

Setting `diff=true` will, if the environment is in a git repository, limit
the output to the difference as compared to the last git commit.

See [`Pkg.project`](@ref) and [`Pkg.dependencies`](@ref) to get the project/manifest
status as a Julia object instead of printing it.

!!! compat "Julia 1.1"
    `Pkg.status` with package arguments requires at least Julia 1.1.

!!! compat "Julia 1.3"
    The `diff` keyword argument requires at least Julia 1.3. In earlier versions `diff=true`
    is the default for environments in git repositories.

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

If no argument is given to `activate`, then activate the home project.
The home project is specified by either the `--project` command line option to
the julia executable, or the `JULIA_PROJECT` environment variable.

# Examples
```
Pkg.activate()
Pkg.activate("local/path")
Pkg.activate("MyDependency")
Pkg.activate(; temp=true)
```

!!! compat "Julia 1.4"
    the `temp` option requires at least Julia 1.4.
"""
const activate = API.activate

"""
    Pkg.offline(b::Bool=true)

Enable (`b=true`) or disable (`b=false`) offline mode.

In offline mode Pkg tries to do as much as possible without connecting
to internet. For example, when adding a package Pkg only considers
versions that are already downloaded in version resolution.

To work in offline mode across Julia sessions you can
set the environment variable `JULIA_PKG_OFFLINE` to `"true"`.

!!! compat "Julia 1.5"
    Pkg's offline mode requires Julia 1.5 or later.
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
    the enum [`UpgradeLevel`](@ref).
  * A `url` and an optional git `rev`ision. `rev` can be a branch name or a git commit SHA1.
  * A local `path`. This is equivalent to using the `url` argument but can be more descriptive.
  * A `subdir` which can be used when adding a package that is not in the root of a repository.

Most functions in Pkg take a `Vector` of `PackageSpec` and do the operation on all the packages
in the vector.

!!! compat "Julia 1.5"
    Many functions that take a `PackageSpec` or a `Vector{PackageSpec}` can be called with a more concise notation with `NamedTuple`s.
    For example, `Pkg.add` can be called either as the explicit or concise versions as:

    | Explicit                                                            | Concise                                        |
    |:--------------------------------------------------------------------|:-----------------------------------------------|
    | `Pkg.add(PackageSpec(name="Package"))`                              | `Pkg.add(name = "Package")`                    |
    | `Pkg.add(PackageSpec(url="www.myhost.com/MyPkg")))`                 | `Pkg.add(name = "Package")`                    |
    |` Pkg.add([PackageSpec(name="Package"), PackageSpec(path="/MyPkg"])` | `Pkg.add([(;name="Package"), (;path="MyPkg")])`|

Below is a comparison between the REPL mode and the functional API:

| `REPL`               | `API`                                                 |
|:---------------------|:------------------------------------------------------|
| `Package`            | `PackageSpec("Package")`                              |
| `Package@0.2`        | `PackageSpec(name="Package", version="0.2")`          |
| `Package=a67d...`    | `PackageSpec(name="Package", uuid="a67d...")`         |
| `Package#master`     | `PackageSpec(name="Package", rev="master")`           |
| `local/path#feature` | `PackageSpec(path="local/path"; rev="feature")`       |
| `www.mypkg.com`      | `PackageSpec(url="www.mypkg.com")`                    |
| `--major Package`    | `PackageSpec(name="Package", version=PKGLEVEL_MAJOR)` |

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

julia> Pkg.setprotocol!(domain = "gitlab.mycompany.com")
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
    RegistrySpec(; name, url, path)

A `RegistrySpec` is a representation of a registry with various metadata, much like
[`PackageSpec`](@ref).

Most registry functions in Pkg take a `Vector` of `RegistrySpec` and do the operation
on all the registries in the vector.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples

Below is a comparison between the REPL mode and the functional API::

| `REPL`               | `API`                                           |
|:---------------------|:------------------------------------------------|
| `Registry`           | `RegistrySpec("Registry")`                      |
| `Registry=a67d...`   | `RegistrySpec(name="Registry", uuid="a67d...")` |
| `local/path`         | `RegistrySpec(path="local/path")`               |
| `www.myregistry.com` | `RegistrySpec(url="www.myregistry.com")`        |
"""
const RegistrySpec = Registry.RegistrySpec

"""
    upgrade_manifest()
    upgrade_manifest(manifest_path::String)

Upgrades the format of the current or specified manifest file from v1.0 to v2.0 without re-resolving.
"""
const upgrade_manifest = API.upgrade_manifest

"""
    is_manifest_current(ctx::Context = Context())

Returns whether the active manifest was resolved from the active project state.
For instance, if the project had compat entries changed, but the manifest wasn't re-resolved, this would return false.

If the manifest doesn't have the project hash recorded, `nothing` is returned.
"""
const is_manifest_current = API.is_manifest_current

function __init__()
    Pkg.UPDATED_REGISTRY_THIS_SESSION[] = false
    if isdefined(Base, :active_repl)
        REPLMode.repl_init(Base.active_repl)
    else
        atreplinit() do repl
            if isinteractive() && repl isa REPL.LineEditREPL
                isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
                REPLMode.repl_init(repl)
            end
        end
    end
    push!(empty!(REPL.install_packages_hooks), REPLMode.try_prompt_pkg_add)
    OFFLINE_MODE[] = get_bool_env("JULIA_PKG_OFFLINE")
    return nothing
end

################
# Deprecations #
################

function installed()
    @warn "Pkg.installed() is deprecated"
    deps = dependencies()
    installs = Dict{String, VersionNumber}()
    for (uuid, dep) in deps
        dep.is_direct_dep || continue
        dep.version === nothing && continue
        installs[dep.name] = dep.version
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
        @info("We haven't cleaned this depot up for a bit, running Pkg.gc()...")
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

function _auto_precompile(ctx::Types.Context; warn_loaded = true, already_instantiated = false)
    if Base.JLOptions().use_compiled_modules == 1 && get_bool_env("JULIA_PKG_PRECOMPILE_AUTO"; default="true")
        Pkg.precompile(ctx; internal_call=true, warn_loaded = warn_loaded, already_instantiated = already_instantiated)
    end
end

using LibGit2: LibGit2
using Tar: Tar
function _run_precompilation_script_setup()
    tmp = mktempdir()
    cd(tmp)
    empty!(DEPOT_PATH)
    pushfirst!(DEPOT_PATH, tmp)
    touch("Project.toml")
    Pkg.activate(".")
    Pkg.generate("TestPkg")
    uuid = TOML.parsefile(joinpath("TestPkg", "Project.toml"))["uuid"]
    mv("TestPkg", "TestPkg.jl")
    tree_hash = cd("TestPkg.jl") do
        sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time()), 0)
        repo = LibGit2.init(".")
        LibGit2.add!(repo, "")
        commit = LibGit2.commit(repo, "initial commit"; author=sig, committer=sig)
        th = LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(repo, commit)) |> LibGit2.GitHash |> string
        close(repo)
        th
    end
    # Prevent cloning the General registry by adding a fake one
    mkpath("registries/Registry/T/TestPkg")
    write("registries/Registry/Registry.toml", """
        name = "Registry"
        uuid = "37c07fec-e54c-4851-934c-2e3885e4053e"
        repo = "https://github.com/JuliaRegistries/Registry.git"
        [packages]
        $uuid = { name = "TestPkg", path = "T/TestPkg" }
        """)
    write("registries/Registry/T/TestPkg/Compat.toml", """
          ["0"]
          julia = "1"
          """)
    write("registries/Registry/T/TestPkg/Deps.toml", """
          ["0"]
          Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
          """)
    write("registries/Registry/T/TestPkg/Versions.toml", """
          ["0.1.0"]
          git-tree-sha1 = "$tree_hash"
          """)
    write("registries/Registry/T/TestPkg/Package.toml", """
        name = "TestPkg"
        uuid = "$uuid"
        repo = "$(escape_string(tmp))/TestPkg.jl"
        """)
    Tar.create("registries/Registry", "registries/Registry.tar")
    cmd = `$(Pkg.PlatformEngines.exe7z()) a "registries/Registry.tar.gz" -tgzip "registries/Registry.tar"`
    run(pipeline(cmd, stdout = stdout_f(), stderr = stderr_f()))
    write("registries/Registry.toml", """
          git-tree-sha1 = "11b5fad51c4f98cfe0c145ceab0b8fb63fed6f81"
          uuid = "37c07fec-e54c-4851-934c-2e3885e4053e"
          path = "Registry.tar.gz"
    """)
    Base.rm("registries/Registry"; recursive=true)
    return tmp
end

function _run_precompilation_script_artifact()
    # Create simple artifact, bind it, then use it:
    foo_hash = Pkg.Artifacts.create_artifact(dir -> touch(joinpath(dir, "foo")))
    Artifacts.bind_artifact!("./Artifacts.toml", "foo", foo_hash)
    # Also create multiple platform-specific ones because that's a codepath we need precompiled
    Artifacts.bind_artifact!("./Artifacts.toml", "foo_plat", foo_hash; platform=Base.BinaryPlatforms.HostPlatform())
    # Because @artifact_str doesn't work at REPL-level, we JIT out a file that we can include()
    write("load_artifact.jl", """
          Pkg.Artifacts.artifact"foo"
          Pkg.Artifacts.artifact"foo_plat"
          """)
    foo_path = include("load_artifact.jl")
end

const CTRL_C = '\x03'
const precompile_script = """
    import Pkg
    _pwd = pwd()
    Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
    tmp = Pkg._run_precompilation_script_setup()
    $CTRL_C
    Pkg.add("TestPkg")
    Pkg.develop(Pkg.PackageSpec(path="TestPkg.jl"))
    Pkg.add(Pkg.PackageSpec(path="TestPkg.jl/"))
    Pkg.REPLMode.try_prompt_pkg_add(Symbol[:notapackage])
    Pkg.update(; update_registry=false)
    Pkg.precompile()
    ] add Te\t\t$CTRL_C
    ] st
    $CTRL_C
    Pkg._run_precompilation_script_artifact()
    rm(tmp; recursive=true)
    cd(_pwd)
    """

end # module
