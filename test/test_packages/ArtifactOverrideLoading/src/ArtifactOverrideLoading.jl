__precompile__(false)
module ArtifactOverrideLoading
using Pkg.Artifacts
export arty_path, barty_path

# These will fail (get set to `nothing`) unless they get redirected
const arty_path = artifact"arty"
const barty_path = artifact"barty"

end # module
