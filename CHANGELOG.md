Pkg v1.9 Release Notes
=======================

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
