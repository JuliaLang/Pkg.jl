module ScratchUsage
using Pkg, Pkg.Scratch

const my_uuid = Pkg.API.get_uuid(@__MODULE__)
const my_version = Pkg.API.get_version(my_uuid)

# This function will create a bevy of spaces here
function touch_scratch()
    # Create an explicitly version-specific space
    private_space = get_scratch!(
        string(my_version.major, ".", my_version.minor, ".", my_version.patch),
        my_uuid,
    )
    touch(joinpath(private_space, string("ScratchUsage-", my_version)))

    # Create a space shared between all instances of the same major version,
    # using the `@get_scratch!` macro which automatically looks up the UUID
    major_space = @get_scratch!(string(my_version.major))
    touch(joinpath(major_space, string("ScratchUsage-", my_version)))

    # Create a global space that is not locked to this package at all
    global_space = get_scratch!("GlobalSpace")
    touch(joinpath(global_space, string("ScratchUsage-", my_version)))
end

end # module ScratchUsage