module ArtifactSelectorDependency

using Artifacts

const selection = String(strip(read(joinpath(artifact"bootstrap", "selection"), String)))

end
