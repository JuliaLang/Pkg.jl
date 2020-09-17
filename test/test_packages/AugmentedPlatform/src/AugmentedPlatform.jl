module AugmentedPlatform
using Artifacts
export get_artifact_dir

# Use our platform augmentation function to get consistent results
include("../.pkg/platform_augmentation.jl")
function get_artifact_dir(name)
    return @artifact_str(name, augment_platform!(HostPlatform()))
end

end # module AugmentedPlatform
