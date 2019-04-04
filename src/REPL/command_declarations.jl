command_declarations = [
"package" => CommandDeclaration[
[   :kind => CMD_TEST,
    :name => "test",
    :handler => do_test!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => OptionDeclaration[
        [:name => "coverage", :api => :coverage => true],
    ],
    :completions => complete_installed_packages,
    :description => "run tests for packages",
    :help => md"""

    test [opts] pkg[=uuid] ...

    opts: --coverage

Run the tests for package `pkg`. This is done by running the file `test/runtests.jl`
in the package directory. The option `--coverage` can be used to run the tests with
coverage enabled. The `startup.jl` file is disabled during testing unless
julia is started with `--startup-file=yes`.
    """,
],[ :kind => CMD_HELP,
    :name => "help",
    :short_name => "?",
    :arg_count => 0 => Inf,
    :arg_parser => identity,
    :completions => complete_help,
    :description => "show this message",
    :help => md"""

    help

List available commands along with short descriptions.

    help cmd

If `cmd` is a partial command, display help for all subcommands.
If `cmd` is a full command, display help for `cmd`.
    """,
],[ :kind => CMD_INSTANTIATE,
    :name => "instantiate",
    :handler => do_instantiate!,
    :option_spec => OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :manifest => false],
        [:name => "manifest", :short_name => "m", :api => :manifest => true],
    ],
    :description => "downloads all the dependencies for the project",
    :help => md"""
    instantiate
    instantiate [-m|--manifest]
    instantiate [-p|--project]

Download all the dependencies for the current project at the version given by the project's manifest.
If no manifest exists or the `--project` option is given, resolve and download the dependencies compatible with the project.
    """,
],[ :kind => CMD_RM,
    :name => "remove",
    :short_name => "rm",
    :handler => do_rm!,
    :arg_count => 1 => Inf,
    :arg_parser => parse_package,
    :option_spec => OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
    ],
    :completions => complete_installed_packages,
    :description => "remove packages from project or manifest",
    :help => md"""

    rm [-p|--project] pkg[=uuid] ...

Remove package `pkg` from the project file. Since the name `pkg` can only
refer to one package in a project this is unambiguous, but you can specify
a `uuid` anyway, and the command is ignored, with a warning if package name
and UUID do not mactch. When a package is removed from the project file, it
may still remain in the manifest if it is required by some other package in
the project. Project mode operation is the default, so passing `-p` or
`--project` is optional unless it is preceded by the `-m` or `--manifest`
options at some earlier point.

    rm [-m|--manifest] pkg[=uuid] ...

Remove package `pkg` from the manifest file. If the name `pkg` refers to
multiple packages in the manifest, `uuid` disambiguates it. Removing a package
from the manifest forces the removal of all packages that depend on it, as well
as any no-longer-necessary manifest packages due to project package removals.
    """,
],[ :kind => CMD_ADD,
    :name => "add",
    :handler => do_add!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_package(x; add_or_dev=true, valid=[VersionRange, Rev])),
    :option_spec => OptionDeclaration[
        [:name => "strict", :api => :strict => true],
    ],
    :completions => complete_add_dev,
    :description => "add packages to project",
    :help => md"""

    add pkg[=uuid] [@version] [#rev] ...

Add package `pkg` to the current project file. If `pkg` could refer to
multiple different packages, specifying `uuid` allows you to disambiguate.
`@version` optionally allows specifying which versions of packages. Versions
may be specified by `@1`, `@1.2`, `@1.2.3`, allowing any version with a prefix
that matches, or ranges thereof, such as `@1.2-3.4.5`. A git-revision can be
specified by `#branch` or `#commit`.

If a local path is used as an argument to `add`, the path needs to be a git repository.
The project will then track that git repository just like if it is was tracking a remote repository online.

**Examples**
```
pkg> add Example
pkg> add Example@0.5
pkg> add Example#master
pkg> add Example#c37b675
pkg> add https://github.com/JuliaLang/Example.jl#master
pkg> add git@github.com:JuliaLang/Example.jl.git
pkg> add Example=7876af07-990d-54b4-ab0e-23690620f79a
```
    """,
],[ :kind => CMD_DEVELOP,
    :name => "develop",
    :short_name => "dev",
    :handler => do_develop!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_package(x; add_or_dev=true, valid=[VersionRange])),
    :option_spec => OptionDeclaration[
        [:name => "strict", :api => :strict => true],
        [:name => "local", :api => :shared => false],
        [:name => "shared", :api => :shared => true],
    ],
    :completions => complete_add_dev,
    :description => "clone the full package repo locally for development",
    :help => md"""
    develop [--shared|--local] pkg[=uuid] ...

Make a package available for development. If `pkg` is an existing local path that path will be recorded in
the manifest and used. Otherwise, a full git clone of `pkg` at rev `rev` is made. The location of the clone is
controlled by the `--shared` (default) and `--local` arguments. The `--shared` location defaults to
`~/.julia/dev`, but can be controlled with the `JULIA_PKG_DEVDIR` environment variable. When `--local` is given,
the clone is placed in a `dev` folder in the current project.
This operation is undone by `free`.

*Example*
```jl
pkg> develop Example
pkg> develop https://github.com/JuliaLang/Example.jl
pkg> develop ~/mypackages/Example
pkg> develop --local Example
```
    """,
],[ :kind => CMD_FREE,
    :name => "free",
    :handler => do_free!,
    :arg_count => 1 => Inf,
    :arg_parser => parse_package,
    :completions => complete_installed_packages,
    :description => "undoes a `pin`, `develop`, or stops tracking a repo",
    :help => md"""
    free pkg[=uuid] ...

Free a pinned package `pkg`, which allows it to be upgraded or downgraded again. If the package is checked out (see `help develop`) then this command
makes the package no longer being checked out.
    """,
],[ :kind => CMD_PIN,
    :name => "pin",
    :handler => do_pin!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_package(x; valid=[VersionRange])),
    :completions => complete_installed_packages,
    :description => "pins the version of packages",
    :help => md"""

    pin pkg[=uuid] ...

Pin packages to given versions, or the current version if no version is specified. A pinned package has its version fixed and will not be upgraded or downgraded.
A pinned package has the symbol `⚲` next to its version in the status list.
    """,
],[ :kind => CMD_BUILD,
    :name => "build",
    :handler => do_build!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => OptionDeclaration[
        [:name => "verbose", :short_name => "v", :api => :verbose => true],
    ],
    :completions => complete_installed_packages,
    :description => "run the build script for packages",
    :help => md"""
    build [-v|verbose] pkg[=uuid] ...

Run the build script in `deps/build.jl` for each package in `pkg` and all of their dependencies in depth-first recursive order.
If no packages are given, runs the build scripts for all packages in the manifest.
The `-v`/`--verbose` option redirects build output to `stdout`/`stderr` instead of the `build.log` file.
The `startup.jl` file is disabled during building unless julia is started with `--startup-file=yes`.
    """,
],[ :kind => CMD_RESOLVE,
    :name => "resolve",
    :handler => do_resolve!,
    :description => "resolves to update the manifest from changes in dependencies of developed packages",
    :help => md"""
    resolve

Resolve the project i.e. run package resolution and update the Manifest. This is useful in case the dependencies of developed
packages have changed causing the current Manifest to be out of sync.
    """,
],[ :kind => CMD_ACTIVATE,
    :name => "activate",
    :handler => do_activate!,
    :arg_count => 0 => 1,
    :option_spec => OptionDeclaration[
        [:name => "shared", :api => :shared => true],
    ],
    :completions => complete_activate,
    :description => "set the primary environment the package manager manipulates",
    :help => md"""
    activate
    activate [--shared] path

Activate the environment at the given `path`, or the home project environment if no `path` is specified.
The active environment is the environment that is modified by executing package commands.
When the option `--shared` is given, `path` will be assumed to be a directory name and searched for in the
`environments` folders of the depots in the depot stack. In case no such environment exists in any of the depots,
it will be placed in the first depot of the stack.
    """ ,
],[ :kind => CMD_UP,
    :name => "update",
    :short_name => "up",
    :handler => do_up!,
    :arg_count => 0 => Inf,
    :arg_parser => (x -> parse_package(x; valid=[VersionRange])),
    :option_spec => OptionDeclaration[
        [:name => "project",  :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
        [:name => "major", :api => :level => UPLEVEL_MAJOR],
        [:name => "minor", :api => :level => UPLEVEL_MINOR],
        [:name => "patch", :api => :level => UPLEVEL_PATCH],
        [:name => "fixed", :api => :level => UPLEVEL_FIXED],
    ],
    :completions => complete_installed_packages,
    :description => "update packages in manifest",
    :help => md"""

    up [-p|project]  [opts] pkg[=uuid] [@version] ...
    up [-m|manifest] [opts] pkg[=uuid] [@version] ...

    opts: --major | --minor | --patch | --fixed

Update the indicated package within the constraints of the indicated version
specifications. Versions may be specified by `@1`, `@1.2`, `@1.2.3`, allowing
any version with a prefix that matches, or ranges thereof, such as `@1.2-3.4.5`.
In `--project` mode, package specifications only match project packages, while
in `manifest` mode they match any manifest package. Bound level options force
the following packages to be upgraded only within the current major, minor,
patch version; if the `--fixed` upgrade level is given, then the following
packages will not be upgraded at all.
    """,
],[ :kind => CMD_GENERATE,
    :name => "generate",
    :handler => do_generate!,
    :arg_count => 1 => 1,
    :description => "generate files for a new project",
    :help => md"""

    generate pkgname

Create a project called `pkgname` in the current folder.
    """,
],[ :kind => CMD_PRECOMPILE,
    :name => "precompile",
    :handler => do_precompile!,
    :description => "precompile all the project dependencies",
    :help => md"""
    precompile

Precompile all the dependencies of the project by running `import` on all of them in a new process.
The `startup.jl` file is disabled during precompilation unless julia is started with `--startup-file=yes`.
    """,
],[ :kind => CMD_STATUS,
    :name => "status",
    :short_name => "st",
    :handler => do_status!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_package,
    :option_spec => OptionDeclaration[
        [:name => "project",  :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
    ],
    :completions => complete_installed_packages,
    :description => "summarize contents of and changes to environment",
    :help => md"""

    status [pkgs...]
    status [-p|--project] [pkgs...]
    status [-m|--manifest] [pkgs...]

Show the status of the current environment. By default, the full contents of
the project file is summarized, showing what version each package is on and
how it has changed since the last git commit (if in a git repo), as well as
any changes to manifest packages not already listed. In `--project` mode, the
status of the project file is summarized. In `--manifest` mode the output also
includes the dependencies of explicitly added packages. If there are any
packages listed as arguments the output will be limited to those packages.

!!! compat "Julia 1.1"
    `pkg> status` with package arguments requires at least Julia 1.1.
    """,
],[ :kind => CMD_GC,
    :name => "gc",
    :handler => do_gc!,
    :description => "garbage collect packages not used for a significant time",
    :help => md"""

Deletes packages that cannot be reached from any existing environment.
    """,
],[ # preview is not a regular command.
    # this is here so that preview appears as a registered command to users
    :kind => CMD_PREVIEW,
    :name => "preview",
    :description => "previews a subsequent command without affecting the current state",
    :help => md"""

    preview cmd

Runs the command `cmd` in preview mode. This is defined such that no side effects
will take place i.e. no packages are downloaded and neither the project nor manifest
is modified.
    """,
],
], #package
"registry" => CommandDeclaration[
[   :kind => CMD_REGISTRY_ADD,
    :name => "add",
    :handler => do_registry_add!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_registry(x; add = true)),
    :description => "add package registries",
    :help => md"""

    registry add reg...

Adds package registries `reg...` to the user depot.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

**Examples**
```
pkg> registry add General
pkg> registry add https://www.my-custom-registry.com
```
    """,
],[ :kind => CMD_REGISTRY_RM,
    :name => "remove",
    :short_name => "rm",
    :handler => do_registry_rm!,
    :arg_count => 1 => Inf,
    :arg_parser => parse_registry,
    :description => "remove package registries",
    :help => md"""

    registry rm reg...

Remove package registres `reg...`.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

**Examples**
```
pkg> registry rm General
```
    """,
],[
    :kind => CMD_REGISTRY_UP,
    :name => "update",
    :short_name => "up",
    :handler => do_registry_up!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_registry,
    :description => "update package registries",
    :help => md"""

    registry up
    registry up reg...

Update package registries `reg...`. If no registries are specified
all user registries will be updated.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

**Examples**
```
pkg> registry up
pkg> registry up General
```
    """,
],[
    :kind => CMD_REGISTRY_STATUS,
    :name => "status",
    :short_name => "st",
    :handler => do_registry_status!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_registry,
    :description => "information about installed registries",
    :help => md"""

    registry status

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
