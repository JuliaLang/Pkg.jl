module Caches
import ...Pkg
using ...Pkg.TOML, Dates

export with_caches_directory, caches_dir, get_cache!, delete_cache!, @get_cache!

const CACHES_DIR_OVERRIDE = Ref{Union{String,Nothing}}(nothing)
"""
    with_caches_directory(f::Function, caches_dir::String)

Helper function to allow temporarily changing the cache directory.  When this is set,
no other directory will be searched for caches, and new caches will be created within
this directory.  Similarly, removing a cache will only effect the given cache directory.
"""
function with_caches_directory(f::Function, caches_dir::String)
    try
        CACHES_DIR_OVERRIDE[] = caches_dir
        f()
    finally
        CACHES_DIR_OVERRIDE[] = nothing
    end
end

"""
    caches_dir(args...)

Returns a path within the current depot's `caches` directory.  This location can be
overridden via `with_caches_directory()`.
"""
function caches_dir(args...)
    if CACHES_DIR_OVERRIDE[] === nothing
        return abspath(Pkg.depots1(), "caches", args...)
    else
        # If we've been given an override, use _only_ that directory.
        return abspath(CACHES_DIR_OVERRIDE[], args...)
    end
end

"""
    cache_path(key, pkg_uuid)

Common utility function to return the path of a cache, keyed by the given parameters.
Users should use `get_cache!()` for most user-facing usage.
"""
function cache_path(key::AbstractString, pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    # If we were given a UUID, we'll namespace our cache within that UUID:
    cache_path = ()
    if pkg_uuid !== nothing
        cache_path = (string(pkg_uuid),)
    end

    # Tack the key onto the end of the cache path
    cache_path = (cache_path..., key)
    return caches_dir(cache_path...)
end

# Session-based cache access time tracker
cache_access_timers = Dict{String,Float64}()
"""
    track_cache_access(pkg_uuid, cache_path)

We need to keep track of who is using what caches, so we know when it is advisable to
remove them during a GC.  We do this by attributing accesses of caches to `Manifest.toml`
files in much the same way that package versions themselves are logged upon install, only
instead of having the manifest information implicitly available, we must rescue it out
from the currently-active Pkg Env.  If we cannot do that, it is because someone is doing
something weird like opening a cache for a Pkg UUID that is not loadable, which we will
simply not track; that cache will be reaped after the appropriate time in an orphanage.

If `pkg_uuid` is explicitly set to `nothing`, this cache is treated as belonging to the
default global manifest next to the global project at `Base.load_path_expand("@v#.#")`.

While package and artifact access tracking can be done at `add()`/`instantiate()` time,
we must do it at access time for caches, as we have no declarative list of caches that
a package may or may not access throughout its lifetime.  To avoid building up a
ludicrously large number of accesses through programs that e.g. call `get_cache!()` in a
loop, we only write out usage information for each cache once per day at most.
"""
function track_cache_access(pkg_uuid::Union{Base.UUID,Nothing}, cache_path::AbstractString)
    # Don't write this out more than once per day within the same Julia session.
    curr_time = time()
    if get(cache_access_timers, cache_path, 0.0) >= curr_time - 60*60*24
        @warn("bailing too often")
        return
    end

    function find_project_file(pkg_uuid)
        # The simplest case (`pkg_uuid` == `nothing`) simply attributes the cache to
        # the global depot environment, which will never cause the cache to be GC'ed
        # because it has been removed, as long as the depot itself is intact.
        if pkg_uuid === nothing
            return Base.load_path_expand("@v#.#")
        end

        # The slightly more complicated case inspects the currently-loaded Pkg env
        # to find the project file that we should tie our lifetime to.  If we can't
        # find it, we'll return `nothing` and skip tracking access.
        ctx = Pkg.Types.Context()

        # Check to see if the UUID is the overall project itself:
        if ctx.env.pkg !== nothing && ctx.env.pkg.uuid == pkg_uuid
            return ctx.env.project_file
        end

        # Finally, check to see if the package is loadable from the current environment
        if haskey(ctx.env.manifest, pkg_uuid)
            pkg_entry = ctx.env.manifest[pkg_uuid]
            pkg_path = Pkg.Operations.source_path(
                ctx,
                Pkg.Types.PackageSpec(
                    name=pkg_entry.name,
                    uuid=pkg_uuid,
                    tree_hash=pkg_entry.tree_hash,
                    path=pkg_entry.path,
                )
            )
            project_path = joinpath(pkg_path, "Project.toml")
            if isfile(project_path)
                return project_path
            end
        end

        # If we couldn't find anything to attribute the cache to, return `nothing`.
        return nothing
    end

    # FWe must decide which manifest to attribute this cache to.
    project_file = find_project_file(pkg_uuid)

    # If we couldn't find one, skip out.
    if project_file === nothing
        @warn("bailing no project")
        return
    end

    entry = Dict(
        "time" => now(),
        "parent_project" => project_file,
    )
    Pkg.Types.write_env_usage(cache_path, "caches_usage.toml", entry)

    # Record that we did, in fact, write out the cache access time
    cache_access_timers[cache_path] = curr_time
end


const VersionConstraint = Union{VersionNumber,AbstractString,Nothing}

"""
    get_cache!(key::AbstractString; pkg_uuid = nothing)

Returns the path to (or creates) a cache.

If `pkg_uuid` is defined, the cache lifecycle is tied to that package, and the cache is
namespaced within that package.  If all versions of the package that used the cache are
uninstalled, the cache will be cleaned up on a future garbage collection run.

If `pkg_uuid` is not defined, a global cache that is not explicitly lifecycled will be
created.

In the current implementation, caches are removed if they have not been accessed for a
predetermined amount of time (see `Pkg.gc()` for more) or sooner if the package versions
they are lifecycled to are garbage collected.

!!! note
    Package caches should never be treated as persistent storage; they are allowed to
    disappear at any time, and all content within them must be nonessential or easily
    recreatable.  All lifecycle guarantees set a maximum lifetime for the cache, never
    a minimum.
"""
function get_cache!(key::AbstractString; pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    # Calculate the path and create the containing folder
    path = cache_path(key, pkg_uuid)
    mkpath(path)

    # We need to keep track of who is using caches, so we track usage in a log
    track_cache_access(pkg_uuid, path)
    return path
end

"""
    delete_cache!(;key, pkg_uuid)

Explicitly deletes a cache created through `get_cache!()`.
"""
function delete_cache!(key::AbstractString; pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    path = cache_path(key, pkg_uuid)
    rm(path; force=true, recursive=true)
    delete!(cache_access_timers, path)
    return nothing
end

"""
    @get_cache!(key)

Convenience macro that gets/creates a cache lifecycled to the package the calling module
belongs to with the given key.  If the calling module does not belong to a package,
(e.g. if it is `Main`) the UUID will be taken to be `nothing`, creating a global cache.
"""
macro get_cache!(key)
    # Note that if someone uses this in the REPL, it
    uuid = Base.PkgId(__module__).uuid
    return quote
        get_cache!($(esc(key)); pkg_uuid=$(esc(uuid)))
    end
end

end # module Caches