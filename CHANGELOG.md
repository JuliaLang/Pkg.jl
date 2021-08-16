Pkg v1.8 Release Notes
======================

- New `outdated::Bool` kwarg to `Pkg.status` (`--outdated` or `-o` in the REPL mode) to show
  information about packages not at the latest version.
- Pkg now only tries to download pacakges from the package server in case the
  server tracks a registry that contains the package.

Pkg v1.7 Release Notes
======================

- The format of the `Manifest.toml` file have changed. New manifests will use
  the new format while old manifest will have their existing format in place.
  Julia 1.6.2 is compatible with the new format.
- Registries downloaded from the Pkg Server (not git) are no longer uncompressed into files but instead read directly from the compressed tarball into memory. This improves performance on
  filesystems which do not handle a large number of files well. To turn this feature off, set the environment variable `JULIA_PKG_UNPACK_REGISTRY=true`.
- It is now possible to use an external `git` executable instead of the default libgit2 library for 
  the downloads that happen via the Git protocol by setting the environment variable `JULIA_PKG_USE_CLI_GIT=true`.
- Registries downloaded from the Pkg Server (not git) is now assumed to be immutable. Manual changes to their files might not be picked up by a running Pkg session.
- The number of packags precompiled in parallel are now limited to 16 unless the
  environment variable `JULIA_NUM_PRECOMPILE_TASKS` is set.
- Adding packages by folder name in the REPL mode now requires a prepending a `./` to the folder name package folder is in the current folder, e.g. `add ./Package` is required instead of `add Pacakge`. This is to avoid confusion between the package name `Package` and the local directory `Package`.
- `rm`, `pin`, and `free` now support the `--all` option, and the api variants gain the `all_pkgs::Bool` kwarg, to perform the operation on all packages within the project or manifest, depending on the mode of the operation.
- The `mode` keyword for `PackageSpec` has been removed.
