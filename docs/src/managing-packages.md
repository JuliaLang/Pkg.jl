# [**3.** Managing Packages](@id Managing-Packages)

## Adding packages

There are two ways of adding packages, either using the `add` command or the `dev` command.
The most frequently used is `add` and its usage is described first.

### Adding registered packages

In the Pkg REPL, packages can be added with the `add` command followed by the name of the package, for example:

```julia-repl
(@v1.10) pkg> add JSON
  Installing known registries into `~/`
   Resolving package versions...
   Installed Parsers ─ v2.4.0
   Installed JSON ──── v0.21.3
    Updating `~/.julia/environments/v1.10/Project.toml`
  [682c06a0] + JSON v0.21.3
    Updating `~/.julia/environments/v1.10/Manifest.toml`
  [682c06a0] + JSON v0.21.3
  [69de0a69] + Parsers v2.4.0
  [ade2ca70] + Dates
  [a63ad114] + Mmap
  [de0858da] + Printf
  [4ec0a83e] + Unicode
Precompiling environment...
  2 dependencies successfully precompiled in 2 seconds
```

Here we added the package `JSON` to the current environment (which is the default `@v1.10` environment).
In this example, we are using a fresh Julia installation,
and this is our first time adding a package using Pkg. By default, Pkg installs the General registry
and uses this registry to look up packages requested for inclusion in the current environment.
The status update shows a short form of the package UUID to the left, then the package name, and the version.
Finally, the newly installed packages are "precompiled".

It is possible to add multiple packages in one command as `pkg> add A B C`.

The status output contains the packages you have added yourself, in this case, `JSON`:

```julia-repl
(@v1.10) pkg> st
    Status `~/.julia/environments/v1.10/Project.toml`
  [682c06a0] JSON v0.21.3
```

The manifest status shows all the packages in the environment, including recursive dependencies:

```julia-repl
(@v1.10) pkg> st -m
Status `~/.julia/environments/v1.10/Manifest.toml`
  [682c06a0] JSON v0.21.3
  [69de0a69] Parsers v2.4.0
  [ade2ca70] Dates
  [a63ad114] Mmap
  [de0858da] Printf
  [4ec0a83e] Unicode
```

Since standard libraries (e.g. ` Dates`) are shipped with Julia, they do not have a version.

To specify that you want a particular version (or set of versions) of a package, use the `compat` command. For example,
to require any patch release of the v0.21 series of JSON after v0.21.4, call `compat JSON 0.21.4`:

```julia-repl
(@v1.10) pkg> compat JSON 0.21.4
      Compat entry set:
  JSON = "0.21.4"
     Resolve checking for compliance with the new compat rules...
       Error empty intersection between JSON@0.21.3 and project compatibility 0.21.4 - 0.21
  Suggestion Call `update` to attempt to meet the compatibility requirements.

(@v1.10) pkg> update
    Updating registry at `~/.julia/registries/General.toml`
    Updating `~/.julia/environments/v1.10/Project.toml`
  [682c06a0] ↑ JSON v0.21.3 ⇒ v0.21.4
    Updating `~/.julia/environments/v1.10/Manifest.toml`
  [682c06a0] ↑ JSON v0.21.3 ⇒ v0.21.4
```

See the section on [Compatibility](@ref) for more on using the compat system.

After a package is added to the project, it can be loaded in Julia:

```julia-repl
julia> using JSON

julia> JSON.json(Dict("foo" => [1, "bar"])) |> print
{"foo":[1,"bar"]}
```

!!! note
    Only packages that have been added with `add` can be loaded (which are packages that are shown when using `st` in the Pkg REPL). Packages that are pulled in only as dependencies (for example the `Parsers` package above) can not be loaded.

A specific version of a package can be installed by appending a version after a `@` symbol to the package name:

```julia-repl
(@v1.10) pkg> add JSON@0.21.1
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
⌃ [682c06a0] + JSON v0.21.1
    Updating `~/.julia/environments/v1.10/Manifest.toml`
⌃ [682c06a0] + JSON v0.21.1
⌅ [69de0a69] + Parsers v1.1.2
  [ade2ca70] + Dates
  [a63ad114] + Mmap
  [de0858da] + Printf
  [4ec0a83e] + Unicode
        Info Packages marked with ⌃ and ⌅ have new versions available, but those with ⌅ are restricted by compatibility constraints from upgrading. To see why use `status --outdated -m`
```

As seen above, Pkg gives some information when a package is not installed at its latest version.

If not all three numbers are given for the version, for example, `0.21`, then the latest registered version of `0.21.x` would be installed.

If a branch (or a certain commit) of `Example` has a hotfix that is not yet included in a registered version,
we can explicitly track that branch (or commit) by appending `#branchname` (or `#commitSHA1`) to the package name:

```julia-repl
(@v1.10) pkg> add Example#master
     Cloning git-repo `https://github.com/JuliaLang/Example.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
  [7876af07] + Example v0.5.4 `https://github.com/JuliaLang/Example.jl.git#master`
    Updating `~/.julia/environments/v1.10/Manifest.toml`
  [7876af07] + Example v0.5.4 `https://github.com/JuliaLang/Example.jl.git#master`
```

The status output now shows that we are tracking the `master` branch of `Example`.
When updating packages, updates are pulled from that branch.

!!! note
    If we would specify a commit id instead of a branch name, e.g.
    `add Example#025cf7e`, then we would effectively "pin" the package
    to that commit. This is because the commit id always points to the same
    thing unlike a branch, which may be updated.

To go back to tracking the registry version of `Example`, the command `free` is used:

```julia-repl
(@v1.10) pkg> free Example
   Resolving package versions...
   Installed Example ─ v0.5.3
    Updating `~/.julia/environments/v1.10/Project.toml`
  [7876af07] ~ Example v0.5.4 `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v0.5.3
    Updating `~/.julia/environments/v1.10/Manifest.toml`
  [7876af07] ~ Example v0.5.4 `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v0.5.3
```

### Adding unregistered packages

If a package is not in a registry, it can be added by specifying a URL to the Git repository:

```julia-repl
(@v1.10) pkg> add https://github.com/fredrikekre/ImportMacros.jl
     Cloning git-repo `https://github.com/fredrikekre/ImportMacros.jl`
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
  [92a963f6] + ImportMacros v1.0.0 `https://github.com/fredrikekre/ImportMacros.jl#master`
    Updating `~/.julia/environments/v1.10/Manifest.toml`
  [92a963f6] + ImportMacros v1.0.0 `https://github.com/fredrikekre/ImportMacros.jl#master`
```

The dependencies of the unregistered package (here `MacroTools`) got installed.
For unregistered packages, we could have given a branch name (or commit SHA1) to track using `#`, just like for registered packages.

If you want to add a package using the SSH-based `git` protocol, you have to use quotes because the URL contains a `@`. For example,
```julia-repl
(@v1.10) pkg> add "git@github.com:fredrikekre/ImportMacros.jl.git"
    Cloning git-repo `git@github.com:fredrikekre/ImportMacros.jl.git`
   Updating registry at `~/.julia/registries/General`
  Resolving package versions...
Updating `~/.julia/environments/v1/Project.toml`
  [92a963f6] + ImportMacros v1.0.0 `git@github.com:fredrikekre/ImportMacros.jl.git#master`
Updating `~/.julia/environments/v1/Manifest.toml`
  [92a963f6] + ImportMacros v1.0.0 `git@github.com:fredrikekre/ImportMacros.jl.git#master`
```


#### Adding a package in a subdirectory of a repository

If the package you want to add by URL is not in the root of the repository, then you need pass that subdirectory using `:`.
For instance, to add the `SnoopCompileCore` package in the [SnoopCompile](https://github.com/timholy/SnoopCompile.jl)
repository:

```julia-repl
pkg> add https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore
    Cloning git-repo `https://github.com/timholy/SnoopCompile.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
  [e2b509da] + SnoopCompileCore v2.9.0 `https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore#master`
    Updating `~/.julia/environments/v1.8/Manifest.toml`
  [e2b509da] + SnoopCompileCore v2.9.0 `https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore#master`
  [9e88b42a] + Serialization
```

### Adding a local package

Instead of giving a URL of a git repo to `add` we could instead have given a local path **to a git repo**.
This works similar to adding a URL. The local repository will be tracked (at some branch) and updates
from that local repo are pulled when packages are updated.

!!! warning
    Note that tracking a package through `add` is distinct from
    `develop` (which is described in the next section). When using `add` on a local
    git repository, changes to files in the local package repository will not
    immediately be reflected when loading that package. The changes would have to be
    committed and the packages updated in order to pull in the changes. In the
    majority of cases, you want to use `develop` on a local path, **not `add`**.

### [Developing packages](@id developing)

By only using `add` your environment always has a "reproducible state", in other words, as long as the repositories and registries used are still accessible
it is possible to retrieve the exact state of all the dependencies in the environment. This has the advantage that you can send your environment (`Project.toml`
and `Manifest.toml`) to someone else and they can [`Pkg.instantiate`](@ref) that environment in the same state as you had it locally.
However, when you are [developing a package](@ref developing), it is more convenient to load packages at their current state at some path. For this reason, the `dev` command exists.

Let's try to `dev` a registered package:

```julia-repl
(@v1.10) pkg> dev Example
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
  [7876af07] + Example v0.5.4 `~/.julia/dev/Example`
    Updating `~/.julia/environments/v1.8/Manifest.toml`
  [7876af07] + Example v0.5.4 `~/.julia/dev/Example`
```

The `dev` command fetches a full clone of the package to `~/.julia/dev/` (the path can be changed by setting the environment variable `JULIA_PKG_DEVDIR`, the default being `joinpath(DEPOT_PATH[1],"dev")`).
When importing `Example` julia will now import it from `~/.julia/dev/Example` and whatever local changes have been made to the files in that path are consequently
reflected in the code loaded. When we used `add` we said that we tracked the package repository; we here say that we track the path itself.
Note the package manager will never touch any of the files at a tracked path. It is therefore up to you to pull updates, change branches, etc.
If we try to `dev` a package at some branch that already exists at `~/.julia/dev/` the package manager will simply re-use the existing path.
If `dev` is used on a local path, that path to that package is recorded and used when loading that package.
The path will be recorded relative to the project file, unless it is given as an absolute path.

Let's try modify the file at  `~/.julia/dev/Example/src/Example.jl` and add a simple function:

```julia
plusone(x::Int) = x + 1
```

Now we can go back to the Julia REPL and load the package and run the new function:

```julia-repl
julia> import Example
[ Info: Precompiling Example [7876af07-990d-54b4-ab0e-23690620f79a]

julia> Example.plusone(1)
2
```

!!! warning
    A package can only be loaded once per Julia session.
    If you have run `import Example` in the current Julia session, you will
    have to restart Julia to see the changes to Example.
    [Revise.jl](https://github.com/timholy/Revise.jl/) can make this process
    significantly more pleasant, but setting it up is beyond the scope of this guide.


To stop tracking a path and use the registered version again, use `free`:

```julia-repl
(@v1.10) pkg> free Example
   Resolving package versions...
    Updating `~/.julia/environments/v1.10/Project.toml`
  [7876af07] ~ Example v0.5.4 `~/.julia/dev/Example` ⇒ v0.5.3
    Updating `~/.julia/environments/v1.8/Manifest.toml`
  [7876af07] ~ Example v0.5.4 `~/.julia/dev/Example` ⇒ v0.5.3
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


## Removing packages

Packages can be removed from the current project by using `pkg> rm Package`.
This will only remove packages that exist in the project; to remove a package that only
exists as a dependency use `pkg> rm --manifest DepPackage`.
Note that this will remove all packages that (recursively) depend on `DepPackage`.

## [Updating packages](@id updating)

When new versions of packages are released, it is a good idea to update. Simply calling `up` will try to update *all* the dependencies of the project
to the latest compatible version. Sometimes this is not what you want. You can specify a subset of the dependencies to upgrade by giving them as arguments to `up`, e.g:

```julia-repl
(@v1.10) pkg> up Example
```

This will only allow Example do upgrade. If you also want to allow dependencies of Example to upgrade (with the exception of packages that are in the project) you can pass the `--preserve=direct` flag.

```julia-repl
(@v1.10) pkg> up --preserve=direct Example
```

And if you also want to allow dependencies of Example that are also in the project to upgrade, you can use `--preserve=none`:


```julia-repl
(@v1.10) pkg> up --preserve=none Example
```
## Pinning a package

A pinned package will never be updated. A package can be pinned using `pin`, for example:

```julia-repl
(@v1.10) pkg> pin Example
 Resolving package versions...
  Updating `~/.julia/environments/v1.10/Project.toml`
  [7876af07] ~ Example v0.5.3 ⇒ v0.5.3 ⚲
  Updating `~/.julia/environments/v1.8/Manifest.toml`
  [7876af07] ~ Example v0.5.3 ⇒ v0.5.3 ⚲
```

Note the pin symbol `⚲` showing that the package is pinned. Removing the pin is done using `free`

```julia-repl
(@v1.10) pkg> free Example
  Updating `~/.julia/environments/v1.10/Project.toml`
  [7876af07] ~ Example v0.5.3 ⚲ ⇒ v0.5.3
  Updating `~/.julia/environments/v1.8/Manifest.toml`
  [7876af07] ~ Example v0.5.3 ⚲ ⇒ v0.5.3
```

## Testing packages

The tests for a package can be run using `test` command:

```julia-repl
(@v1.10) pkg> test Example
...
   Testing Example
   Testing Example tests passed
```

## Building packages

The build step of a package is automatically run when a package is first installed.
The output of the build process is directed to a file.
To explicitly run the build step for a package, the `build` command is used:

```julia-repl
(@v1.10) pkg> build IJulia
    Building Conda ─→ `~/.julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/6e47d11ea2776bc5627421d59cdcc1296c058071/build.log`
    Building IJulia → `~/.julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/98ab633acb0fe071b671f6c1785c46cd70bb86bd/build.log`

julia> print(read(joinpath(homedir(), ".julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/98ab633acb0fe071b671f6c1785c46cd70bb86bd/build.log"), String))
[ Info: Installing Julia kernelspec in /home/kc/.local/share/jupyter/kernels/julia-1.8
```

## [Interpreting and resolving version conflicts](@id conflicts)

An environment consists of a set of mutually-compatible packages.
Sometimes, you can find yourself in a situation in which two packages you'd like to use simultaneously
have incompatible requirements.
In such cases you'll get an "Unsatisfiable requirements" error:

!!! note "Dependency Resolver"
    Pkg uses a SAT-based dependency resolver by default, which provides more robust conflict resolution and clearer error messages. You can switch to the legacy MaxSum resolver by setting the environment variable `JULIA_PKG_RESOLVER=maxsum` if needed or by passing the `resolver=:maxsum` to functions.

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

!!! note
    When tackling these conflicts, first consider that the bigger a project gets, the more likely this is to happen.
    Using targeted projects for a given task is highly recommended, and removing unused dependencies is a good first
    step when hitting these issues.
    For instance, a common pitfall is having more than a few packages in your default (i.e. `(@1.8)`) environment,
    and using that as an environment for all tasks you're using julia for. It's better to create a dedicated project
    for the task you're working on, and keep the dependencies there minimal. To read more see
    [Working with Environments](@ref Working-with-Environments)

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

Here again, the vertical stroke aligns with `D`: this means that `D` is *also* required by another package, `C`.
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

So we can see that `A` was explicitly required, and in this case, it's because we were trying to
`add` it to our environment.

In summary, we explicitly asked to use `A` and `B`, but this gave a conflict for `D`.
The reason was that `B` and `C` require conflicting versions of `D`.
Even though `C` isn't something we asked for explicitly, it was needed by `A`.

To fix such errors, you have a number of options:

- try [updating your packages](@ref updating). It's possible the developers of these packages have recently released new versions that are mutually compatible.
- remove either `A` or `B` from your environment. Perhaps `B` is left over from something you were previously working on, and you don't need it anymore. If you don't need `A` and `B` at the same time, this is the easiest way to fix the problem.
- try reporting your conflict. In this case, we were able to deduce that `B` requires an outdated version of `D`. You could thus report an issue in the development repository of `B.jl` asking for an updated version.
- try fixing the problem yourself.
  This becomes easier once you understand `Project.toml` files and how they declare their compatibility requirements. We'll return to this example in [Fixing conflicts](@ref Fixing-conflicts).

## Yanked packages

Package registries can mark specific versions of packages as "yanked". A yanked package version
is one that should no longer be used, typically because it contains serious bugs, security
vulnerabilities, or other critical issues. When a package version is yanked, it becomes
unavailable for new installations but remains accessible (i.e. via `instantiate`) to maintain reproducibility
of existing environments.

When you run `pkg> status`, yanked packages are clearly marked with a warning symbol:

```julia-repl
(@v1.13) pkg> status
    Status `~/.julia/environments/v1.13/Project.toml`
  [682c06a0] JSON v0.21.3
  [f4259836] Example v1.2.0 [yanked]
```

The `[yanked]` annotation indicate that version `v1.2.0` of the `Example` package
has been yanked and should be updated or replaced.

When resolving dependencies, Pkg will warn you if yanked packages are present and may provide
guidance on how to resolve the situation. It's important to address yanked packages promptly
to ensure the security and stability of your Julia environment.

## Garbage collecting old, unused packages

As packages are updated and projects are deleted, installed package versions and artifacts that were
once used will inevitably become old and not used from any existing project.
`Pkg` keeps a log of all projects used so it can go through the log and see exactly which projects still exist
and what packages/artifacts those projects used.
If a package or artifact is not marked as used by any project, it is added to a list of orphaned packages.
Packages and artifacts that are in the orphan list for 30 days without being used again are deleted from the system on the next garbage collection.
This timing is configurable via the `collect_delay` keyword argument to `Pkg.gc()`.
A value of `0` will cause anything currently not in use to be collected immediately, skipping the orphans list entirely;
If you are short on disk space and want to clean out as many unused packages and artifacts as possible, you may want to try this, but if you need these versions again, you will have to download them again.
To run a typical garbage collection with default arguments, simply use the `gc` command at the `pkg>` REPL:

```julia-repl
(@v1.10) pkg> gc
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

In offline mode, Pkg tries to do as much as possible without connecting
to internet. For example, when adding a package Pkg only considers
versions that are already downloaded in version resolution.

To work in offline mode use `import Pkg; Pkg.offline(true)` or set the environment
variable `JULIA_PKG_OFFLINE` to `"true"`.

## Pkg client/server

When you add a new registered package, usually three things would happen:

1. update registries,
2. download the source code of the package,
3. if not available, download [artifacts](@ref Artifacts) required by the package.

The [General](https://github.com/JuliaRegistries/General) registry and most packages in it are
developed on GitHub, while the artifacts data are hosted on various platforms. When the network
connection to GitHub and AWS S3 is not stable, it is usually not a good experience to install or
update packages. Fortunately, the pkg client/server feature improves the experience in the sense that:

1. If set, the pkg client would first try to download data from the pkg server,
2. if that fails, then it falls back to downloading from the original sources (e.g., GitHub).

By default, the client makes upto `8` concurrent requests to the server. This can set by the environment variable `JULIA_PKG_CONCURRENT_DOWNLOADS`.

Since Julia 1.5, `https://pkg.julialang.org` provided by the JuliaLang organization is used as the default
pkg server. In most cases, this should be transparent, but users can still set/unset a pkg server
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
    update the registry because Julia before 1.4 doesn't know how to fetch new data.
    Hence, for users that frequently switch between multiple Julia versions, it is recommended to
    still use git-controlled registries.

For the deployment of pkg server, please refer to [PkgServer.jl](https://github.com/JuliaPackaging/PkgServer.jl).
