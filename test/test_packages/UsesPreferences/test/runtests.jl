using UsesPreferences, Test, Pkg, Pkg.Preferences

# Get the UUID for UsesPreferences
up_uuid = Pkg.API.get_uuid(UsesPreferences)

prefs = load_preferences(up_uuid)
@test haskey(prefs, "backend")
@test prefs["backend"] == "OpenCL"
@test UsesPreferences.get_backend() == "OpenCL"

UsesPreferences.set_backend("CUDA")
prefs = load_preferences(up_uuid)
@test haskey(prefs, "backend")
@test prefs["backend"] == "CUDA"
@test UsesPreferences.get_backend() == "CUDA"

# sorry, AMD
@test_throws ArgumentError UsesPreferences.set_backend("ROCm")
prefs = load_preferences(up_uuid)
@test haskey(prefs, "backend")
@test prefs["backend"] == "CUDA"
@test UsesPreferences.get_backend() == "CUDA"

clear_preferences!(up_uuid)
prefs = load_preferences(up_uuid)
@test !haskey(prefs, "backend")
@test UsesPreferences.get_backend() == "CUDA"

# And finally, save something back so that the parent process can read it:
UsesPreferences.set_backend("jlFPGA")