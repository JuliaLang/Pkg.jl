# **3.** Managing Packages

## Adding packages

There are two ways of adding packages, either using the `add` command or the `dev` command.
The most frequently used is `add` and its usage is described first.

### Adding registered packages

In the Pkg REPL, packages can be added with the `add` command followed by the name of the package, for example:

```julia-repl
(v1.0) pkg> add Example
   Cloning default registries into /Users/kristoffer/.julia/registries
   Cloning registry General from "https://github.com/JuliaRegistries/General.git"
  Updating registry at `~/.julia/registries/General`
  Updating git-repo `https://github.com/JuliaRegistries/General.git`
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] + Example v0.5.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] + Example v0.5.1
  [8dfed614] + Test
```

Here we added the package Example to the current project. In this example, we are using a fresh Julia installation,
and this is our first time adding a package using Pkg. By default, Pkg clones Julia's General registry,
and uses this registry to look up packages requested for inclusion in the current environment.
The status update shows a short form of the package UUID to the left, then the package name, and the version.
Since standard libraries (e.g. `Test`) are shipped with Julia, they do not have a version. The project status contains the packages
you have added yourself, in this case, `Example`:

```julia-repl
(v1.0) pkg> st
    Status `Project.toml`
  [7876af07] Example v0.5.1
```

The manifest status shows all the packages in the environment, including recursive dependencies:

```julia-repl
(v1.0) pkg> st --manifest
    Status `Manifest.toml`
  [7876af07] Example v0.5.1
  [8dfed614] Test
```

It is possible to add multiple packages in one command as `pkg> add A B C`.

After a package is added to the project, it can be loaded in Julia:

```julia-repl
julia> using Example

julia> Example.hello("User")
"Hello, User"
```

A specific version can be installed by appending a version after a `@` symbol, e.g. `@v0.4`, to the package name:

```julia-repl
(v1.0) pkg> add Example@0.4
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] + Example v0.4.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] + Example v0.4.1
```

If a branch (or a certain commit) of `Example` has a hotfix that is not yet included in a registered version,
we can explicitly track that branch (or commit) by appending `#branchname` (or `#commitSHA1`) to the package name:

```julia-repl
(v1.0) pkg> add Example#master
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1+ #master (https://github.com/JuliaLang/Example.jl.git)
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1+ #master (https://github.com/JuliaLang/Example.jl.git)
```

The status output now shows that we are tracking the `master` branch of `Example`.
When updating packages, updates are pulled from that branch.

!!! note
    If we would specify a commit id instead of a branch name, e.g.
    `add Example#025cf7e`, then we would effectively "pin" the package
    to that commit. This is because the commit id always point to the same
    thing unlike a branch, which may be updated.
    
To go back to tracking the registry version of `Example`, the command `free` is used:

```julia-repl
(v1.0) pkg> free Example
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1+ #master (https://github.com/JuliaLang/Example.jl.git) ⇒ v0.5.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1+ #master )https://github.com/JuliaLang/Example.jl.git) ⇒ v0.5.1
```


### Adding unregistered packages

If a package is not in a registry, it can be added by specifying a URL to the repository:

```julia-repl
(v1.0) pkg> add https://github.com/fredrikekre/ImportMacros.jl
  Updating git-repo `https://github.com/fredrikekre/ImportMacros.jl`
 Resolving package versions...
Downloaded MacroTools ─ v0.4.1
  Updating `~/.julia/environments/v1.0/Project.toml`
  [e6797606] + ImportMacros v0.0.0 # (https://github.com/fredrikekre/ImportMacros.jl)
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [e6797606] + ImportMacros v0.0.0 # (https://github.com/fredrikekre/ImportMacros.jl)
  [1914dd2f] + MacroTools v0.4.1
```

The dependencies of the unregistered package (here `MacroTools`) got installed.
For unregistered packages we could have given a branch name (or commit SHA1) to track using `#`, just like for registered packages.

If you want to add a package using the SSH-based `git` protocol, you have to use quotes because the URL contains a `@`. For example,
```julia-repl
(v1.0) pkg> add "git@github.com:fredrikekre/ImportMacros.jl.git"
    Cloning git-repo `git@github.com:fredrikekre/ImportMacros.jl.git`
   Updating git-repo `git@github.com:fredrikekre/ImportMacros.jl.git`
   Updating registry at `~/.julia/registries/General`
  Resolving package versions...
Updating `~/.julia/environments/v1/Project.toml`
  [92a963f6] + ImportMacros v1.0.0 `git@github.com:fredrikekre/ImportMacros.jl.git#master`
Updating `~/.julia/environments/v1/Manifest.toml`
  [92a963f6] + ImportMacros v1.0.0 `git@github.com:fredrikekre/ImportMacros.jl.git#master`
```

### Adding a local package

Instead of giving a URL of a git repo to `add` we could instead have given a local path to a git repo.
This works similar to adding a URL. The local repository will be tracked (at some branch) and updates
from that local repo are pulled when packages are updated.
Note tracking a package through `add` is distinct from `develop`:
changes to files in the local package repository will not immediately be reflected when loading that package.
The changes would have to be committed and the packages updated in order to pull in the changes.

In addition, it is possible to add packages relatively to the `Manifest.toml` file, see [Developing packages](@ref developing) for an example.

### [Developing packages](@id developing)

By only using `add` your Manifest will always have a "reproducible state", in other words, as long as the repositories and registries used are still accessible
it is possible to retrieve the exact state of all the dependencies in the project. This has the advantage that you can send your project (`Project.toml`
and `Manifest.toml`) to someone else and they can "instantiate" that project in the same state as you had it locally.
However, when you are developing a package, it is more convenient to load packages at their current state at some path. For this reason, the `dev` command exists.

Let's try to `dev` a registered package:

```julia-repl
(v1.0) pkg> dev Example
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] + Example v0.5.1+ [`~/.julia/dev/Example`]
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] + Example v0.5.1+ [`~/.julia/dev/Example`]
```

The `dev` command fetches a full clone of the package to `~/.julia/dev/` (the path can be changed by setting the environment variable `JULIA_PKG_DEVDIR`, the default being `joinpath(DEPOT_PATH[1],"dev")`).
When importing `Example` julia will now import it from `~/.julia/dev/Example` and whatever local changes have been made to the files in that path are consequently
reflected in the code loaded. When we used `add` we said that we tracked the package repository, we here say that we track the path itself.
Note the package manager will never touch any of the files at a tracked path. It is therefore up to you to pull updates, change branches etc.
If we try to `dev` a package at some branch that already exists at `~/.julia/dev/` the package manager we will simply use the existing path.
For example:

```julia-repl
(v1.0) pkg> dev Example
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
[ Info: Path `/Users/kristoffer/.julia/dev/Example` exists and looks like the correct package, using existing path instead of cloning
```

Note the info message saying that it is using the existing path.
When tracking a path, the package manager will never modify the files at that path.

If `dev` is used on a local path, that path to that package is recorded and used when loading that package.
The path will be recorded relative to the project file, unless it is given as an absolute path.

```julia-repl
(v1.0) pkg> dev /Users/kristoffer/Desktop/Example
```

To stop tracking a path and use the registered version again, use `free`:

```julia-repl
(v1.0) pkg> free Example
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ↓ Example v0.5.1+ [`~/.julia/dev/Example`] ⇒ v0.5.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ↓ Example v0.5.1+ [`~/.julia/dev/Example`] ⇒ v0.5.1
```

It should be pointed out that by using `dev` your project is now inherently stateful.
Its state depends on the current content of the files at the path and the manifest cannot be "instantiated" by someone else without
knowing the exact content of all the packages that are tracking a path.

Note that if you add a dependency to a package that tracks a local path, the Manifest (which contains the whole dependency graph) will become
out of sync with the actual dependency graph. This means that the package will not be able to load that dependency since it is not recorded
in the Manifest. To synchronize the Manifest, use the REPL command `resolve`.

In addition to absolute paths, `add` and `dev` can accept relative paths to packages.
In this case, the relative path from the active project to the package is stored.
This approach is useful when the relative location of tracked dependencies is more important than their absolute location.
For example, the tracked dependencies can be stored inside of the active project directory.
The whole directory can be moved and `Pkg` will still be able to find the dependencies
because their path relative to the active project is preserved even though their absolute path has changed.

### Adding a package in a subdirectory of a repository

If the package you want to add by URL is not in the root of the repository, then you need to manually pass the `subdir` keyword to `Pkg.add`
or `PackageSpec`. For instance, to add the `SnoopCompileCore` package in the [SnoopCompile](https://github.com/timholy/SnoopCompile.jl)
repository:

```julia-repl
julia> Pkg.add(url="https://github.com/timholy/SnoopCompile.jl.git", subdir="SnoopCompileCore")
     Cloning git-repo `https://github.com/timholy/SnoopCompile.jl.git`
    Updating git-repo `https://github.com/timholy/SnoopCompile.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v1.6/Project.toml`
  [e2b509da] + SnoopCompileCore v2.7.0 `https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore#master`
    Updating `~/.julia/environments/v1.6/Manifest.toml`
  [e2b509da] + SnoopCompileCore v2.7.0 `https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore#master`
  [9e88b42a] + Serialization
```

Another way is to use the Pkg REPL with `<repo_url>:<subdir>` format:

```julia-repl
pkg> add https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore # git HTTPS protocol
...

pkg> add "git@github.com:timholy/SnoopCompile.jl.git":SnoopCompileCore # git SSH protocol
...
```

!!! compat "Julia 1.5"
    The Pkg REPL for packages in subdirectory requires at least Julia 1.5.


## Removing packages

Packages can be removed from the current project by using `pkg> rm Package`.
This will only remove packages that exist in the project; to remove a package that only
exists as a dependency use `pkg> rm --manifest DepPackage`.
Note that this will remove all packages that depend on `DepPackage`.

## [Updating packages](@id updating)

When new versions of packages that the project is using are released, it is a good idea to update. Simply calling `up` will try to update *all* the dependencies of the project
to the latest compatible version. Sometimes this is not what you want. You can specify a subset of the dependencies to upgrade by giving them as arguments to `up`, e.g:

```julia-repl
(v1.0) pkg> up Example
```

If `Example` has a dependency which is also a dependency for another explicitly added package, that dependency will not be updated. If you only want to update the minor version of packages, to reduce the risk that your project breaks, you can give the `--minor` flag, e.g:

```julia-repl
(v1.0) pkg> up --minor Example
```

Packages that track a local repository are not updated when a minor upgrade is done.
Packages that track a path are never touched by the package manager.

## Pinning a package

A pinned package will never be updated. A package can be pinned using `pin`, for example:

```julia-repl
(v1.0) pkg> pin Example
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1 ⚲
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1 ⚲
```

Note the pin symbol `⚲` showing that the package is pinned. Removing the pin is done using `free`

```julia-repl
(v1.0) pkg> free Example
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1 ⚲ ⇒ v0.5.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1 ⚲ ⇒ v0.5.1
```

## Testing packages

The tests for a package can be run using `test`command:

```julia-repl
(v1.0) pkg> test Example
   Testing Example
   Testing Example tests passed
```

## Building packages

The build step of a package is automatically run when a package is first installed.
The output of the build process is directed to a file.
To explicitly run the build step for a package, the `build` command is used:

```julia-repl
(v1.0) pkg> build MbedTLS
  Building MbedTLS → `~/.julia/packages/MbedTLS/h1Vu/deps/build.log`

julia> print(read("~/.julia/packages/MbedTLS/h1Vu/deps/build.log", String))
┌ Warning: `wait(t::Task)` is deprecated, use `fetch(t)` instead.
│   caller = macro expansion at OutputCollector.jl:63 [inlined]
└ @ Core OutputCollector.jl:63
...
[ Info: using prebuilt binaries
```

## [Interpreting and resolving version conflicts](@id conflicts)

An environment consists of a set of mutually-compatible packages.
Sometimes, you can find yourself in a situation in which two packages you'd like to use simultaneously
have incompatible requirements.
In such cases you'll get an "Unsatisfiable requirements" error:

```@setup conflict
using Pkg
include(joinpath(pkgdir(Pkg), "test", "resolve_utils.jl"))
using .ResolveUtils
deps_data = Any[["A", v"1.0.0", "C", v"0.2"],
                ["B", v"1.0.0", "D", v"0.1"],
                ["C", v"0.1.0", "D", v"0.1"],
                ["C", v"0.1.1", "D", v"0.1"],
                ["C", v"0.2.0", "D", v"0.2"],
                ["D", v"0.1.0"],
                ["D", v"0.2.0"],
                ["D", v"0.2.1"]]
reqs_data = Any[["A", "*"],
                ["B", "*"]]
```

```@example conflict
print("pkg> add A\n", try resolve_tst(deps_data, reqs_data) catch e sprint(showerror, e) end)   # hide
```

This message means that a package named `D` has a version conflict.
Even if you have never `add`ed `D` directly, this kind of error can arise
if `D` is required by other packages that you are trying to use.

The error message has a lot of crucial information.
It may be easiest to interpret piecewise:

```
Unsatisfiable requirements detected for package D [756980fe]:
 D [756980fe] log:
 ├─possible versions are: [0.1.0, 0.2.0-0.2.1] or uninstalled
```
means that `D` has three released versions, `v0.1.0`, `v0.2.0`, and `v0.2.1`.
You also have the option of not having it installed at all.
Each of these options might have different implications for the set of other packages that can be installed.

Crucially, notice the stroke characters (vertical and horizontal lines) and their indentation.
Together, these connect *messages* to specific *packages*.
For instance the right stroke of `├─` indicates that the message to its right (`possible versions...`)
is connected to the package pointed to by its vertical stroke (`D`).
This same principle applies to the next line:

```
 ├─restricted by compatibility requirements with B [f4259836] to versions: 0.1.0
```
The vertical stroke here is also aligned under `D`, and thus this message
is in reference to `D`.
Specifically, there's some other package `B` that depends on version `v0.1.0` of `D`.
Notice that this is not the newest version of `D`.

Next comes some information about `B`:

```
 │ └─B [f4259836] log:
 │   ├─possible versions are: 1.0.0 or uninstalled
 │   └─restricted to versions * by an explicit requirement, leaving only versions 1.0.0
```
The two lines below the first have a vertical stroke that aligns with `B`,
and thus they provide information about `B`.
They tell you that `B` has just one release, `v1.0.0`.
You've not specified a particular version of `B` (`restricted to versions *` means that any version will do),
but the `explicit requirement` means that you've asked for `B` to be part of your environment,
for example by `pkg> add B`.
You might have asked for `B` previously, and the requirement is still active.

The conflict becomes clear with the line
```
└─restricted by compatibility requirements with C [c99a7cb2] to versions: 0.2.0 — no versions left
```

Here again the vertical stroke aligns with `D`: this means that `D` is *also* required by another package, `C`.
`C` requires `v0.2.0` of `D`, and this conflicts with `B`'s need for `v0.1.0` of `D`.
This explains the conflict.

But wait, you might ask, what is `C` and why do I need it at all?
The next few lines introduce the problem:

```
   └─C [c99a7cb2] log:
     ├─possible versions are: [0.1.0-0.1.1, 0.2.0] or uninstalled
     └─restricted by compatibility requirements with A [29c70717] to versions: 0.2.0
```
These provide more information about `C`, revealing that it has 3 released versions: `v0.1.0`, `v0.1.1`, and `v0.2.0`.
Moreover, `C` is required by another package `A`.
Indeed, `A`'s requirements are such that we need `v0.2.0` of `C`.
`A`'s origin is revealed on the next lines:

```
       └─A [29c70717] log:
         ├─possible versions are: 1.0.0 or uninstalled
         └─restricted to versions * by an explicit requirement, leaving only versions 1.0.0
```

So we can see that `A` was `explicitly required`, and in this case it's because we were trying to
`add` it to our environment.

In summary, we explicitly asked to use `A` and `B`, but this gave a conflict for `D`.
The reason was that `B` and `C` require conflicting versions of `D`.
Even though `C` isn't something we asked for explicitly, it was needed by `A`.

To fix such errors, you have a number of options:

- try [updating your packages](@ref updating). It's possible the developers of these packages have recently released new versions that are mutually compatible.
- remove either `A` or `B` from your environment. Perhaps `B` is left over from something you were previously working on, and you don't need it anymore. If you don't need `A` and `B` at the same time, this is the easiest way to fix the problem.
- try reporting your conflict. In this case, we were able to deduce that `B` requires an outdated version of `D`. You could thus report an issue in the development repository of `B.jl` asking for an updated version.
- try fixing the problem yourself.
  This becomes easier once you understand `Project.toml` files and how they declare their compatiblity requirements. We'll return to this example in [Fixing conflicts](@ref).

## Garbage collecting old, unused packages

As packages are updated and projects are deleted, installed package versions and artifacts that were
once used will inevitably become old and not used from any existing project.
`Pkg` keeps a log of all projects used so it can go through the log and see exactly which projects still exist
and what packages/artifacts those projects used.
If a package or artifact is not marked as used by any project, it is added to a list of orphaned packages.
Packages and artifacts that are in the orphan list for 30 days without being used again are deleted from the system on the next garbage collection.
This timing is configurable via the `collect_delay` keyword argument to `Pkg.gc()`.
A value of `0` will cause anything currently not in use immediately, skipping the orphans list entirely;
If you are short on disk space and want to clean out as many unused packages and artifacts as possible, you may want to try this, but if you need these versions again, you will have to download them again.
To run a typical garbage collection with default arguments, simply use the `gc` command at the `pkg>` REPL:

```julia-repl
(v1.0) pkg> gc
    Active manifests at:
        `~/BinaryProvider/Manifest.toml`
        ...
        `~/Compat.jl/Manifest.toml`
    Active artifacts:
        `~/src/MyProject/Artifacts.toml`

    Deleted ~/.julia/packages/BenchmarkTools/1cAj: 146.302 KiB
    Deleted ~/.julia/packages/Cassette/BXVB: 795.557 KiB
   ...
   Deleted `~/.julia/artifacts/e44cdf2579a92ad5cbacd1cddb7414c8b9d2e24e` (152.253 KiB)
   Deleted `~/.julia/artifacts/f2df5266567842bbb8a06acca56bcabf813cd73f` (21.536 MiB)

   Deleted 36 package installations (113.205 MiB)
   Deleted 15 artifact installations (20.759 GiB)
```

Note that only packages in `~/.julia/packages` are deleted.

## Offline Mode

In offline mode Pkg tries to do as much as possible without connecting
to internet. For example, when adding a package Pkg only considers
versions that are already downloaded in version resolution.

To work in offline mode use `import Pkg; Pkg.offline(true)` or set the environment 
variable `JULIA_PKG_OFFLINE` to `"true"`.

## Pkg client/server

!!! compat "Julia 1.4"
    Pkg client/server feature requires at least Julia 1.4. It is opt-in for Julia 1.4 and is enabled
    by default since Julia 1.5.

When you add a new registered package, usually three things would happen:

1. update registries,
2. download source codes of the package,
3. if not available, download [artifacts](@ref Artifacts) required by the package.

The [General](https://github.com/JuliaRegistries/General) registry and most packages in it are
developed on Github, while the artifacts data are hosted in various platforms. When the network
connection to Github and AWS S3 is not stable, it is usually not a good experience to install or
update packages. Fortunately, the pkg client/server feature improves the experience in the sense that:

1. If set, pkg client would first try to download data from the pkg server,
2. if that fails, then it falls back to download from the original sources (e.g., Github).

Since Julia 1.5, `https://pkg.julialang.org` provided by the JuliaLang org. is used as the default
pkg server. In most cases this should be transparent, but users can still set/unset an pkg server
upstream via the environment variable `JULIA_PKG_SERVER`.

```julia
# manually set it to some pkg server
julia> ENV["JULIA_PKG_SERVER"] = "pkg.julialang.org"
"pkg.julialang.org"

# unset to always download data from original sources
julia> ENV["JULIA_PKG_SERVER"] = ""
""
```

For clarification, some sources are not provided by Pkg server

* packages/registries fetched via `git`
  * `]add https://github.com/JuliaLang/Example.jl.git`
  * `]add Example#v0.5.3` (Note that this is different from `]add Example@0.5.3`)
  * `]registry add https://github.com/JuliaRegistries/General.git`, including registries installed by Julia before 1.4.
* artifacts without download info
  * [TestImages](https://github.com/JuliaImages/TestImages.jl/blob/eaa94348df619c65956e8cfb0032ecddb7a29d3a/Artifacts.toml#L1-L2)


!!! note
    If you have a new registry installed via pkg server, then it's impossible for old Julia versions to
    update the registry because Julia before 1.4 don't know how to fetch new data.
    Hence, for users that frequently switches between multiple julia versions, it is recommended to
    still use git-controlled regsitries.

For the deployment of pkg server, please refer to [PkgServer.jl](https://github.com/JuliaPackaging/PkgServer.jl).
