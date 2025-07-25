Pkg v1.13 Release Notes
=======================

- Project.toml environments now support a `readonly` field to mark environments as read-only, preventing modifications.
  ([#4284])
- `Pkg.build` now supports an `allow_reresolve` keyword argument to control whether the build process can re-resolve
  package versions, similar to the existing option for `Pkg.test`. ([#3329])
- Packages are now automatically added to `[sources]` when they are added by url or devved. ([#4225])
- `update` now shows a helpful tip when trying to upgrade a specific package that can be upgraded but is held back
  because it's part of a less optimal resolver solution ([#4266])
- `Pkg.status` now displays yanked packages with a `[yanked]` indicator and shows a warning when yanked packages are
  present. `Pkg.resolve` errors also display warnings about yanked packages that are not resolvable. ([#4310])
- Added `pkg> compat --current` command to automatically populate missing compat entries with the currently resolved
  package versions. Use `pkg> compat --current` for all packages or `pkg> compat Foo --current` for specific packages.
  ([#3266])
- Added `Pkg.precompile() do` block syntax to delay autoprecompilation until after multiple operations complete,
  improving efficiency when performing several environment changes. ([#4262])
- Added `Pkg.autoprecompilation_enabled(state::Bool)` to globally enable or disable automatic precompilation for Pkg
  operations. ([#4262])
- Implemented atomic TOML writes to prevent data corruption when Pkg operations are interrupted or multiple processes
  write simultaneously. All TOML files are now written atomically using temporary files and atomic moves. ([#4293])
- Implemented lazy loading for RegistryInstance to significantly improve startup performance for operations that don't
  require full registry data. This reduces `Pkg.instantiate()` time by approximately 60% in many cases. ([#4304])
- Added support for directly adding git submodules via `Pkg.add(path="/path/to/git-submodule.jl")`. ([#3344])
- Enhanced REPL user experience by automatically detecting and stripping accidental leading `]` characters in commands.
  ([#3122])
- Improved tip messages to show REPL mode syntax when operating in REPL mode. ([#3854])
- Enhanced error handling with more descriptive error messages when operations fail on empty URLs during git repository
  installation or registry discovery. ([#4282])
- Improved error messages for invalid compat entries to provide better guidance for fixing them. ([#4302])
- Added warnings when attempting to add local paths that contain dirty git repositories. ([#4309])
- Enhanced package parsing to better handle complex URLs and paths with branch/tag/subdir specifiers. ([#4299])
- Improved artifact download behavior to only attempt downloads from the Pkg server when the package is registered on
  that server's registries. ([#4297])
- Added comprehensive documentation page about depots, including depot layouts and configuration. ([#2245])
- Enhanced error handling for packages missing from registries or manifests with more informative messages. ([#4303])
- Added more robust error handling when packages have revisions but no source information. ([#4311])
- Enhanced registry status reporting with more detailed information. ([#4300])
- Fixed various edge cases in package resolution and manifest handling. ([#4307], [#4308], [#4312])
- Improved handling of path separators across different operating systems. ([#4305])
- Added better error messages when accessing private PackageSpec.repo field. ([#4170])

Pkg v1.12 Release Notes
=======================

- Pkg now has support for "workspaces" which is a way to resolve multiple project files into a single manifest.
  The functions `Pkg.status`, `Pkg.why`, `Pkg.instantiate`, `Pkg.precompile` (and their REPL variants) have been
  updated to take a `workspace` option, with fixes for workspace path collection and package resolution in workspace
  environments. Read more about this feature in the manual about the TOML-files. ([#3841], [#4229])
- Pkg now supports "apps" which are Julia packages that can be run directly from the terminal after installation.
  Apps can be defined in a package's Project.toml and installed via Pkg. Apps now support multiple apps per package
  via submodules, allowing packages to define multiple command-line applications, with enhanced functionality including
  update capabilities and better handling of already installed apps. ([#3772], [#4277], [#4263])
- `status` now shows when different versions/sources of dependencies are loaded than that which is expected by the
  manifest ([#4109])
- When adding or developing a package that exists in the `[weakdeps]` section, it is now automatically removed from
  weak dependencies and added as a regular dependency. ([#3865])
- Enhanced fuzzy matching algorithm for package name suggestions with improved multi-factor scoring for better package
  name suggestions. ([#4287])
- The Pkg REPL now supports GitHub pull request URLs, allowing direct package installation from PRs via
  `pkg> add https://github.com/Org/Package.jl/pull/123` ([#4295])
- Improved git repository cloning performance by changing from `refs/*` to `refs/heads/*` to speed up operations on
  repositories with many branches. ([#2330])
- Improved REPL command parsing to handle leading whitespace with comma-separated packages. ([#4274])
- Improved error messages when providing incorrect package UUIDs. ([#4270])
- Added confirmation prompts before removing compat entries to prevent accidental deletions. ([#4254])

Pkg v1.11 Release Notes
=======================

- It is now possible to specify "sources" for packages in a `[sources]` section in Project.toml.
  This can be used to add non-registered normal or test dependencies. ([#3783])
- Pkg now obeys `[compat]` bounds for `julia` and raises an error if the version of the running Julia binary is incompatible with the bounds in `Project.toml`.
  Pkg has always obeyed this compat when working with Registry packages. This change affects mostly local packages. ([#3526])
- `pkg> add` and `Pkg.add` will now add compat entries for new direct dependencies if the active environment is a
  package (has a `name` and `uuid` entry) ([#3732])
- Dependencies can now be directly added as weak deps or extras via the `pkg> add --weak/extra Foo` or
  `Pkg.add("Foo", target=:weakdeps/:extras)` forms ([#3708])

Pkg v1.10 Release Notes
=======================

Pkg v1.9 Release Notes
======================

- New functionality: `Pkg.why` and `pkg> why` to show why a package is inside the environment (shows all "paths" to a package starting at the direct dependencies).
- When code coverage tracking is enabled for `Pkg.test` the new path-specific code-coverage option is used to limit coverage
  to the directory of the package being tested. Previously the `--code-coverage=user` option was used, which tracked files
  in all code outside of Core & Base, i.e. all stdlibs and all user packages, which often made running tests with
  code coverage a lot slower ([#3021]).
- Writes to `manifest_usage.toml` and Registry downloads/updates are now protected from process concurrency clashes via
  a pidfile lock ([#2793]).
- The Pkg REPL now understands Github URLs to branches and commits so you can e.g. do `pkg> add https://github.com/Org/Package.jl/tree/branch`
  or `pkg> add https://github.com/Org/Package.jl/commit/bb9eb77e6dc`.
- Timing of the precompilation of dependencies can now be reported via `Pkg.precompile(timing=true)` ([#3334])
- Bug fix on `pin/free --all` which now correctly applies to all dependencies, not just direct dependencies ([#3346]).
- To reduce the amount of time spent downloading and precompiling new package versions when working with multiple
  environments, a new preserve strategy `PRESERVE_ALL_INSTALLED` has been added which will preserve all existing
  dependencies and only add versions of the new packages that are already installed. i.e. `pkg> add --preserve=installed Foo`.
  Also a new tiered resolve strategy `PRESERVE_TIERED_INSTALLED` that tries this first, which can be set to the default
  strategy by setting the env var `JULIA_PKG_PRESERVE_TIERED_INSTALLED` to `true` ([#3378]).

Pkg v1.8 Release Notes
======================

- Pkg will now respect the version of packages put into the sysimage using e.g. PackageCompiler. For example,
  if version 1.3.2 of package A is in the sysimage, Pkg will always install that version when adding the package,
  or when the package is installed as a dependency to some other package. This can be disabled by calling
  `Pkg.respect_sysimage_versions(false)` ([#3002]).
- New `⌃` and `⌅` indicators beside packages in `pkg> status` that have new versions available.
  `⌅` indicates when new versions cannot be installed ([#2906]).
- New `outdated::Bool` kwarg to `Pkg.status` (`--outdated` or `-o` in the REPL mode) to show
  information about packages not at the latest version ([#2284]).
- New `compat::Bool` kwarg to `Pkg.status` (`--compat` or `-c` in the REPL mode) to show any [compat]
  entries in the Project.toml ([#2702]).
- New `pkg> compat` (and `Pkg.compat`) mode for setting Project compat entries. Provides an interactive editor
  via `pkg> compat`, or direct entry manipulation via `pkg> Foo 0.4,0.5` which can load current entries via tab-completion.
  i.e. `pkg> compat Fo<TAB>` autocompletes to `pkg> Foo 0.4,0.5` so that the existing entry can be edited ([#2702]).
- Pkg now only tries to download packages from the package server in case the server tracks a registry that contains
  the package ([#2689]).
- `Pkg.instantiate` will now warn when a Project.toml is out of sync with a Manifest.toml. It does this by storing a hash
  of the project deps and compat entries (other fields are ignored) in the manifest when it is resolved, so that any change
  to the Project.toml deps or compat entries without a re-resolve can be detected ([#2815]).
- If `pkg> add` cannot find a package with the provided name it will now suggest similarly named packages that can be added ([#2985]).
- The julia version stored in the manifest no longer includes the build number i.e. master will now record as `1.9.0-DEV` ([#2995]).
- Interrupting a `pkg> test` will now be caught more reliably and exit back to the REPL gracefully ([#2933]).

Pkg v1.7 Release Notes
======================

- The format of the `Manifest.toml` file have changed. New manifests will use
  the new format while old manifest will have their existing format in place ([#2580]).
  Julia 1.6.2 is compatible with the new format ([#2561]).
- Registries downloaded from the Pkg Server (not git) are no longer uncompressed into files but instead read directly from the compressed tarball into memory. This improves performance on
  filesystems which do not handle a large number of files well. To turn this feature off, set the environment variable `JULIA_PKG_UNPACK_REGISTRY=true` ([#2431]).
- It is now possible to use an external `git` executable instead of the default libgit2 library for
  the downloads that happen via the Git protocol by setting the environment variable `JULIA_PKG_USE_CLI_GIT=true` ([#2448]).
- Registries downloaded from the Pkg Server (not git) is now assumed to be immutable. Manual changes to their files might not be picked up by a running Pkg session.
- The number of packages precompiled in parallel are now limited to 16 unless the
  environment variable `JULIA_NUM_PRECOMPILE_TASKS` is set ([#2552]).
- Adding packages by folder name in the REPL mode now requires a prepending a `./` to the folder name package folder is in the current folder, e.g. `add ./Package` is required instead of `add Package`. This is to avoid confusion between the package name `Package` and the local directory `Package`.
- `rm`, `pin`, and `free` now support the `--all` option, and the api variants gain the `all_pkgs::Bool` kwarg, to perform the operation on all packages within the project or manifest, depending on the mode of the operation ([#2432]).
- The `mode` keyword for `PackageSpec` has been removed ([#2454]).

<!--- Generated by NEWS-update.jl --->
[#4225]: https://github.com/JuliaLang/Pkg.jl/issues/4225
[#4284]: https://github.com/JuliaLang/Pkg.jl/issues/4284
[#3526]: https://github.com/JuliaLang/Pkg.jl/issues/3526
[#3708]: https://github.com/JuliaLang/Pkg.jl/issues/3708
[#3732]: https://github.com/JuliaLang/Pkg.jl/issues/3732
[#3772]: https://github.com/JuliaLang/Pkg.jl/issues/3772
[#3783]: https://github.com/JuliaLang/Pkg.jl/issues/3783
[#3841]: https://github.com/JuliaLang/Pkg.jl/issues/3841
[#3865]: https://github.com/JuliaLang/Pkg.jl/issues/3865
[#4109]: https://github.com/JuliaLang/Pkg.jl/issues/4109
[#2284]: https://github.com/JuliaLang/Pkg.jl/issues/2284
[#2431]: https://github.com/JuliaLang/Pkg.jl/issues/2431
[#2432]: https://github.com/JuliaLang/Pkg.jl/issues/2432
[#2448]: https://github.com/JuliaLang/Pkg.jl/issues/2448
[#2454]: https://github.com/JuliaLang/Pkg.jl/issues/2454
[#2552]: https://github.com/JuliaLang/Pkg.jl/issues/2552
[#2561]: https://github.com/JuliaLang/Pkg.jl/issues/2561
[#2580]: https://github.com/JuliaLang/Pkg.jl/issues/2580
[#2689]: https://github.com/JuliaLang/Pkg.jl/issues/2689
[#2702]: https://github.com/JuliaLang/Pkg.jl/issues/2702
[#2793]: https://github.com/JuliaLang/Pkg.jl/issues/2793
[#2815]: https://github.com/JuliaLang/Pkg.jl/issues/2815
[#2906]: https://github.com/JuliaLang/Pkg.jl/issues/2906
[#2933]: https://github.com/JuliaLang/Pkg.jl/issues/2933
[#2985]: https://github.com/JuliaLang/Pkg.jl/issues/2985
[#2995]: https://github.com/JuliaLang/Pkg.jl/issues/2995
[#3002]: https://github.com/JuliaLang/Pkg.jl/issues/3002
[#3021]: https://github.com/JuliaLang/Pkg.jl/issues/3021
[#3266]: https://github.com/JuliaLang/Pkg.jl/pull/3266
[#4266]: https://github.com/JuliaLang/Pkg.jl/pull/4266
[#4310]: https://github.com/JuliaLang/Pkg.jl/pull/4310
[#3329]: https://github.com/JuliaLang/Pkg.jl/pull/3329
[#4262]: https://github.com/JuliaLang/Pkg.jl/pull/4262
[#4293]: https://github.com/JuliaLang/Pkg.jl/pull/4293
[#4304]: https://github.com/JuliaLang/Pkg.jl/pull/4304
[#3344]: https://github.com/JuliaLang/Pkg.jl/pull/3344
[#2330]: https://github.com/JuliaLang/Pkg.jl/pull/2330
[#3122]: https://github.com/JuliaLang/Pkg.jl/pull/3122
[#3854]: https://github.com/JuliaLang/Pkg.jl/pull/3854
[#4282]: https://github.com/JuliaLang/Pkg.jl/pull/4282
[#4302]: https://github.com/JuliaLang/Pkg.jl/pull/4302
[#4309]: https://github.com/JuliaLang/Pkg.jl/pull/4309
[#4299]: https://github.com/JuliaLang/Pkg.jl/pull/4299
[#4295]: https://github.com/JuliaLang/Pkg.jl/pull/4295
[#4277]: https://github.com/JuliaLang/Pkg.jl/pull/4277
[#4297]: https://github.com/JuliaLang/Pkg.jl/pull/4297
[#2245]: https://github.com/JuliaLang/Pkg.jl/pull/2245
[#4303]: https://github.com/JuliaLang/Pkg.jl/pull/4303
[#4254]: https://github.com/JuliaLang/Pkg.jl/pull/4254
[#4270]: https://github.com/JuliaLang/Pkg.jl/pull/4270
[#4263]: https://github.com/JuliaLang/Pkg.jl/pull/4263
[#4229]: https://github.com/JuliaLang/Pkg.jl/pull/4229
[#4274]: https://github.com/JuliaLang/Pkg.jl/pull/4274
[#4311]: https://github.com/JuliaLang/Pkg.jl/pull/4311
[#4300]: https://github.com/JuliaLang/Pkg.jl/pull/4300
[#4307]: https://github.com/JuliaLang/Pkg.jl/pull/4307
[#4308]: https://github.com/JuliaLang/Pkg.jl/pull/4308
[#4312]: https://github.com/JuliaLang/Pkg.jl/pull/4312
[#4305]: https://github.com/JuliaLang/Pkg.jl/pull/4305
[#4170]: https://github.com/JuliaLang/Pkg.jl/pull/4170
[#4287]: https://github.com/JuliaLang/Pkg.jl/pull/4287
