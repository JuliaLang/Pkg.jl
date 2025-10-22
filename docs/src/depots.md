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

### When to customize the depot path

You may want to change your depot location in several scenarios:

- **Corporate environments**: When your user folder synchronizes with a server (such as with
  Active Directory roaming profiles), storing thousands of package files in the default depot
  can cause significant slowdowns during login/logout.
- **Storage constraints**: When your user directory has limited quota or is on a slow network drive.
- **Shared computing**: When multiple users need access to the same packages on a shared system.
- **Custom organization**: When you prefer to organize Julia packages separately from your user directory.

### Platform-specific configuration

`JULIA_DEPOT_PATH` is an **operating system environment variable**, not a Julia REPL command.
The method for setting it varies by platform:

#### Unix/Linux/macOS

For temporary configuration (current shell session only):

```bash
export JULIA_DEPOT_PATH="/custom/depot:"
```

For permanent configuration, add the export command to your shell configuration file
(e.g., `~/.bashrc`, `~/.zshrc`, or `~/.profile`).

#### Windows

For temporary configuration in **PowerShell** (current session only):

```powershell
$env:JULIA_DEPOT_PATH = "C:\custom\depot;"
```

For temporary configuration in **Command Prompt** (current session only):

```cmd
set JULIA_DEPOT_PATH=C:\custom\depot;
```

For permanent system-wide or user-level configuration:

1. Press `Win+R` to open the Run dialog
2. Type `sysdm.cpl` and press Enter
3. Go to the "Advanced" tab
4. Click "Environment Variables"
5. Add a new user or system variable named `JULIA_DEPOT_PATH` with your desired path
   (e.g., `C:\custom\depot;`)

!!! note
    The trailing path separator (`:` on Unix, `;` on Windows) is crucial for including
    the default system depots, which contain the standard library and other bundled
    resources. Without it, Julia will only use the specified depot and will have to precompile
    standard library packages, which can be time-consuming and inefficient.

### Alternative configuration methods

Instead of setting an operating system environment variable, you can configure the depot
path using Julia's `startup.jl` file, which runs automatically when Julia starts:

```julia
# In ~/.julia/config/startup.jl (Unix) or C:\Users\USERNAME\.julia\config\startup.jl (Windows)
empty!(DEPOT_PATH)
push!(DEPOT_PATH, "/custom/depot")
push!(DEPOT_PATH, joinpath(homedir(), ".julia"))  # Include default depot as fallback
```

This approach provides per-user permanent configuration without requiring operating system
environment variable changes. However, setting `JULIA_DEPOT_PATH` is generally preferred
as it takes effect before Julia loads any code.

!!! warning
    Modifying `DEPOT_PATH` at runtime (in the REPL or in scripts) after Julia has started
    is generally not recommended, as Julia may have already loaded packages from the
    original depot locations.

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
