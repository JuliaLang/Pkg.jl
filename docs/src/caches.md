# [**9.** Caches](@id Caches)

!!! compat "Julia 1.6"
    Pkg's caches functionality requires at least Julia 1.6.

`Pkg` can manage and lifecycle caches of temporary or readily-recreatable data.
These caches can contain datasets, text, binaries, or any other kind of data that would be convenient to store, but which is non-fatal to have garbage collected if it has not been accessed recently, or if the owning package has been uninstalled.
As compared to [Artifacts](@ref), these containers of data are mutable and can be deleted at any time; all usage of caches should assume that the data stored within them could be gone by the next time the script is run.
In the current implementation, caches are removed during [Pkg.gc](@ref) garbage collection if the cache has not been accessed within the last month, or if the owning package has been removed.
Users can also request a cache wipe to clean up unused disk space.

## API overview

Cache usage is performed primarily through one function: `get_cache!()`.
It provides a single interface for creating and getting previously-created caches, either tied to a package by its UUID, or as a global cache.
Here is an example where a package creates a cache that is specific to its own version:

```julia
module CacheExample
using Pkg, Pkg.Caches

download_cache = ""
shared_cache = ""

function download_dataset(url)
    fname = joinpath(download_cache, basename(url))
    if !isfile(fname)
        download(url, fname)
    end
end

function __init__()
    global download_cache = @get_cache!("downloaded_files")
end

end # module
```

Note that we initialize the `download_cache` within `__init__()` so that our packages are as relocatable as possible; we typically do not want to bake absolute paths into our precompiled files.
This makes use of the `@get_cache!()` macro, which is identical to the `get_cache!()` method, except it automatically determines the UUID of the calling module, if possible.
An equivalent (but more verbose) invocation is given here:
```julia
function __init__()
    global download_cache = get_cache!("downloaded_files";
                                       pkg_uuid=Base.PkgId(@__MODULE__).uuid)
end
```

If a user wishes to manually delete a cache, the method `delete_cache!(key; pkg_uuid)` is the natural analog to `get_cache!()`, however in general users will not need to do so, the caches will be garbage collected by `Pkg` automatically.

For a full listing of docstrings and methods, see the [Caches Reference](@ref) section.

## Usecases

Good usecases for a Pkg cache include:

* Caching downloads of files that must be routinely accessed and modified by a package.  Files that must be modified are a bad fit for the immutable [Artifacts](@ref) abstraction, and files can always be re-downloaded if the cache is wiped by the user.

* Generated data that depends on the characteristics of the host system.  Examples are compiled binaries, fontcache system font folder inspection output, generated CUDA bitcode files, etc...  Objects that would be difficult to compute off of the user's machine, and that can be recreated without user intervention are a great fit.

* Directories that should be shared between multiple packages in a single depot.  The cache keying mechanism (explained below) makes it simple to provide scratch space that can be shared between different versions of a package, or even between different packages.  This allows packages to provide a scratch space where other packages can easily find the generated data, however the typical race condition warnings apply here; always design your access patterns assuming another process could be reading or writing to this scratch space at any time.

Bad usecases for a Pkg cache include (but are not limited to):

* Anything that requires user input to regenerate.  Because caches can disappear, it is a bad experience for the user to need to answer questions at seemingly random times when the cache must be rebuilt.

* Storing data that is write-once, read-many times.  We suggest you use [Artifacts](@ref) for that, as they are much more persistent and are built to become portable (so that other machines do not have to generate the data, they can simple make use of the artifact by downloading it from a hosted location).  Caches generally should follow a write-many read-many access pattern.

## Frequently-Accessed Caching Questions

> Can I trigger data regeneration if the cache is empty?

Yes, this is quite simple; just check to see if the directory is empty, and if it is, run your generation function:

```julia
function get_dataset_dir()
    dataset_dir = @get_cache!("dataset")
    if isempty(readdir(dataset_dir))
        perform_expensive_dataset_generation(dataset_dir)
    end
    return dataset_dir
end
```

> Can I create a cache that is not shared across versions of my package?

Yes!  Make use of the `key` parameter and Pkg's ability to look up the current version of your package at compile-time:

```julia
module VersionSpecificExample
using Pkg, Pkg.Caches

# Helpers to get current package UUID and VersionNumber
function get_uuid()
    return Base.PkgId(@__MODULE__).uuid
end
function get_version(uuid)
    ctx = Pkg.Types.Context()
    uuid, entry = first(filter(((u, e),) -> u == uuid, ctx.env.manifest))
    return entry.version
end

# Get the current version at compile-time, that's fine it's not going to change. ;)
const v = get_version(get_uuid())

# This will be filled in by `__init__()`; it might change if we get deployed somewhere
version_specific_cache = ""

function __init__()
    # This cache will be unique between versions of my package that different major and
    # minor versions, but allows patch releases to share the same.
    global version_specific_cache = @get_cache!("data_for_version-$(v.major).$(v.minor)")
end

end # module
```

> Can I use a cache as a temporary workspace, then turn it into an Artifact?

Yes!  Once you're satisfied with your dataset that has been cooking inside a cache, and you're ready to share it with the world as an immutable artifact, you can use `create_artifact()` to create an artifact from the cache, `archive_artifact()` to get a tarball that you can upload somewhere, and `bind_artifact!()` to write out an `Artifacts.toml` that allows others to download and use it:

```julia
using Pkg, Pkg.Caches, Pkg.Artifacts
function export_cache(cache_name::String)
    cache_dir = @get_cache!(cache_name)

    # Copy cache directory over to an Artifact
    hash = create_artifact() do artifact_dir
        cp(cache_dir, artifact_dir)
    end

    # Archive artifact out to a tarball
    mktempdir() do upload_dir
        tarball_path = joinpath(upload_dir, "$(cache_name).tar.gz")
        tarball_hash = archive_artifact(hash, tarball_path)

        # Upload tarball to a hosted site somewhere.  Note; this function does not exist:
        tarball_url = upload_tarball(tarball_path)

        # Bind artifact to an Artifacts.toml file in the current directory; this file can
        # be used by others to download and use your newly-created Artifact!
        bind_artifact!(
            joinpath(@__DIR__, "./Artifacts.toml"),
            cache_name,
            hash;
            download_info=[(tarball_url, tarball_hash)],
            force=true,
        )
    end
end
```