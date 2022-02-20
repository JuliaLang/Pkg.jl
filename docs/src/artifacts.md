# [**8.** Artifacts](@id Artifacts)

!!! compat "Julia 1.3"
    Pkg's artifacts functionality requires at least Julia 1.3.

`Pkg` can install and manage containers of data that are not Julia packages.  These containers can contain platform-specific binaries, datasets, text, or any other kind of data that would be convenient to place within an immutable, life-cycled datastore.
These containers, (called "Artifacts") can be created locally, hosted anywhere, and automatically downloaded and unpacked upon installation of your Julia package.
This mechanism is also used to provide the binary dependencies for packages built with [`BinaryBuilder.jl`](https://github.com/JuliaPackaging/BinaryBuilder.jl).

## Basic Usage

`Pkg` artifacts are declared in an `Artifacts.toml` file, which can be placed in your current directory or in the root of your package.
Currently, `Pkg` supports downloading of tarfiles (which can be compressed) from a URL.
Following is a minimal `Artifacts.toml` file which will permit the downloading of a `socrates.tar.gz` file from `github.com`.
In this example, a single artifact, given the name `socrates`, is defined.

```TOML
# a simple Artifacts.toml file
[socrates]
git-tree-sha1 = "43563e7631a7eafae1f9f8d9d332e3de44ad7239"

    [[socrates.download]]
    url = "https://github.com/staticfloat/small_bin/raw/master/socrates.tar.gz"
    sha256 = "e65d2f13f2085f2c279830e863292312a72930fee5ba3c792b14c33ce5c5cc58"
```

If this `Artifacts.toml` file is placed in your current directory, then `socrates.tar.gz` can be downloaded, unpacked and used with `artifact"socrates"`.
Since this tarball contains a folder `bin`, and a text file named `socrates` within that folder, we could access the content of that file as follows.

```julia
using Pkg.Artifacts

rootpath = artifact"socrates"
open(joinpath(rootpath, "bin", "socrates")) do file
    println(read(file, String))
end
```

If you have an existing tarball that is accessible via a `url`, it could also be be accessed in this manner.
To create the `Artifacts.toml` you must compute two hashes: the `sha256` hash of the download file, and the `git-tree-sha1` of the unpacked content.
These can be computed as follows.

```julia
using Tar, Inflate, SHA

filename = "socrates.tar.gz"
println("sha256: ", bytes2hex(open(sha256, filename)))
println("git-tree-sha1: ", Tar.tree_hash(IOBuffer(inflate_gzip(filename))))
```

To access this artifact from within a package you create, place the `Artifacts.toml` at the root of your package, adjacent to `Project.toml`. Then, make sure to add `Pkg` in your `deps` and set `julia = "1.3"` or higher in your `compat` section.

## `Artifacts.toml` files

`Pkg` provides an API for working with artifacts, as well as a TOML file format for recording artifact usage in your packages, and to automate downloading of artifacts at package install time.
Artifacts can always be referred to by content hash, but are typically accessed by a name that is bound to a content hash in an `Artifacts.toml` file that lives in a project's source tree.

!!! note
    It is possible to use the alternate name `JuliaArtifacts.toml`, similar
    to how it is possible to use `JuliaProject.toml` and `JuliaManifest.toml`
    instead of `Project.toml` and `Manifest.toml`, respectively.

An example `Artifacts.toml` file is shown here:

```TOML
# Example Artifacts.toml file
[socrates]
git-tree-sha1 = "43563e7631a7eafae1f9f8d9d332e3de44ad7239"
lazy = true

    [[socrates.download]]
    url = "https://github.com/staticfloat/small_bin/raw/master/socrates.tar.gz"
    sha256 = "e65d2f13f2085f2c279830e863292312a72930fee5ba3c792b14c33ce5c5cc58"

    [[socrates.download]]
    url = "https://github.com/staticfloat/small_bin/raw/master/socrates.tar.bz2"
    sha256 = "13fc17b97be41763b02cbb80e9d048302cec3bd3d446c2ed6e8210bddcd3ac76"

[[c_simple]]
arch = "x86_64"
git-tree-sha1 = "4bdf4556050cb55b67b211d4e78009aaec378cbc"
libc = "musl"
os = "linux"

    [[c_simple.download]]
    sha256 = "411d6befd49942826ea1e59041bddf7dbb72fb871bb03165bf4e164b13ab5130"
    url = "https://github.com/JuliaBinaryWrappers/c_simple_jll.jl/releases/download/c_simple+v1.2.3+0/c_simple.v1.2.3.x86_64-linux-musl.tar.gz"

[[c_simple]]
arch = "x86_64"
git-tree-sha1 = "51264dbc770cd38aeb15f93536c29dc38c727e4c"
os = "macos"

    [[c_simple.download]]
    sha256 = "6c17d9e1dc95ba86ec7462637824afe7a25b8509cc51453f0eb86eda03ed4dc3"
    url = "https://github.com/JuliaBinaryWrappers/c_simple_jll.jl/releases/download/c_simple+v1.2.3+0/c_simple.v1.2.3.x86_64-apple-darwin14.tar.gz"

[processed_output]
git-tree-sha1 = "1c223e66f1a8e0fae1f9fcb9d3f2e3ce48a82200"
```

This `Artifacts.toml` binds three artifacts; one named `socrates`, one named `c_simple` and one named `processed_output`.
The single required piece of information for an artifact is its `git-tree-sha1`.
Because artifacts are addressed only by their content hash, the purpose of an `Artifacts.toml` file is to provide metadata about these artifacts, such as binding a human-readable name to a content hash, providing information about where an artifact may be downloaded from, or even binding a single name to multiple hashes, keyed by platform-specific constraints such as operating system or libgfortran version.

## Artifact types and properties

In the above example, the `socrates` artifact showcases a platform-independent artifact with multiple download locations.
When downloading and installing the `socrates` artifact, URLs will be attempted in-order until one succeeds.
The `socrates` artifact is marked as `lazy`, which means that it will not be automatically downloaded when the containing package is installed, but rather will be downloaded on-demand when the package first attempts to use it.

The `c_simple` artifact showcases a platform-dependent artifact, where each entry in the `c_simple` array contains keys that help the calling package choose the appropriate download based on the particulars of the host machine.
Note that each artifact contains both a `git-tree-sha1` and a `sha256` for each download entry.  This is to ensure that the downloaded tarball is secure before attempting to unpack it, as well as enforcing that all tarballs must expand to the same overall tree hash.

The `processed_output` artifact contains no `download` stanza, and so cannot be installed.
An artifact such as this would be the result of code that was previously run, generating a new artifact and binding the resultant hash to a name within this project.

## Using Artifacts

Artifacts can be manipulated using convenient APIs exposed from the `Pkg.Artifacts` namespace.
As a motivating example, let us imagine that we are writing a package that needs to load the [Iris machine learning dataset](https://archive.ics.uci.edu/ml/datasets/iris).
While we could just download the dataset during a build step into the package directory, and many packages currently do precisely this, that has some significant drawbacks:

* First, it modifies the package directory, making package installation stateful, which we want to avoid.
  In the future, we would like to reach the point where packages can be installed completely read-only, instead of being able to modify themselves after installation.

* Second, the downloaded data is not shared across different versions of our package.
  If we have three different versions of the package installed for use by various projects, then we need three different copies of the data, even if it hasn't changed between those versions.
  Moreover, each time we upgrade or downgrade the package, unless we do something clever (and probably brittle), we have to download the data again.

With artifacts, we will instead check to see if our `iris` artifact already exists on-disk and only if it doesn't will we download and install it, after which we can bind the result into our `Artifacts.toml` file:

```julia
using Pkg.Artifacts

# This is the path to the Artifacts.toml we will manipulate
artifact_toml = joinpath(@__DIR__, "Artifacts.toml")

# Query the `Artifacts.toml` file for the hash bound to the name "iris"
# (returns `nothing` if no such binding exists)
iris_hash = artifact_hash("iris", artifact_toml)

# If the name was not bound, or the hash it was bound to does not exist, create it!
if iris_hash == nothing || !artifact_exists(iris_hash)
    # create_artifact() returns the content-hash of the artifact directory once we're finished creating it
    iris_hash = create_artifact() do artifact_dir
        # We create the artifact by simply downloading a few files into the new artifact directory
        iris_url_base = "https://archive.ics.uci.edu/ml/machine-learning-databases/iris"
        download("$(iris_url_base)/iris.data", joinpath(artifact_dir, "iris.csv"))
        download("$(iris_url_base)/bezdekIris.data", joinpath(artifact_dir, "bezdekIris.csv"))
        download("$(iris_url_base)/iris.names", joinpath(artifact_dir, "iris.names"))
    end

    # Now bind that hash within our `Artifacts.toml`.  `force = true` means that if it already exists,
    # just overwrite with the new content-hash.  Unless the source files change, we do not expect
    # the content hash to change, so this should not cause unnecessary version control churn.
    bind_artifact!(artifact_toml, "iris", iris_hash)
end

# Get the path of the iris dataset, either newly created or previously generated.
# this should be something like `~/.julia/artifacts/dbd04e28be047a54fbe9bf67e934be5b5e0d357a`
iris_dataset_path = artifact_path(iris_hash)
```

For the specific use case of using artifacts that were previously bound, we have the shorthand notation `artifact"name"` which will automatically search for the `Artifacts.toml` file contained within the current package, look up the given artifact by name, install it if it is not yet installed, then return the path to that given artifact.
An example of this shorthand notation is given below:

```julia
using Pkg.Artifacts

# For this to work, an `Artifacts.toml` file must be in the current working directory
# (or in the root of the current package) and must define a mapping for the "iris"
# artifact.  If it does not exist on-disk, it will be downloaded.
iris_dataset_path = artifact"iris"
```

## The `Pkg.Artifacts` API

The `Artifacts` API is broken up into three levels: hash-aware functions, name-aware functions and utility functions.

* **Hash-aware** functions deal with content-hashes and essentially nothing else. These methods allow you to query whether an artifact exists, what its path is, to verify that an artifact satisfies its content hash on-disk, etc.  Hash-aware functions include: `artifact_exists()`, `artifact_path()`, `remove_artifact()`, `verify_artifact()` and `archive_artifact()`.  Note that in general you should not use `remove_artifact()` and should instead use `Pkg.gc()` to cleanup artifact installations.

* **Name-aware** functions deal with bound names within an `Artifacts.toml` file, and as such, typically require both a path to an `Artifacts.toml` file as well as the artifact name.  Name-aware functions include: `artifact_meta()`, `artifact_hash()`, `bind_artifact!()`, `unbind_artifact!()`, `download_artifact()` and `ensure_artifact_installed()`.

* **Utility** functions deal with miscellaneous aspects of artifact life, such as `create_artifact()`, `ensure_all_artifacts_installed()`, and even the `@artifact_str` string macro.

For a full listing of docstrings and methods, see the [Artifacts Reference](@ref) section.

## Overriding artifact locations

It is occasionally necessary to be able to override the location and content of an artifact.
A common use case is a computing environment where certain versions of a binary dependency must be used, regardless of what version of this dependency a package was published with.
While a typical Julia configuration would download, unpack and link against a generic library, a system administrator may wish to disable this and instead use a library already installed on the local machine.
To enable this, `Pkg` supports a per-depot `Overrides.toml` file placed within the `artifacts` depot directory (e.g. `~/.julia/artifacts/Overrides.toml` for the default user depot) that can override the location of an artifact either by content-hash or by package UUID and bound artifact name.
Additionally, the destination location can be either an absolute path, or a replacement artifact content hash.
This allows sysadmins to create their own artifacts which they can then use by overriding other packages to use the new artifact.

```TOML
# Override single hash to absolute path
78f35e74ff113f02274ce60dab6e92b4546ef806 = "/path/to/replacement"

# Override single hash to new artifact content-hash
683942669b4639019be7631caa28c38f3e1924fe = "d826e316b6c0d29d9ad0875af6ca63bf67ed38c3"

# Override package bindings by specifying the package UUID and bound artifact name
# For demonstration purposes we assume this package is called `Foo`
[d57dbccd-ca19-4d82-b9b8-9d660942965b]
libfoo = "/path/to/libfoo"
libbar = "683942669b4639019be7631caa28c38f3e1924fe"
```

Due to the layered nature of `Pkg` depots, multiple `Overrides.toml` files may be in effect at once.
This allows the "inner" `Overrides.toml` files to override the overrides placed within the "outer" `Overrides.toml` files.
To remove an override and re-enable default location logic for an artifact, insert an entry mapping to the empty string:

```TOML
78f35e74ff113f02274ce60dab6e92b4546ef806 = "/path/to/new/replacement"
683942669b4639019be7631caa28c38f3e1924fe = ""

[d57dbccd-ca19-4d82-b9b8-9d660942965b]
libfoo = ""
```

If the two `Overrides.toml` snippets as given above are layered on top of eachother, the end result will be mapping the content-hash `78f35e74ff113f02274ce60dab6e92b4546ef806` to `"/path/to/new/replacement"`, and mapping `Foo.libbar` to the artifact identified by the content-hash `683942669b4639019be7631caa28c38f3e1924fe`.
Note that while that hash was previously overridden, it is no longer, and therefore `Foo.libbar` will look directly at locations such as `~/.julia/artifacts/683942669b4639019be7631caa28c38f3e1924fe`.

Most methods that are affected by overrides have the ability to ignore overrides by setting `honor_overrides=false` as a keyword argument within them.
For UUID/name based overrides to work, `Artifacts.toml` files must be loaded with the knowledge of the UUID of the loading package.
This is deduced automatically by the `artifacts""` string macro, however if you are for some reason manually using the `Pkg.Artifacts` API within your package and you wish to honor overrides, you must provide the package UUID to API calls like `artifact_meta()` and `ensure_artifact_installed()` via the `pkg_uuid` keyword argument.

## Extending Platform Selection

!!! compat "Julia 1.7"
    Pkg's extended platform selection requires at least Julia 1.7, and is considered experimental.

New in Julia 1.6, `Platform` objects can have extended attributes applied to them, allowing artifacts to be tagged with things such as CUDA driver version compatibility, microarchitectural compatibility, julia version compatibility and more!
Note that this feature is considered experimental and may change in the future.
If you as a package developer find yourself needing this feature, please get in contact with us so it can evolve for the benefit of the whole ecosystem.
In order to support artifact selection at `Pkg.add()` time, `Pkg` will run the specially-named file `<project_root>/.pkg/select_artifacts.jl`, passing the current platform triplet as the first arugment.
This artifact selection script should print a `TOML`-serialized dictionary representing the artifacts that this package needs according to the given platform, and performing any inspection of the system as necessary to auto-detect platform capabilities, if they are not explicitly provided by the given platform triplet.
The format of the dictionary should match that returned from `Artifacts.select_downloadable_artifacts()`, and indeed most packages should simply call that function with an augmented `Platform` object.
An example artifact selection hook definition might look like the following, split across two files:

```julia
# .pkg/platform_augmentation.jl
using Libdl, Base.BinaryPlatforms
function augment_platform!(p::Platform)
    # If this platform object already has a `cuda` tag set, don't augment
    if haskey(p, "cuda")
        return p
    end

    # Open libcuda explicitly, so it gets `dlclose()`'ed after we're done
    dlopen("libcuda") do lib
        # find symbol to ask for driver version; if we can't find it, just silently continue
        cuDriverGetVersion = dlsym(lib, "cuDriverGetVersion"; throw_error=false)
        if cuDriverGetVersion !== nothing
            # Interrogate CUDA driver for driver version:
            driverVersion = Ref{Cint}()
            ccall(cuDriverGetVersion, UInt32, (Ptr{Cint},), driverVersion)

            # Store only the major version
            p["cuda"] = div(driverVersion, 1000)
        end
    end

    # Return possibly-altered `Platform` object
    return p
end
```

```julia
using TOML, Artifacts, Base.BinaryPlatforms
include("./platform_augmentation.jl")
artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")

# Get "target triplet" from ARGS, if given (defaulting to the host triplet otherwise)
target_triplet = get(ARGS, 1, Base.BinaryPlatforms.host_triplet())

# Augment this platform object with any special tags we require
platform = augment_platform!(HostPlatform(parse(Platform, target_triplet)))

# Select all downloadable artifacts that match that platform
artifacts = select_downloadable_artifacts(artifacts_toml; platform)

# Output the result to `stdout` as a TOML dictionary
TOML.print(stdout, artifacts)
```

In this hook definition, our platform augmentation routine opens a system library (`libcuda`), searches it for a symbol to give us the CUDA driver version, then embeds the major version of that version number into the `cuda` property of the `Platform` object we are augmenting.
While it is not critical for this code to actually attempt to close the loaded library (as it will most likely be opened again by the CUDA package immediately after the package operations are completed) it is best practice to make hooks as lightweight and transparent as possible, as they may be used by other Pkg utilities in the future.
In your own package, you should also use augmented platform objects when using the `@artifact_str` macro, as follows:

```julia
include("../.pkg/platform_augmentation.jl")

function __init__()
    p = augment_platform!(HostPlatform())
    global my_artifact_dir = @artifact_str("MyArtifact", p)
end
```

This ensures that the same artifact is used by your code as Pkg attempted to install.