# This file is a part of Julia. License is MIT: https://julialang.org/license

module Pkg

import Random
import REPL

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
devdir(depot = depots1()) = get(ENV, "JULIA_PKG_DEVDIR", joinpath(depots1(), "dev"))
envdir(depot = depots1()) = joinpath(depot, "environments")
const UPDATED_REGISTRY_THIS_SESSION = Ref(false)
const OFFLINE_MODE = Ref(false)
const DEFAULT_IO = Ref{Union{Nothing,IO}}(nothing)

# load snapshotted dependencies
include("../ext/TOML/src/TOML.jl")

include("utils.jl")
include("GitTools.jl")
include("PlatformEngines.jl")
include("BinaryPlatforms.jl")
include("Types.jl")
include("Resolve/Resolve.jl")
include("Artifacts.jl")
include("Operations.jl")
include("API.jl")
include("Registry.jl")
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
Used as an argument to  [`PackageSpec`](@ref) or as an argument to [`Pkg.rm`](@ref).
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

See also [`PackageSpec`](@ref).
"""
const add = API.add

"""
    Pkg.precompile()

Precompile all the dependencies of the project.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3. On earlier versions
    you can use `Pkg.API.precompile()` or the `precompile` Pkg REPL command.

# Examples
```julia
Pkg.precompile()
```
"""
const precompile = API.precompile

"""
    Pkg.rm(pkg::Union{String, Vector{String}})
    Pkg.rm(pkg::Union{PackageSpec, Vector{PackageSpec}})

Remove a package from the current project. If the `mode` of `pkg` is
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

See also [`PackageSpec`](@ref), [`PackageMode`](@ref), [`UpgradeLevel`](@ref).
"""
const update = API.up

"""
    Pkg.test(; kwargs...)
    Pkg.test(pkg::Union{String, Vector{String}; kwargs...)
    Pkg.test(pkgs::Union{PackageSpec, Vector{PackageSpec}}; kwargs...)

**Keyword arguments:**
  - `coverage::Bool=false`: enable or disable generation of coverage statistics.
  - `julia_args::Union{Cmd, Vector{String}}`: options to be passed the test process.
  - `test_args::Union{Cmd, Vector{String}}`: test arguments (`ARGS`) available in the test process.

!!! compat "Julia 1.3"
    `julia_args` and `test_args` requires at least Julia 1.3.

Run the tests for package `pkg`, or for the current project (which thus needs to be a package) if no
positional argument is given to `Pkg.test`. A package is tested by running its
`test/runtests.jl` file.

The tests are run by generating a temporary environment with only `pkg` and its (recursive) dependencies
in it. If a manifest exists, the versions in that manifest are used, otherwise
a feasible set of packages is resolved and installed.

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
    Pkg.gc()

Garbage collect packages that are no longer reachable from any project.
Only packages that are tracked by version are deleted, so no packages
that might contain local changes are touched.
"""
const gc = API.gc


"""
    Pkg.build(; verbose = false)
    Pkg.build(pkg::Union{String, Vector{String}}; verbose = false)
    Pkg.build(pkgs::Union{PackageSpec, Vector{PackageSpec}}; verbose = false)

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
    Pkg.pin(pkg::Union{String, Vector{String}})
    Pkg.pin(pkgs::Union{PackageSpec, Vector{PackageSpec}})

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
    Pkg.free(pkg::Union{String, Vector{String}})
    Pkg.free(pkgs::Union{PackageSpec, Vector{PackageSpec}})

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
    Pkg.develop(pkg::Union{String, Vector{String}})
    Pkg.develop(pkgs::Union{Packagespec, Vector{Packagespec}})

Make a package available for development by tracking it by path.
If `pkg` is given with only a name or by a URL, the package will be downloaded
to the location specified by the environment variable `JULIA_PKG_DEVDIR`, with
`.julia/dev` as the default.

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

See also [`PackageSpec`](@ref)

"""
const develop = API.develop

#TODO: Will probably be deprecated for something in PkgDev
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
    Pkg.instantiate(; verbose = false)

If a `Manifest.toml` file exists in the active project, download all
the packages declared in that manifest.
Otherwise, resolve a set of feasible packages from the `Project.toml` files
and install them.
`verbose = true` prints the build output to `stdout`/`stderr` instead of
redirecting to the `build.log` file.
If no `Project.toml` exist in the current active project, create one with all the
dependencies in the manifest and instantiate the resulting project.
"""
const instantiate = API.instantiate

"""
    Pkg.resolve()

Update the current manifest with potential changes to the dependency graph
from packages that are tracking a path.
"""
const resolve = API.resolve

"""
    Pkg.status([pkgs...]; mode::PackageMode=PKGMODE_PROJECT, diff::Bool=false)

Print out the status of the project/manifest.
If `mode` is `PKGMODE_PROJECT`, print out status only about the packages
that are in the project (explicitly added). If `mode` is `PKGMODE_MANIFEST`,
print status also about those in the manifest (recursive dependencies). If there are
any packages listed as arguments, the output will be limited to those packages.
Setting `diff=true` will, if the environment is in a git repository, limit
the output to the difference as compared to the last git commit.

!!! compat "Julia 1.1"
    `Pkg.status` with package arguments requires at least Julia 1.1.

!!! compat "Julia 1.3"
    The `diff` keyword argument requires Julia 1.3. In earlier versions `diff=true`
    is the default for environments in git repositories.
"""
const status = API.status


"""
    Pkg.activate([s::String]; shared::Bool=false)

Activate the environment at `s`. The active environment is the environment
that is modified by executing package commands.
The logic for what path is activated is as follows:

  * If `shared` is `true`, the first existing environment named `s` from the depots
    in the depot stack will be activated. If no such environment exists,
    create and activate that environment in the first depot.
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
```
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
  * A `mode`, which is an instance of the enum [`PackageMode`](@ref), with possible values `PKGMODE_PROJECT`
   (the default) or `PKGMODE_MANIFEST`. Used in e.g. [`Pkg.rm`](@ref).

Most functions in Pkg take a `Vector` of `PackageSpec` and do the operation on all the packages
in the vector.

!!! compat "Julia 1.5"
    Many functions that take a `PackageSpec` or a `Vector{PackageSpec}` can be called with a more concise notation with `NamedTuple`s.
    For example, `Pkg.add` can be called either as the explicit or concise versions as:
    | Explicit                                                            | Concise
    |:--------------------------------------------------------------------|:-----------------------------------------------|
    | `Pkg.add(PackageSpec(name="Package))`                               | `Pkg.add(name = "Package")`                    |
    | `Pkg.add(PackageSpec(url="www.myhost.com/MyPkg")))`                 | `Pkg.add(name = "Package")`                    |
    |` Pkg.add([PackageSpec(name="Package"), PackageSpec(path="/MyPkg"])` | `Pkg.add([(;name="Package"), (;path="MyPkg")])`|

Below is a comparison between the REPL version and the API version:

| `REPL`               | `API`                                                 |
|:---------------------|:------------------------------------------------------|
| `Package`            | `PackageSpec("Package")`                              |
| `Package@0.2`        | `PackageSpec(name="Package", version="0.2")`          |
| `Package=a67d...`    | `PackageSpec(name="Package", uuid="a67d...")`         |
| `Package#master`     | `PackageSpec(name="Package", rev="master")`           |
| `local/path#feature` | `PackageSpec(path="local/path"; rev="feature")`       |
| `www.mypkg.com`      | `PackageSpec(url="www.mypkg.com")`                    |
| `--manifest Package` | `PackageSpec(name="Package", mode=PKGSPEC_MANIFEST)`  |
| `--major Package`    | `PackageSpec(name="Package", version=PKGLEVEL_MAJOR)` |

"""
const PackageSpec = API.Package

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

Below is a comparison between the REPL version and the API version:

| `REPL`               | `API`                                           |
|:---------------------|:------------------------------------------------|
| `Registry`           | `RegistrySpec("Registry")`                      |
| `Registry=a67d...`   | `RegistrySpec(name="Registry", uuid="a67d...")` |
| `local/path`         | `RegistrySpec(path="local/path")`               |
| `www.myregistry.com` | `RegistrySpec(url="www.myregistry.com")`        |
"""
const RegistrySpec = Types.RegistrySpec


function __init__()
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
    OFFLINE_MODE[] = get(ENV, "JULIA_PKG_OFFLINE", nothing) == "true"
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

##################
# Precompilation #
##################

using LibGit2: LibGit2
function _run_precompilation_script_setup()
    tmp = mktempdir()
    cd(tmp)
    empty!(DEPOT_PATH)
    pushfirst!(DEPOT_PATH, tmp)
    touch("Project.toml")
    Pkg.activate(".")
    Pkg.generate("TestPkg")
    uuid = Pkg.TOML.parsefile(joinpath("TestPkg", "Project.toml"))["uuid"]
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
        repo = "$tmp/TestPkg.jl"
        """)
    return tmp
end

function _run_precompilation_script_artifact()
    # Create simple artifact, bind it, then use it:
    foo_hash = Pkg.Artifacts.create_artifact(dir -> touch(joinpath(dir, "foo")))
    Artifacts.bind_artifact!("./Artifacts.toml", "foo", foo_hash)
    # Also create multiple platform-specific ones because that's a codepath we need precompiled
    Artifacts.bind_artifact!("./Artifacts.toml", "foo_plat", foo_hash; platform=BinaryPlatforms.platform_key_abi())
    Artifacts.bind_artifact!("./Artifacts.toml", "foo_plat", foo_hash; platform=BinaryPlatforms.Linux(:x86_64), force=true)
    Artifacts.bind_artifact!("./Artifacts.toml", "foo_plat", foo_hash; platform=BinaryPlatforms.Windows(:x86_64), force=true)
    Artifacts.bind_artifact!("./Artifacts.toml", "foo_plat", foo_hash; platform=BinaryPlatforms.MacOS(:x86_64), force=true)
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
    tmp = Pkg._run_precompilation_script_setup()
    $CTRL_C
    Pkg.add("TestPkg")
    Pkg.develop(Pkg.PackageSpec(path="TestPkg.jl"))
    Pkg.add(Pkg.PackageSpec(path="TestPkg.jl/"))
    ] add Te\t\t$CTRL_C
    ] st
    $CTRL_C
    Pkg._run_precompilation_script_artifact()
    rm(tmp; recursive=true)"""

end # module
