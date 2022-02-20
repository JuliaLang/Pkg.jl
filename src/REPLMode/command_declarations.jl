const PSA = Pair{Symbol,Any}

compound_declarations = [
"package" => CommandDeclaration[
PSA[:name => "test",
    :api => API.test,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => [
        PSA[:name => "coverage", :api => :coverage => true],
    ],
    :completions => complete_installed_packages,
    :description => "run tests for packages",
    :help => md"""
    test [--coverage] pkg[=uuid] ...

Run the tests for package `pkg`. This is done by running the file `test/runtests.jl`
in the package directory. The option `--coverage` can be used to run the tests with
coverage enabled. The `startup.jl` file is disabled during testing unless
julia is started with `--startup-file=yes`.
""",
],
PSA[:name => "help",
    :short_name => "?",
    :api => identity, # dummy API function
    :arg_count => 0 => Inf,
    :arg_parser => ((x,y) -> x),
    :completions => complete_help,
    :description => "show this message",
    :help => md"""
    [?|help]

List available commands along with short descriptions.

    [?|help] cmd

If `cmd` is a partial command, display help for all subcommands.
If `cmd` is a full command, display help for `cmd`.
""",
],
PSA[:name => "instantiate",
    :api => API.instantiate,
    :option_spec => [
        PSA[:name => "project", :short_name => "p", :api => :manifest => false],
        PSA[:name => "manifest", :short_name => "m", :api => :manifest => true],
        PSA[:name => "verbose", :short_name => "v", :api => :verbose => true],
    ],
    :description => "downloads all the dependencies for the project",
    :help => md"""
    instantiate [-v|--verbose]
    instantiate [-v|--verbose] [-m|--manifest]
    instantiate [-v|--verbose] [-p|--project]

Download all the dependencies for the current project at the version given by the project's manifest.
If no manifest exists or the `--project` option is given, resolve and download the dependencies compatible with the project.

After packages have been installed the project will be precompiled. For more information see `pkg> ?precompile`.
""",
],
PSA[:name => "remove",
    :short_name => "rm",
    :api => API.rm,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => [
        PSA[:name => "project", :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        PSA[:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
        PSA[:name => "all", :api => :all_pkgs => true],
    ],
    :completions => complete_installed_packages,
    :description => "remove packages from project or manifest",
    :help => md"""
    [rm|remove] [-p|--project] pkg[=uuid] ...
    [rm|remove] [-p|--project] [--all]

Remove package `pkg` from the project file. Since the name `pkg` can only
refer to one package in a project this is unambiguous, but you can specify
a `uuid` anyway, and the command is ignored, with a warning, if package name
and UUID do not match. When a package is removed from the project file, it
may still remain in the manifest if it is required by some other package in
the project. Project mode operation is the default, so passing `-p` or
`--project` is optional unless it is preceded by the `-m` or `--manifest`
options at some earlier point. All packages can be removed by passing `--all`.

    [rm|remove] [-m|--manifest] pkg[=uuid] ...
    [rm|remove] [-m|--manifest] [--all]

Remove package `pkg` from the manifest file. If the name `pkg` refers to
multiple packages in the manifest, `uuid` disambiguates it. Removing a package
from the manifest forces the removal of all packages that depend on it, as well
as any no-longer-necessary manifest packages due to project package removals.
All packages can be removed by passing `--all`.
""",
],
PSA[:name => "add",
    :api => API.add,
    :should_splat => false,
    :arg_count => 1 => Inf,
    :arg_parser => ((x,y) -> parse_package(x,y; add_or_dev=true)),
    :option_spec => [
        PSA[:name => "preserve", :takes_arg => true, :api => :preserve => do_preserve],
    ],
    :completions => complete_add_dev,
    :description => "add packages to project",
    :help => md"""
    add [--preserve=<opt>] pkg[=uuid] [@version] [#rev] ...

Add package `pkg` to the current project file. If `pkg` could refer to
multiple different packages, specifying `uuid` allows you to disambiguate.
`@version` optionally allows specifying which versions of packages to add. Version specifications
are of the form `@1`, `@1.2` or `@1.2.3`, allowing any version with a prefix
that matches, or ranges thereof, such as `@1.2-3.4.5`. A git revision can be
specified by `#branch` or `#commit`.

If a local path is used as an argument to `add`, the path needs to be a git repository.
The project will then track that git repository just like it would track a remote repository online.
If the package is not located at the top of the git repository, a subdirectory can be specified with
`path:subdir/path`.

`Pkg` resolves the set of packages in your environment using a tiered approach.
The `--preserve` command line option allows you to key into a specific tier in the resolve algorithm.
The following table describes the command line arguments to `--preserve` (in order of strictness).

| Argument | Description                                                                         |
|:---------|:------------------------------------------------------------------------------------|
| `all`    | Preserve the state of all existing dependencies (including recursive dependencies)  |
| `direct` | Preserve the state of all existing direct dependencies                              |
| `semver` | Preserve semver-compatible versions of direct dependencies                          |
| `none`   | Do not attempt to preserve any version information                                  |
| `tiered` | Use the tier which will preserve the most version information (this is the default) |

After the installation of new packages the project will be precompiled. For more information see `pkg> ?precompile`.

!!! compat "Julia 1.5"
    Subdirectory specification requires at least Julia 1.5.

**Examples**
```
pkg> add Example
pkg> add --preserve=all Example
pkg> add Example@0.5
pkg> add Example#master
pkg> add Example#c37b675
pkg> add https://github.com/JuliaLang/Example.jl#master
pkg> add git@github.com:JuliaLang/Example.jl.git
pkg> add "git@github.com:JuliaLang/Example.jl.git"#master
pkg> add Example=7876af07-990d-54b4-ab0e-23690620f79a
```
""",
],
PSA[:name => "develop",
    :short_name => "dev",
    :api => API.develop,
    :should_splat => false,
    :arg_count => 1 => Inf,
    :arg_parser => ((x,y) -> parse_package(x,y; add_or_dev=true)),
    :option_spec => [
        PSA[:name => "strict", :api => :strict => true],
        PSA[:name => "local", :api => :shared => false],
        PSA[:name => "shared", :api => :shared => true],
        PSA[:name => "preserve", :takes_arg => true, :api => :preserve => do_preserve],
    ],
    :completions => complete_add_dev,
    :description => "clone the full package repo locally for development",
    :help => md"""
    [dev|develop] [--preserve=<opt>] [--shared|--local] pkg[=uuid] ...
    [dev|develop] [--preserve=<opt>] path

Make a package available for development. If `pkg` is an existing local path, that path will be recorded in
the manifest and used. Otherwise, a full git clone of `pkg` is made. The location of the clone is
controlled by the `--shared` (default) and `--local` arguments. The `--shared` location defaults to
`~/.julia/dev`, but can be controlled with the `JULIA_PKG_DEVDIR` environment variable.

When `--local` is given, the clone is placed in a `dev` folder in the current project. This
is not supported for paths, only registered packages.

This operation is undone by `free`.

**Examples**
```jl
pkg> develop Example
pkg> develop https://github.com/JuliaLang/Example.jl
pkg> develop ~/mypackages/Example
pkg> develop --local Example
```
""",
],
PSA[:name => "free",
    :api => API.free,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :option_spec => [
        PSA[:name => "all", :api => :all_pkgs => true],
    ],
    :arg_parser => parse_package,
    :completions => complete_installed_packages,
    :description => "undoes a `pin`, `develop`, or stops tracking a repo",
    :help => md"""
    free pkg[=uuid] ...
    free [--all]

Free pinned packages, which allows it to be upgraded or downgraded again. If the package is checked out (see `help develop`) then this command
makes the package no longer being checked out.
""",
],
PSA[:name => "pin",
    :api => API.pin,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :option_spec => [
        PSA[:name => "all", :api => :all_pkgs => true],
    ],
    :arg_parser => parse_package,
    :completions => complete_installed_packages,
    :description => "pins the version of packages",
    :help => md"""
    pin pkg[=uuid] ...
    pin [--all]

Pin packages to given versions, or the current version if no version is specified. A pinned package has its version fixed and will not be upgraded or downgraded.
A pinned package has the symbol `⚲` next to its version in the status list.

**Examples**
```
pkg> pin Example
pkg> pin Example@0.5.0
pkg> pin Example=7876af07-990d-54b4-ab0e-23690620f79a@0.5.0
pkg> pin --all
```
""",
],
PSA[:name => "build",
    :api => API.build,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => [
        PSA[:name => "verbose", :short_name => "v", :api => :verbose => true],
    ],
    :completions => complete_installed_packages,
    :description => "run the build script for packages",
    :help => md"""
    build [-v|--verbose] pkg[=uuid] ...

Run the build script in `deps/build.jl` for `pkg` and all of its dependencies in depth-first recursive order.
If no packages are given, run the build scripts for all packages in the manifest.
The `-v`/`--verbose` option redirects build output to `stdout`/`stderr` instead of the `build.log` file.
The `startup.jl` file is disabled during building unless julia is started with `--startup-file=yes`.
""",
],
PSA[:name => "resolve",
    :api => API.resolve,
    :description => "resolves to update the manifest from changes in dependencies of developed packages",
    :help => md"""
    resolve

Resolve the project i.e. run package resolution and update the Manifest. This is useful in case the dependencies of developed
packages have changed causing the current Manifest to be out of sync.
""",
],
PSA[:name => "activate",
    :api => API.activate,
    :arg_count => 0 => 1,
    :arg_parser => parse_activate,
    :option_spec => [
        PSA[:name => "shared", :api => :shared => true],
        PSA[:name => "temp", :api => :temp => true],
    ],
    :completions => complete_activate,
    :description => "set the primary environment the package manager manipulates",
    :help => md"""
    activate
    activate [--shared] path
    activate --temp

Activate the environment at the given `path`, or the home project environment if no `path` is specified.
The active environment is the environment that is modified by executing package commands.
When the option `--shared` is given, `path` will be assumed to be a directory name and searched for in the
`environments` folders of the depots in the depot stack. In case no such environment exists in any of the depots,
it will be placed in the first depot of the stack.
Use the `--temp` option to create temporary environments which are removed when the julia
process is exited.
""" ,
],
PSA[:name => "update",
    :short_name => "up",
    :api => API.up,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => [
        PSA[:name => "project",  :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        PSA[:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
        PSA[:name => "major", :api => :level => UPLEVEL_MAJOR],
        PSA[:name => "minor", :api => :level => UPLEVEL_MINOR],
        PSA[:name => "patch", :api => :level => UPLEVEL_PATCH],
        PSA[:name => "fixed", :api => :level => UPLEVEL_FIXED],
    ],
    :completions => complete_installed_packages,
    :description => "update packages in manifest",
    :help => md"""
    [up|update] [-p|--project]  [opts] pkg[=uuid] [@version] ...
    [up|update] [-m|--manifest] [opts] pkg[=uuid] [@version] ...

    opts: --major | --minor | --patch | --fixed

Update `pkg` within the constraints of the indicated version
specifications. These specifications are of the form `@1`, `@1.2` or `@1.2.3`, allowing
any version with a prefix that matches, or ranges thereof, such as `@1.2-3.4.5`.
In `--project` mode, package specifications only match project packages, while
in `--manifest` mode they match any manifest package. Bound level options force
the following packages to be upgraded only within the current major, minor,
patch version; if the `--fixed` upgrade level is given, then the following
packages will not be upgraded at all.

After any package updates the project will be precompiled. For more information see `pkg> ?precompile`.
""",
],
PSA[:name => "generate",
    :api => API.generate,
    :arg_count => 1 => 1,
    :arg_parser => ((x,y) -> map(expanduser, unwrap(x))),
    :description => "generate files for a new project",
    :help => md"""
    generate pkgname

Create a minimal project called `pkgname` in the current folder. For more featureful package creation, please see `PkgTemplates.jl`.
""",
],
PSA[:name => "precompile",
    :api => API.precompile,
    :arg_count => 0 => Inf,
    :completions => complete_installed_packages,
    :description => "precompile all the project dependencies",
    :help => md"""
    precompile
    precompile pkgs...

Precompile all or specified dependencies of the project in parallel.
The `startup.jl` file is disabled during precompilation unless julia is started with `--startup-file=yes`.

Errors will only throw when precompiling the top-level dependencies, given that
not all manifest dependencies may be loaded by the top-level dependencies on the given system.

This method is called automatically after any Pkg action that changes the manifest.
Any packages that have previously errored during precompilation won't be retried in auto mode
until they have changed. To disable automatic precompilation set the environment variable `JULIA_PKG_PRECOMPILE_AUTO=0`.
To manually control the number of tasks used set the environment variable `JULIA_NUM_PRECOMPILE_TASKS`.
""",
],
PSA[:name => "status",
    :short_name => "st",
    :api => API.status,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => [
        PSA[:name => "project",  :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        PSA[:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
        PSA[:name => "diff", :short_name => "d", :api => :diff => true],
        PSA[:name => "outdated", :short_name => "o", :api => :outdated => true],
        PSA[:name => "compat", :short_name => "c", :api => :compat => true],
    ],
    :completions => complete_installed_packages,
    :description => "summarize contents of and changes to environment",
    :help => md"""
    [st|status] [-d|--diff] [-o|--outdated] [pkgs...]
    [st|status] [-d|--diff] [-o|--outdated] [-p|--project] [pkgs...]
    [st|status] [-d|--diff] [-o|--outdated] [-m|--manifest] [pkgs...]
    [st|status] [-c|--compat] [pkgs...]

Show the status of the current environment.
Packages marked with `⌃` have new versions that can be installed, e.g. via `pkg> up`.
Those marked with `⌅` have new versions available, but that cannot be installed. To see why
use `pkg> status --outdated` which shows any packages that are not at their latest version
and if any packages are holding them back.

In `--project` mode (default), the status of the project file is summarized. In `--manifest`
mode the output also includes the recursive dependencies of added packages given in the manifest.
If there are any packages listed as arguments the output will be limited to those packages.
The `--diff` option will, if the environment is in a git repository, limit
the output to the difference as compared to the last git commit.
The `--compat` option alone shows project compat entries.

!!! compat "Julia 1.1"
    `pkg> status` with package arguments requires at least Julia 1.1.

!!! compat "Julia 1.3"
    The `--diff` option requires at least Julia 1.3. In earlier versions `--diff`
    is the default for environments in git repositories.

!!! compat "Julia 1.8"
    The `⌃` and `⌅` indicators were added in Julia 1.8
    The `--outdated` and `--compat` options require at least Julia 1.8.
""",
],
PSA[:name => "compat",
    :api => API.compat,
    :arg_count => 0 => 2,
    :completions => complete_installed_packages_and_compat,
    :description => "edit compat entries in the current Project and re-resolve",
    :help => md"""
    compat [pkg] [compat_string]

Edit project [compat] entries directly, or via an interactive menu by not specifying any arguments.
When directly editing use tab to complete the package name and any existing compat entry.
Specifying a package with a blank compat entry will remove the entry.
After changing compat entries a `resolve` will be attempted to check whether the current
environment is compliant with the new compat rules.
""",
],
PSA[:name => "gc",
    :api => API.gc,
    :option_spec => [
        PSA[:name => "all", :api => :collect_delay => Hour(0)],
        PSA[:name => "verbose", :short_name => "v", :api => :verbose => true],
    ],
    :description => "garbage collect packages not used for a significant time",
    :help => md"""
    gc [-v|--verbose] [--all]

Free disk space by garbage collecting packages not used for a significant time.
The `--all` option will garbage collect all packages which can not be immediately
reached from any existing project.
Use verbose mode for detailed output.
""",
],
PSA[:name => "undo",
    :api => API.undo,
    :description => "undo the latest change to the active project",
    :help => md"""
    undo

Undoes the latest change to the active project.
""",
],
PSA[:name => "redo",
    :api => API.redo,
    :description => "redo the latest change to the active project",
    :help => md"""
    redo

Redoes the changes from the latest [`undo`](@ref).
""",
],
], #package
"registry" => CommandDeclaration[
PSA[:name => "add",
    :api => Registry.add,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => ((x,y) -> parse_registry(x,y; add = true)),
    :description => "add package registries",
    :help => md"""
    registry add reg...

Add package registries `reg...` to the user depot. Without arguments
it adds known registries, i.e. the General registry and registries
served by the configured package server.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

!!! compat "Julia 1.5"
    `registry add` without arguments requires at least Julia 1.5.

**Examples**
```
pkg> registry add General
pkg> registry add https://www.my-custom-registry.com
pkg> registry add
```
""",
],
PSA[:name => "remove",
    :short_name => "rm",
    :api => Registry.rm,
    :should_splat => false,
    :arg_count => 1 => Inf,
    :arg_parser => parse_registry,
    :description => "remove package registries",
    :help => md"""
    registry [rm|remove] reg...

Remove package registries `reg...`.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

**Examples**
```
pkg> registry [rm|remove] General
```
""",
],
PSA[:name => "update",
    :short_name => "up",
    :api => Registry.update,
    :should_splat => false,
    :arg_count => 0 => Inf,
    :arg_parser => parse_registry,
    :description => "update package registries",
    :help => md"""
    registry [up|update]
    registry [up|update] reg...

Update package registries `reg...`. If no registries are specified
all registries will be updated.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

**Examples**
```
pkg> registry up
pkg> registry up General
```
""",
],
PSA[:name => "status",
    :short_name => "st",
    :api => Registry.status,
    :description => "information about installed registries",
    :help => md"""
    registry [st|status]

Display information about installed registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

**Examples**
```
pkg> registry status
```
""",
]
], #registry
] #command_declarations
