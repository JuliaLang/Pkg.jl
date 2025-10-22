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

## Setting up shared depots for multi-user systems

In multi-user environments such as JupyterHub deployments, university computing labs, or shared servers,
system administrators often want to provide a set of commonly-used packages that are available to all
users while still allowing individual users to install their own packages. This can be achieved by
setting up a layered depot structure with a read-only shared depot and user-specific writable depots.

### Overview of the approach

The key concept is to use `JULIA_DEPOT_PATH` to create a layered depot structure where:

1. **User depot** (first in path): User-specific packages and modifications
2. **Shared depot** (middle in path): Common packages installed by administrators
3. **System depot** (last in path): Julia standard library and bundled resources

When Julia searches for packages, it looks through depots in order. This allows users to:
- Access pre-installed packages from the shared depot
- Install additional packages into their own depot
- Override shared packages if needed by installing different versions in their user depot

### Administrator setup

#### Step 1: Create the shared depot

As a system administrator, create a shared depot location accessible to all users:

```bash
# Create shared depot directory
sudo mkdir -p /opt/julia/shared_depot

# Create a shared user for managing the depot (optional but recommended)
sudo useradd -r -s /bin/bash -d /opt/julia/shared_depot julia-shared

# Set ownership
sudo chown -R julia-shared:julia-shared /opt/julia/shared_depot
```

#### Step 2: Install shared packages

Switch to the shared user account and configure Julia to use the shared depot:

```bash
sudo su - julia-shared
export JULIA_DEPOT_PATH="/opt/julia/shared_depot:"
```

Then install commonly-used packages. You can do this interactively or by instantiating from a Project.toml:

```bash
# Interactive installation
julia -e 'using Pkg; Pkg.add(["Plots", "DataFrames", "CSV", "LinearAlgebra"])'

# Or from a Project.toml file
cd /opt/julia/shared_depot
# Create or copy your Project.toml and Manifest.toml files here
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

!!! tip
    Using a `Project.toml` and `Manifest.toml` file to define the shared environment is
    recommended as it provides reproducibility and version control. You can maintain these
    files in a git repository for tracking changes.

#### Step 3: Clean the shared depot (optional)

To minimize the shared depot size, you can remove registries from the shared depot:

```bash
rm -rf /opt/julia/shared_depot/registries
```

Since Pkg only writes to the first depot in `JULIA_DEPOT_PATH`, users will maintain their own
registries in their user depots anyway. Removing registries from the shared depot simply avoids
storing duplicate registry data.

#### Step 4: Set appropriate permissions

Make the shared depot read-only for regular users:

```bash
# Make shared depot readable by all users
sudo chmod -R a+rX /opt/julia/shared_depot

# Ensure it's not writable by others
sudo chmod -R go-w /opt/julia/shared_depot
```

### User configuration

Each user should configure their `JULIA_DEPOT_PATH` to include both their personal depot and
the shared depot. The exact syntax depends on where you want the user depot:

#### Using default user depot location

To use the default `~/.julia` as the user depot with the shared depot as a fallback:

```bash
export JULIA_DEPOT_PATH="~/.julia:/opt/julia/shared_depot:"
```

The trailing `:` ensures the system depot (with standard library) is still included.

#### Using a custom user depot location

If you want users to have their depot in a different location (e.g., to avoid home directory quotas):

```bash
export JULIA_DEPOT_PATH="/scratch/$USER/julia_depot:/opt/julia/shared_depot:"
```

#### System-wide configuration

To configure this for all users automatically, add the export command to system-wide shell
configuration files:

**On Linux:**
```bash
# In /etc/profile.d/julia.sh
export JULIA_DEPOT_PATH="~/.julia:/opt/julia/shared_depot:"
```

**On macOS:**
```bash
# In /etc/zshrc or /etc/bashrc
export JULIA_DEPOT_PATH="~/.julia:/opt/julia/shared_depot:"
```

Users can then further customize their individual depot paths if needed.

### Pre-seeding user environments

In some scenarios (e.g., for student lab computers or container images), you may want to
pre-seed individual user environments. This can be done by:

1. Creating a template environment with a `Project.toml` and `Manifest.toml`
2. Copying these files to each user's Julia project directory
3. Having users (or a startup script) run `Pkg.instantiate()` on first use

Since packages in the shared depot will be found automatically, `instantiate()` will only
download packages that aren't already available in the shared depot.

```bash
# As administrator, create template
mkdir -p /opt/julia/template_project
# Create Project.toml with desired packages
julia --project=/opt/julia/template_project -e 'using Pkg; Pkg.add("Example"); Pkg.add("Plots")'

# Users copy the template and instantiate
cp -r /opt/julia/template_project ~/my_project
cd ~/my_project
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

### Updating shared packages

To update packages in the shared depot:

1. Switch to the shared user account
2. Set `JULIA_DEPOT_PATH` to point only to the shared depot
3. Update packages as needed
4. Optionally, clean up old package versions to save space

```bash
sudo su - julia-shared
export JULIA_DEPOT_PATH="/opt/julia/shared_depot:"
julia -e 'using Pkg; Pkg.update()'
```

!!! note
    Updating packages in the shared depot adds new versions alongside existing ones. Users with
    Manifest.toml files remain pinned to their specific versions and won't be affected. If you
    explicitly clean up old package versions to save disk space, users who need those versions
    can run `Pkg.instantiate()` to download them to their local depot.

### Troubleshooting

**Packages not found despite being in shared depot:**
Verify that `JULIA_DEPOT_PATH` is set correctly and includes the shared depot. Check that
the trailing separator is present to include system depots. Use `DEPOT_PATH` in the Julia
REPL to verify the depot search path.

```julia
julia> DEPOT_PATH
3-element Vector{String}:
 "/home/user/.julia"
 "/opt/julia/shared_depot"
 "/usr/local/share/julia"
```
