# [**3.** Managing Packages](@id Managing-Packages)

## Adding packages

There are two ways of adding packages, either using the `add` command or the `dev` command.
The most frequently used is `add` and its usage is described first.

### Adding registered packages

In the Pkg REPL, packages can be added with the `add` command followed by the name of the package, for example:

```julia-repl
(@v{{VERSION}}) pkg> add JSON
  Installing known registries into `~/.julia`
       Added `General` registry to ~/.julia/registries
   Resolving package versions...
   Installed Parsers ───────── v3.0.6
   Installed StructUtils ───── v2.12.1
   Installed JSON ──────────── v1.13.4
   Installed Preferences ───── v1.6.1
   Installed PrecompileTools ─ v1.4.0
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [682c06a0] + JSON v1.13.4
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [682c06a0] + JSON v1.13.4
  [69de0a69] + Parsers v3.0.6
  [aea7be01] + PrecompileTools v1.4.0
  [21216c6a] + Preferences v1.6.1
  [ec057cc2] + StructUtils v2.12.1
  [ade2ca70] + Dates v1.11.0
  [56ddb016] + Logging v1.11.0
  [de0858da] + Printf v1.11.0
  [9a3f8284] + Random v1.11.0
  [ea8e919c] + SHA v1.13.0
  [fa267f1f] + TOML v1.0.3
  [cf7118a7] + UUIDs v1.11.0
  [4ec0a83e] + Unicode v1.11.0
Precompiling packages...
  5 dependencies successfully precompiled in 5 seconds. 7 already precompiled.
```

Here we added the package `JSON` to the current environment (which is the default `@v{{VERSION}}` environment).
In this example, we are using a fresh Julia installation,
and this is our first time adding a package using Pkg. By default, Pkg installs the General registry
and uses this registry to look up packages requested for inclusion in the current environment.
The status update shows a short form of the package UUID to the left, then the package name, and the version.
Finally, the newly installed packages are "precompiled".

It is possible to add multiple packages in one command as `pkg> add A B C`.

The status output contains the packages you have added yourself, in this case, `JSON`:

```julia-repl
(@v{{VERSION}}) pkg> st
Status `~/.julia/environments/v{{VERSION}}/Project.toml`
  [682c06a0] JSON v1.13.4
```

The manifest status shows all the packages in the environment, including recursive dependencies:

```julia-repl
(@v{{VERSION}}) pkg> st -m
Status `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [682c06a0] JSON v1.13.4
  [69de0a69] Parsers v3.0.6
  [aea7be01] PrecompileTools v1.4.0
  [21216c6a] Preferences v1.6.1
  [ec057cc2] StructUtils v2.12.1
  [ade2ca70] Dates v1.11.0
  [56ddb016] Logging v1.11.0
  [de0858da] Printf v1.11.0
  [9a3f8284] Random v1.11.0
  [ea8e919c] SHA v1.13.0
  [fa267f1f] TOML v1.0.3
  [cf7118a7] UUIDs v1.11.0
  [4ec0a83e] Unicode v1.11.0
```

Note that before 1.11 standard libraries (e.g. ` Dates`) did not have dedicated version numbers.

To specify that you want a particular version (or set of versions) of a package, use the `compat` command. For example,
if JSON v0.21.3 is installed, to require any patch release of the v0.21 series of JSON from v0.21.4 on, call `compat JSON 0.21.4`:

```julia-repl
(@v{{VERSION}}) pkg> compat JSON 0.21.4
      Compat entry set:
  JSON = "0.21.4"
     Resolve checking for compliance with the new compat rules...
       Error empty intersection between JSON@0.21.3 (recorded in the manifest) and project compatibility 0.21.4 - 0.21
The project has a compat entry for JSON:
 * /home/user/.julia/environments/v{{VERSION}}/Project.toml:5: JSON = "0.21.4"
  Suggestion Call `update` to attempt to meet the compatibility requirements.

(@v{{VERSION}}) pkg> update
    Updating registry at `~/.julia/registries/General.toml`
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
⌃ [682c06a0] ↑ JSON v0.21.3 ⇒ v0.21.4
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
⌃ [682c06a0] ↑ JSON v0.21.3 ⇒ v0.21.4
        Info Packages marked with ⌃ have new versions available. Use `status --outdated -m` to see which of them an update upgrades and what holds the others back.
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
(@v{{VERSION}}) pkg> add JSON@0.21.1
   Resolving package versions...
   Installed Parsers ─ v1.1.2
   Installed JSON ──── v0.21.1
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
⌃ [682c06a0] + JSON v0.21.1
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
⌃ [682c06a0] + JSON v0.21.1
⌃ [69de0a69] + Parsers v1.1.2
  [ade2ca70] + Dates v1.11.0
  [a63ad114] + Mmap v1.11.0
  [de0858da] + Printf v1.11.0
  [9e88b42a] + Serialization v1.11.0
  [4ec0a83e] + Unicode v1.11.0
        Info Packages marked with ⌃ have new versions available. Use `status --outdated -m` to see which of them an update upgrades and what holds the others back.
```

As seen above, Pkg gives some information when a package is not installed at its latest version.

If not all three numbers are given for the version, for example, `0.21`, then the latest registered version of `0.21.x` would be installed.

If a branch (or a certain commit) of `Example` has a hotfix that is not yet included in a registered version,
we can explicitly track that branch (or commit) by appending `#branchname` (or `#commitSHA1`) to the package name:

```julia-repl
(@v{{VERSION}}) pkg> add Example#master
     Cloning git-repo `https://github.com/JuliaLang/Example.jl.git`
    Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] + Example v0.5.5 `https://github.com/JuliaLang/Example.jl.git#master`
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [7876af07] + Example v0.5.5 `https://github.com/JuliaLang/Example.jl.git#master`
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
(@v{{VERSION}}) pkg> free Example
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] ~ Example v0.5.5 `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v0.5.5
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [7876af07] ~ Example v0.5.5 `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v0.5.5
```

Adding a package may change the versions of packages that are already in the environment, when that
is needed to find a set of versions that work together. To keep every package as it is and add only
versions that are already installed, so that nothing new is downloaded, use `--preserve=installed`:

```julia-repl
(@v{{VERSION}}) pkg> add --preserve=installed Example
```

This fails if no such versions work together. `--preserve=tiered_installed` tries it first and
otherwise falls back to the default; setting the environment variable
`JULIA_PKG_PRESERVE_TIERED_INSTALLED=true` makes that the default. `pkg> ?add` describes the other
`--preserve` options.

### Adding unregistered packages

If a package is not in a registry, it can be added by specifying a URL to the Git repository:

```julia-repl
(@v{{VERSION}}) pkg> add https://github.com/fredrikekre/ImportMacros.jl
     Cloning git-repo `https://github.com/fredrikekre/ImportMacros.jl`
    Updating git-repo `https://github.com/fredrikekre/ImportMacros.jl`
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [92a963f6] + ImportMacros v1.0.0 `https://github.com/fredrikekre/ImportMacros.jl#master`
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [92a963f6] + ImportMacros v1.0.0 `https://github.com/fredrikekre/ImportMacros.jl#master`
```

For unregistered packages, we could have given a branch name (or commit SHA1) to track using `#`, just like for registered packages.

A link to a branch, a commit or a pull request on GitHub works too, which is handy for trying out a fix
before it is released:

```julia-repl
(@v{{VERSION}}) pkg> add https://github.com/JuliaLang/Example.jl/tree/mybranch
(@v{{VERSION}}) pkg> add https://github.com/JuliaLang/Example.jl/commit/025cf7e
(@v{{VERSION}}) pkg> add https://github.com/JuliaLang/Example.jl/pull/123
```

These are the same as giving the repository URL with `#mybranch`, `#025cf7e` and `#pull/123/head`.

!!! compat "Julia 1.13"
    Links to pull requests require at least Julia 1.13.

If you want to add a package using the SSH-based `git` protocol, you have to use quotes because the URL contains a `@`. For example,
```julia-repl
(@v{{VERSION}}) pkg> add "git@github.com:fredrikekre/ImportMacros.jl.git"
     Cloning git-repo `git@github.com:fredrikekre/ImportMacros.jl.git`
    Updating git-repo `git@github.com:fredrikekre/ImportMacros.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [92a963f6] + ImportMacros v1.0.0 `git@github.com:fredrikekre/ImportMacros.jl.git#master`
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [92a963f6] + ImportMacros v1.0.0 `git@github.com:fredrikekre/ImportMacros.jl.git#master`
```


#### Adding a package in a subdirectory of a repository

If the package you want to add by URL is not in the root of the repository, then you need pass that subdirectory using `:`.
For instance, to add the `SnoopCompileCore` package in the [SnoopCompile](https://github.com/timholy/SnoopCompile.jl)
repository:

```julia-repl
(@v{{VERSION}}) pkg> add https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore
     Cloning git-repo `https://github.com/timholy/SnoopCompile.jl.git`
    Updating git-repo `https://github.com/timholy/SnoopCompile.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [e2b509da] + SnoopCompileCore v3.1.4 `https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore#master`
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [e2b509da] + SnoopCompileCore v3.1.4 `https://github.com/timholy/SnoopCompile.jl.git:SnoopCompileCore#master`
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
(@v{{VERSION}}) pkg> dev Example
     Cloning git-repo `https://github.com/JuliaLang/Example.jl.git`
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] + Example v0.5.5 `~/.julia/dev/Example`
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [7876af07] + Example v0.5.5 `~/.julia/dev/Example`
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
(@v{{VERSION}}) pkg> free Example
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] ~ Example v0.5.5 `~/.julia/dev/Example` ⇒ v0.5.5
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [7876af07] ~ Example v0.5.5 `~/.julia/dev/Example` ⇒ v0.5.5
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
(@v{{VERSION}}) pkg> up Example
```

This will only allow Example do upgrade. If you also want to allow dependencies of Example to upgrade (with the exception of packages that are in the project) you can pass the `--preserve=direct` flag.

```julia-repl
(@v{{VERSION}}) pkg> up --preserve=direct Example
```

And if you also want to allow dependencies of Example that are also in the project to upgrade, you can use `--preserve=none`:


```julia-repl
(@v{{VERSION}}) pkg> up --preserve=none Example
```

### Why is a package not at its latest version?

A package can be held back, or even downgraded when you add another package, by the compatibility requirements
of other packages in the environment. `status` marks every package that has a newer version with `⌃`, and
`status --outdated` shows the latest version and which packages (or your own `[compat]`) don't allow it:

```julia-repl
(@v{{VERSION}}) pkg> status --outdated
Status `~/.julia/environments/v{{VERSION}}/Project.toml`
⌃ [7876af07] C v1.0.0 [<v1.1.0], (<v2.0.0): D
⌅ [756980fe] D v0.1.0 (<v0.2.1): B
```

A plain `status` only says that a newer version exists, since whether it can be installed depends on the whole
environment. `status --outdated` resolves what `up` would do, without changing anything, so here `⌃` means that
`up` upgrades the package (to the version in brackets when that is not the latest one) and `⌅` that it stays
where it is. The packages listed after a package are those that, at the version an update gives them, are not
compatible with its latest version: above, `B` does not allow `D` 0.2.1, and `C` 2.0.0 needs a newer `D`.

Add `-m` to also include packages that are only in the manifest, and use `why D` to see which packages depend on `D`.
To get the full explanation, ask for the version you expected, for example with `add D@0.2.1`.
This fails with a report of what conflicts with it (see [Interpreting and resolving version conflicts](@ref conflicts)),
which may also point out that a new release of a dependent, here `B`, is needed.
If so, check whether that package already supports the newer version on its development branch, or open an issue asking for it.

## Pinning a package

A pinned package will never be updated. A package can be pinned using `pin`, for example:

```julia-repl
(@v{{VERSION}}) pkg> pin Example
   Resolving package versions...
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] ~ Example v0.5.5 ⇒ v0.5.5 ⚲
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [7876af07] ~ Example v0.5.5 ⇒ v0.5.5 ⚲
```

Note the pin symbol `⚲` showing that the package is pinned. Removing the pin is done using `free`

```julia-repl
(@v{{VERSION}}) pkg> free Example
    Updating `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] ~ Example v0.5.5 ⚲ ⇒ v0.5.5
    Updating `~/.julia/environments/v{{VERSION}}/Manifest.toml`
  [7876af07] ~ Example v0.5.5 ⚲ ⇒ v0.5.5
```

## Testing packages

The tests for a package can be run using `test` command:

```julia-repl
(@v{{VERSION}}) pkg> test Example
     Testing Example
...
     Testing Running tests...
     Testing Example tests passed
```

## Building packages

The build step of a package is automatically run when a package is first installed.
The output of the build process is directed to a file.
To explicitly run the build step for a package, the `build` command is used:

```julia-repl
(@v{{VERSION}}) pkg> build IJulia
    Building Conda ─→ `~/.julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/6e47d11ea2776bc5627421d59cdcc1296c058071/build.log`
    Building IJulia → `~/.julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/98ab633acb0fe071b671f6c1785c46cd70bb86bd/build.log`

julia> print(read(joinpath(homedir(), ".julia/scratchspaces/44cfe95a-1eb2-52ea-b672-e2afdf69b78f/98ab633acb0fe071b671f6c1785c46cd70bb86bd/build.log"), String))
[ Info: Installing Julia kernelspec in /home/kc/.local/share/jupyter/kernels/julia-{{VERSION}}
```

## [Interpreting and resolving version conflicts](@id conflicts)

An environment consists of a set of mutually-compatible packages.
Sometimes, you can find yourself in a situation in which two packages you'd like to use simultaneously
have incompatible requirements.
In such cases you'll get an "Unsatisfiable requirements" error.
For example, with a package `B` already in the environment, adding a package `A` might give:

```julia-repl
(@v{{VERSION}}) pkg> add A
   Resolving package versions...
ERROR: Unsatisfiable requirements detected — 1 conflict:

Conflict 1: A and B
  • A 1.0.0 requires C 0.2.0
  • C 0.2.0 allows no version of B (through D)
  Fix it by any one of:
    1. drop dependency A
       → allows: B 1.0.0
    2. drop dependency B
       → allows: A 1.0.0, C 0.2.0
```

!!! note
    When tackling these conflicts, first consider that the bigger a project gets, the more likely this is to happen.
    Using targeted projects for a given task is highly recommended, and removing unused dependencies is a good first
    step when hitting these issues.
    For instance, a common pitfall is having more than a few packages in your default (i.e. `(@v{{VERSION}})`) environment,
    and using that as an environment for all tasks you're using julia for. It's better to create a dedicated project
    for the task you're working on, and keep the dependencies there minimal. To read more see
    [Working with Environments](@ref Working-with-Environments)

The heading `Conflict 1: A and B` names the requirements that cannot be satisfied together:
`A`, which we are adding, and `B`, which is already in the project.
The bullets below it are the chain of facts from the registry that leads to the conflict:

- `A 1.0.0 requires C 0.2.0`: `A` (whose only release is `v1.0.0`) depends on `C`, and only `v0.2.0` of `C` is compatible with it.
- `C 0.2.0 allows no version of B (through D)`: `C` `v0.2.0` cannot be installed together with any version of `B`.
  The packages in parentheses are those the conflict passes through: here `C` `v0.2.0` requires `v0.2` of `D`
  while `B` requires `v0.1` of `D`.

So even though we never asked for `C` or `D`, they matter because `A` and `B` depend on them.
The report ends with the changes to your own requirements that would fix the conflict,
each followed (after `→ allows:`) by the versions the resolver would then pick.
Here the only options are to not have `A` or `B` in the environment, since the incompatibility comes from the
compatibility requirements of the packages themselves.

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
(@v{{VERSION}}) pkg> status
Status `~/.julia/environments/v{{VERSION}}/Project.toml`
  [7876af07] Example v0.5.4 [yanked]
  [682c06a0] JSON v1.13.4
Warning Package versions marked with [yanked] have been pulled from their registry. It is recommended to update them to resolve a valid version.
```

The `[yanked]` annotation indicates that version `v0.5.4` of the `Example` package
has been yanked and should be updated or replaced.

When resolving dependencies, Pkg will warn you if yanked packages are present and may provide
guidance on how to resolve the situation. It's important to address yanked packages promptly
to ensure the security and stability of your Julia environment.

## Garbage collecting old, unused packages

As packages are updated and projects are deleted, installed package versions and artifacts that were
once used will inevitably become old and not used from any existing project.
`Pkg` keeps a log of all projects used so it can go through the log and see exactly which projects still exist
and what packages/artifacts those projects used.
Packages and artifacts that are not used by any existing project are deleted from the system on the next garbage collection.
If you need these versions again, they will be downloaded again.
Garbage collection also runs automatically about once a week after operations such as `up`, `pin`, `free` and `rm`;
this can be disabled by setting the environment variable `JULIA_PKG_GC_AUTO` to `"false"`.
To run a garbage collection manually, simply use the `gc` command at the `pkg>` REPL:

```julia-repl
(@v{{VERSION}}) pkg> gc
      Active manifest files: 12 found
      Active artifact files: 31 found
      Active scratchspaces: 4 found
     Deleted 36 package installations (113.205 MiB)
     Deleted 15 artifact installations (20.759 GiB)
     Deleted 52 precompilation cache files (1.024 GiB)
```

Use `gc --verbose` to list each deleted package and artifact.

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
