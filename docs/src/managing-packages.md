# **3.** Managing Packages

## Adding packages

There are two ways of adding packages, either using the `add` command or the `dev` command.
The most frequently used one is `add` and its usage is described first.

### Adding registered packages

In the Pkg REPL packages can be added with the `add` command followed by the name of the package, for example:

```
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

```
(v1.0) pkg> st
    Status `Project.toml`
  [7876af07] Example v0.5.1
```

The manifest status, in addition, includes the dependencies of explicitly added packages.

```
(v1.0) pkg> st --manifest
    Status `Manifest.toml`
  [7876af07] Example v0.5.1
  [8dfed614] Test
```

It is possible to add multiple packages in one command as `pkg> add A B C`.

After a package is added to the project, it can be loaded in Julia:

```
julia> using Example

julia> Example.hello("User")
"Hello, User"
```

A specific version can be installed by appending a version after a `@` symbol, e.g. `@v0.4`, to the package name:

```
(v1.0) pkg> add Example@0.4
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] + Example v0.4.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] + Example v0.4.1
```

If the master branch (or a certain commit SHA) of `Example` has a hotfix that has not yet included in a registered version,
we can explicitly track a branch (or commit) by appending `#branch` (or `#commit`) to the package name:

```
(v1.0) pkg> add Example#master
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1+ #master (https://github.com/JuliaLang/Example.jl.git)
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1+ #master (https://github.com/JuliaLang/Example.jl.git)
```

The status output now shows that we are tracking the `master` branch of `Example`.
When updating packages, we will pull updates from that branch.

To go back to tracking the registry version of `Example`, the command `free` is used:

```
(v1.0) pkg> free Example
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1+ #master (https://github.com/JuliaLang/Example.jl.git) ⇒ v0.5.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1+ #master )https://github.com/JuliaLang/Example.jl.git) ⇒ v0.5.1
```


### Adding unregistered packages

If a package is not in a registry, it can still be added by instead of the package name giving the URL to the repository to `add`.

```
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
For unregistered packages we could have given a branch (or commit SHA) to track using `#`, just like for registered packages.


### Adding a local package

Instead of giving a URL of a git repo to `add` we could instead have given a local path to a git repo.
This works similarly to adding a URL. The local repository will be tracked (at some branch) and updates
from that local repo are pulled when packages are updated.
Note that changes to files in the local package repository will not immediately be reflected when loading that package.
The changes would have to be committed and the packages updated in order to pull in the changes.

### Developing packages

By only using `add` your Manifest will always have a "reproducible state", in other words, as long as the repositories and registries used are still accessible
it is possible to retrieve the exact state of all the dependencies in the project. This has the advantage that you can send your project (`Project.toml`
and `Manifest.toml`) to someone else and they can "instantiate" that project in the same state as you had it locally.
However, when you are developing a package, it is more convenient to load packages at their current state at some path. For this reason, the `dev` command exists.

Let's try to `dev` a registered package:

```
(v1.0) pkg> dev Example
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] + Example v0.5.1+ [`~/.julia/dev/Example`]
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] + Example v0.5.1+ [`~/.julia/dev/Example`]
```

The `dev` command fetches a full clone of the package to `~/.julia/dev/` (the path can be changed by setting the environment variable `JULIA_PKG_DEVDIR`).
When importing `Example` julia will now import it from `~/.julia/dev/Example` and whatever local changes have been made to the files in that path are consequently
reflected in the code loaded. When we used `add` we said that we tracked the package repository, we here say that we track the path itself.
Note that the package manager will never touch any of the files at a tracked path. It is therefore up to you to pull updates, change branches etc.
If we try to `dev` a package at some branch that already exists at `~/.julia/dev/` the package manager we will simply use the existing path.
For example:

```
(v1.0) pkg> dev Example
  Updating git-repo `https://github.com/JuliaLang/Example.jl.git`
[ Info: Path `/Users/kristoffer/.julia/dev/Example` exists and looks like the correct package, using existing path instead of cloning
```

Note the info message saying that it is using the existing path. As a general rule, the package manager will
never touch files that are tracking a path.

If `dev` is used on a local path, that path to that package is recorded and used when loading that package.
The path will be recorded relative to the project file, unless it is given as an absolute path.

To stop tracking a path and use the registered version again, use `free`

```
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
in the Manifest. To update sync the Manifest, use the REPL command `resolve`.

## Removing packages

Packages can be removed from the current project by using `pkg> rm Package`.
This will only remove packages that exist in the project, to remove a package that only
exists as a dependency use `pkg> rm --manifest DepPackage`.
Note that this will remove all packages that depends on `DepPackage`.

## Updating packages

When new versions of packages the project is using are released, it is a good idea to update. Simply calling `up` will try to update *all* the dependencies of the project
to the latest compatible version. Sometimes this is not what you want. You can specify a subset of the dependencies to upgrade by giving them as arguments to `up`, e.g:

```
(v1.0) pkg> up Example
```

The version of all other packages direct dependencies will stay the same. If you only want to update the minor version of packages, to reduce the risk that your project breaks, you can give the `--minor` flag, e.g:

```
(v1.0) pkg> up --minor Example
```

Packages that track a repository are not updated when a minor upgrade is done.
Packages that track a path are never touched by the package manager.

## Pinning a package

A pinned package will never be updated. A package can be pinned using `pin` as for example

```
(v1.0) pkg> pin Example
 Resolving package versions...
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1 ⚲
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1 ⇒ v0.5.1 ⚲
```

Note the pin symbol `⚲` showing that the package is pinned. Removing the pin is done using `free`

```
(v1.0) pkg> free Example
  Updating `~/.julia/environments/v1.0/Project.toml`
  [7876af07] ~ Example v0.5.1 ⚲ ⇒ v0.5.1
  Updating `~/.julia/environments/v1.0/Manifest.toml`
  [7876af07] ~ Example v0.5.1 ⚲ ⇒ v0.5.1
```

## Testing packages

The tests for a package can be run using `test`command:

```
(v1.0) pkg> test Example
   Testing Example
   Testing Example tests passed
```

## Building packages

The build step of a package is automatically run when a package is first installed.
The output of the build process is directed to a file.
To explicitly run the build step for a package the `build` command is used:

```
(v1.0) pkg> build MbedTLS
  Building MbedTLS → `~/.julia/packages/MbedTLS/h1Vu/deps/build.log`

shell> cat ~/.julia/packages/MbedTLS/h1Vu/deps/build.log
┌ Warning: `wait(t::Task)` is deprecated, use `fetch(t)` instead.
│   caller = macro expansion at OutputCollector.jl:63 [inlined]
└ @ Core OutputCollector.jl:63
...
[ Info: using prebuilt binaries
```
## Garbage collecting old, unused packages

As packages are updated and projects are deleted, installed packages that were once used will inevitably
become old and not used from any existing project.
Pkg keeps a log of all projects used so it can go through the log and see exactly which projects still exist
and what packages those projects used. The rest can be deleted.
This is done with the `gc` command:

```
(v1.0) pkg> gc
    Active manifests at:
        `/Users/kristoffer/BinaryProvider/Manifest.toml`
        ...
        `/Users/kristoffer/Compat.jl/Manifest.toml`
   Deleted /Users/kristoffer/.julia/packages/BenchmarkTools/1cAj: 146.302 KiB
   Deleted /Users/kristoffer/.julia/packages/Cassette/BXVB: 795.557 KiB
   ...
   Deleted /Users/kristoffer/.julia/packages/WeakRefStrings/YrK6: 27.328 KiB
   Deleted 36 package installations: 113.205 MiB
```

Note that only packages in `~/.julia/packages` are deleted.


## Preview mode

If you just want to see the effects of running a command, but not change your state you can `preview` a command.
For example:

```
(HelloWorld) pkg> preview add Plots
```

or

```
(HelloWorld) pkg> preview up
```

will show you the effects of adding `Plots`, or doing a full upgrade, respectively, would have on your project.
However, nothing would be installed and your `Project.toml` and `Manifest.toml` are untouched.
