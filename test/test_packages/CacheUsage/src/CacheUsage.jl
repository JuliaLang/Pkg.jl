module CacheUsage
using Pkg, Pkg.Caches

function get_version(uuid)
    ctx = Pkg.Types.Context()

    # We know that we will always be listed in the manifest during tests.
    uuid, entry = first(filter(((u, e),) -> u == uuid, ctx.env.manifest))
    return entry.version
end

const my_uuid = Base.PkgId(@__MODULE__).uuid
const my_version = get_version(my_uuid)

# This function will create a bevy of caches here
function touch_caches()
    # Create an explicitly version-specific cache
    private_cache = get_cache!(
        string(my_version.major, ".", my_version.minor, ".", my_version.patch);
        pkg_uuid=my_uuid,
    )
    touch(joinpath(private_cache, string("CacheUsage-", my_version)))

    # Create a cache shared between all instances of the same major version,
    # using the `@get_cache!` macro which automatically looks up the UUID
    major_cache = @get_cache!(string(my_version.major))
    touch(joinpath(major_cache, string("CacheUsage-", my_version)))

    # Create a global cache that is not locked to this package at all
    global_cache = get_cache!("GlobalCache")
    touch(joinpath(global_cache, string("CacheUsage-", my_version)))
end

end # module CacheUsage