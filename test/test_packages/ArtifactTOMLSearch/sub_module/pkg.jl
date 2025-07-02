module SubModule
using Pkg.Artifacts

# All this module will do is reference its `arty` Artifact.
arty = artifact"arty"
end
