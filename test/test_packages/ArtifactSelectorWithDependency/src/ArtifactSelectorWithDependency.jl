module ArtifactSelectorWithDependency

using ArtifactSelectorDependency
using Artifacts
using Base.BinaryPlatforms

function selected_artifact()
    platform = HostPlatform()
    platform["selection"] = ArtifactSelectorDependency.selection
    artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
    hash = artifact_hash("selected", artifacts_toml; platform)
    return strip(read(joinpath(artifact_path(hash), "selection"), String))
end

end
