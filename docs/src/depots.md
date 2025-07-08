# **15.** Depots

The packages installed for a particular environment, defined in the
files `Project.toml` and `Manifest.toml` within the directory
structure, are not actually installed within that directory but into a
"depot". The location of the depots are set by the variable
[`DEPOT_PATH`](https://docs.julialang.org/en/v1/base/constants/#Base.DEPOT_PATH).

For details on the default depot locations and how they vary by installation method,
see the [`DEPOT_PATH`](https://docs.julialang.org/en/v1/base/constants/#Base.DEPOT_PATH) documentation.

Packages which are installed by a user go into the first depot and the Julia
standard library is in the last depot.

You should not need to manage the user depot directly. Pkg will automatically clean up
the depots when packages are removed after a delay. However you may want to manually
remove old `.julia/compiled/` subdirectories if you have any that reside for older Julia
versions that you no longer use (hence have not been run to tidy themselves up).

## Configuring the depot path with `JULIA_DEPOT_PATH`

The depot path can be configured using the `JULIA_DEPOT_PATH` environment variable,
which is used to populate the global Julia [`DEPOT_PATH`](https://docs.julialang.org/en/v1/base/constants/#Base.DEPOT_PATH) variable
at startup. For complete details on the behavior of this environment variable,
see the [environment variables documentation](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_DEPOT_PATH).

Unlike the shell `PATH` variable, empty entries in `JULIA_DEPOT_PATH`
have special behavior for easy overriding of the user depot while retaining access to system resources.
For example, to switch the user depot to `/custom/depot` while still accessing bundled
resources, use a trailing path separator:

```bash
export JULIA_DEPOT_PATH="/custom/depot:"
```

!!! note
    The trailing path separator (`:` on Unix, `;` on Windows) is crucial for including
    the default system depots, which contain the standard library and other bundled
    resources. Without it, Julia will only use the specified depot and will have to precompile
    standard library packages, which can be time-consuming and inefficient.

## Shared depots for distributed computing

When using Julia in distributed computing environments, such as high-performance computing
(HPC) clusters, it's recommended to use a shared depot via `JULIA_DEPOT_PATH`. This allows
multiple Julia processes to share precompiled packages and reduces redundant compilation.

Since Julia v1.10, multiple processes using the same depot coordinate via pidfile locks
to ensure only one process precompiles a package while others wait. However, due to
the caching of native code in pkgimages since v1.9, you may need to set the `JULIA_CPU_TARGET`
environment variable appropriately to ensure cache compatibility across different
worker nodes with varying CPU capabilities.

For more details, see the [FAQ section on distributed computing](https://docs.julialang.org/en/v1/manual/faq/#Computing-cluster)
and the [environment variables documentation](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_CPU_TARGET).
