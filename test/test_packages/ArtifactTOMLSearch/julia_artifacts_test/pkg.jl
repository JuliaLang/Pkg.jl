module ATSMod

using Pkg.Artifacts

# All this module will do is reference its `arty` Artifact.
arty = artifact"arty"

function do_test()
    return isfile(joinpath(arty, "bin", "socrates"))
end

end # module
