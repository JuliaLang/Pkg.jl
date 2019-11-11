# [**12.** API Reference](@id API-Reference)

This section describes the function interface, or "API mode",
for interacting with Pkg.jl. The function API is recommended
for non-interactive usage, for example in scripts.

## General API Reference

Certain options are generally useful and can be specified in any API call.
You can specify these options by setting keyword arguments.

### Redirecting output

Use the `io::IOBuffer` keyword argument to redirect Pkg output.
For example, `Pkg.add("Example"; io=devnull)` will discard any output produced by the `add` call.

## Package API Reference

In the REPL mode, packages (with associated version, UUID, URL etc) are parsed from strings,
for example `"Package#master"`,`"Package@v0.1"`, `"www.mypkg.com/MyPkg#my/feature"`.

In the API mode, it is possible to use strings as arguments for simple commands (like `Pkg.add(["PackageA", "PackageB"])`,
but more complicated commands, which e.g. specify URLs or version range, require the use of a more structured format over strings.
This is done by creating an instance of [`PackageSpec`](@ref) which is passed in to functions.

```@docs
PackageSpec
PackageMode
UpgradeLevel
Pkg.add
Pkg.develop
Pkg.activate
Pkg.rm
Pkg.update
Pkg.test
Pkg.build
Pkg.pin
Pkg.free
Pkg.instantiate
Pkg.resolve
Pkg.gc
Pkg.status
Pkg.precompile
Pkg.setprotocol!
Pkg.dependencies
Pkg.project
Pkg.undo
Pkg.redo
```


## Registry API Reference

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

The function API for registries uses [`RegistrySpec`](@ref)s, similar to
[`PackageSpec`](@ref).

```@docs
RegistrySpec
Pkg.Registry.add
Pkg.Registry.rm
Pkg.Registry.update
Pkg.Registry.status
```

## [Artifacts API Reference](@id Artifacts-Reference)

!!! compat "Julia 1.3"
    Pkg's artifacts API requires at least Julia 1.3.

```@docs
Pkg.Artifacts.create_artifact
Pkg.Artifacts.artifact_exists
Pkg.Artifacts.artifact_path
Pkg.Artifacts.remove_artifact
Pkg.Artifacts.verify_artifact
Pkg.Artifacts.artifact_meta
Pkg.Artifacts.artifact_hash
Pkg.Artifacts.bind_artifact!
Pkg.Artifacts.unbind_artifact!
Pkg.Artifacts.download_artifact
Pkg.Artifacts.find_artifacts_toml
Pkg.Artifacts.ensure_artifact_installed
Pkg.Artifacts.ensure_all_artifacts_installed
Pkg.Artifacts.@artifact_str
Pkg.Artifacts.archive_artifact
```
