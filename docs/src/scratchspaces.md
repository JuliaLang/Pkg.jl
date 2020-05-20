# [**9.** Scratch Spaces](@id Scratch-Spaces)

!!! compat "Julia 1.6"
    Pkg's Scratch Spaces functionality requires at least Julia 1.6.

`Pkg` can manage and automatically garbage collect scratch spaces of temporary or readily-recreatable data.
These spaces can contain datasets, text, binaries, or any other kind of data that would be convenient to store, but which is non-fatal to have garbage collected if it has not been accessed recently, or if the owning package has been uninstalled.
As compared to [Artifacts](@ref), these containers of data are mutable and should be treated as ephemeral; all usage of scratch spaces should assume that the data stored within them could be gone by the next time your code is run.
In the current implementation, scratch spaces are removed during Pkg garbage collection if the scratch space has not been accessed for a period of time (see the `scratch_cleanup_period` keyword argument to [Pkg.gc](@ref)), or if the owning package has been removed.
Users can also request a full wipe of all scratch spaces to clean up unused disk space through `Pkg.Scratch.clear_scratchspaces!()`.

## API overview

Scratch space usage is performed primarily through one function: `get_scratch!()`.
It provides a single interface for creating and getting previously-created spaces, either tied to a package by its UUID, or as a global scratch space that can be accessed by any package.
Here is an example where a package creates a scratch space that is namespaced to its own UUID:

```julia
module ScratchExample
using Pkg, Pkg.Scratch

# This will be filled in inside `__init__()`
download_cache = ""

# Downloads a resource, stores it within a scratchspace
function download_dataset(url)
    fname = joinpath(download_cache, basename(url))
    if !isfile(fname)
        download(url, fname)
    end
    return fname
end

function __init__()
    global download_cache = @get_scratch!("downloaded_files")
end

end # module ScratchExample
```

Note that we initialize the `download_cache` within `__init__()` so that our packages are as relocatable as possible; we typically do not want to bake absolute paths into our precompiled files.
This makes use of the `@get_scratch!()` macro, which is identical to the `get_scratch!()` method, except it automatically determines the UUID of the calling module, if possible. The user can manually pass in a `Module` as well for a slightly more verbose incantation:
```julia
function __init__()
    global download_cache = get_scratch!("downloaded_files", @__MODULE__)
end
```

If a user wishes to manually delete a scratch space, the method `delete_scratch!(key; pkg_uuid)` is the natural analog to `get_scratch!()`, however in general users will not need to do so, the scratch spaces will be garbage collected by `Pkg` automatically.

For a full listing of docstrings and methods, see the [Scratch Space Reference](@ref) section.

## Use cases

Good use cases for a Pkg scratch space include:

* Caching downloads of files that must be routinely accessed and modified by a package.  Files that must be modified are a bad fit for the immutable [Artifacts](@ref) abstraction, and files can always be re-downloaded if the cache is wiped by the user.

* Generated data that depends on the characteristics of the host system.  Examples are compiled binaries, fontcache system font folder inspection output, generated CUDA bitcode files, etc...  Objects that would be difficult to compute off of the user's machine, and that can be recreated without user intervention are a great fit.

* Directories that should be shared between multiple packages in a single depot.  The scratch space keying mechanism makes it simple to provide scratch spaces that can be shared between different versions of a package, or even between different packages.  This allows packages to provide a scratch space where other packages can easily find the generated data, however the typical race condition warnings apply here; always design your access patterns assuming another process could be reading or writing to this scratch space at any time.

Bad use cases for a Pkg scratch space include (but are not limited to):

* Anything that requires user input to regenerate.  Because scratch spaces can disappear, it is a bad experience for the user to need to answer questions at seemingly random times when the space must be rebuilt.

* Storing data that is write-once, read-many times.  We suggest you use [Artifacts](@ref) for that, as they are much more persistent and are built to become portable (so that other machines do not have to generate the data, they can simple make use of the artifact by downloading it from a hosted location).  Scratch spaces generally should follow a write-many read-many access pattern.

## Tips and Tricks

> Can I trigger data regeneration if the scratch space is found to be empty/files are missing?

Yes, this is quite simple; just check the contents of the directory when you first call `get_scratch!()`, and if it's empty, run your generation function:

```julia
using Pkg, Pkg.Scratch

function get_dataset_dir()
    dataset_dir = @get_scratch!("dataset")
    if isempty(readdir(dataset_dir))
        perform_expensive_dataset_generation(dataset_dir)
    end
    return dataset_dir
end
```

> Can I create a scratch space that is not shared across versions of my package?

Yes!  Make use of the `key` parameter and Pkg's ability to look up the current version of your package at compile-time:

```julia
module VersionSpecificExample
using Pkg, Pkg.Scratch

# Get the current version at compile-time, that's fine it's not going to change. ;)
const pkg_version = Pkg.API.get_version(Pkg.API.get_uuid(@__MODULE__))

# This will be filled in by `__init__()`; it might change if we get deployed somewhere
version_specific_scratch = Ref{String}()

function __init__()
    # This space will be unique between versions of my package that different major and
    # minor versions, but allows patch releases to share the same.
    scratch_name = "data_for_version-$(pkg_version.major).$(pkg_version.minor)"
    global version_specific_scratch[] = @get_scratch!(scratch_name)
end

end # module
```

> Can I use a scratch space as a temporary workspace, then turn it into an Artifact?

Yes!  Once you're satisfied with your dataset that has been cooking inside a space, and you're ready to share it with the world as an immutable artifact, you can use `create_artifact()` to create an artifact from the space, `archive_artifact()` to get a tarball that you can upload somewhere, and `bind_artifact!()` to write out an `Artifacts.toml` that allows others to download and use it:

```julia
using Pkg, Pkg.Scratch, Pkg.Artifacts

function export_scratch(scratch_name::String, github_repo::String)
    scratch_dir = @get_scratch!(scratch_name)

    # Copy space directory over to an Artifact
    hash = create_artifact() do artifact_dir
        rm(artifact_dir)
        cp(scratch_dir, artifact_dir)
    end

    # Archive artifact out to a tarball.  Since `upload_tarball()` is not a function that
    # exists, users must either write it themselves (uploading to whatever hosting
    # provider they prefer), or run each line of this `do`-block manually, upload the
    # tarball manually, record its URL, and pass that to `bind_artifact!()`.
    mktempdir() do upload_dir
        tarball_path = joinpath(upload_dir, "$(scratch_name).tar.gz")
        tarball_hash = archive_artifact(hash, tarball_path)

        # Upload tarball to a hosted site somewhere.  Note; this function does not
        # exist, it's put here simply to show the flow of events.
        tarball_url = upload_tarball(tarball_path)

        # Bind artifact to an Artifacts.toml file in the current directory; this file can
        # be used by others to download and use your newly-created Artifact!
        bind_artifact!(
            joinpath(@__DIR__, "./Artifacts.toml"),
            scratch_name,
            hash;
            download_info=[(tarball_url, tarball_hash)],
            force=true,
        )
    end
end
```