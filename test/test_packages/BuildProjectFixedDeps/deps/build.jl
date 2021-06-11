import TOML
build_artifact = joinpath(@__DIR__, "artifact")
isfile(build_artifact) && rm(build_artifact)
project = TOML.parsefile(Base.active_project())
@assert get(project["deps"], "JSON", nothing) === nothing

# Backwards compat with 1.6.1
function is_v1_format_manifest(raw_manifest::Dict)
    if haskey(raw_manifest, "manifest_format")
        if raw_manifest["manifest_format"] isa Dict && haskey(raw_manifest["manifest_format"], "uuid")
            # the off-chance where an old format manifest has a dep called "manifest_format"
            return true
        end
        return false
    else
        return true
    end
end
# returns a deps list for both old and new manifest formats
function get_deps(raw_manifest::Dict)
    if is_v1_format_manifest(raw_manifest)
        return raw_manifest
    else
        # if the manifest has no deps, there won't be a `deps` field
        return get(Dict{String, Any}, raw_manifest, "deps")
    end
end

manifest = get_deps(TOML.parsefile(joinpath(dirname(Base.active_project()), "Manifest.toml")))
json = manifest["JSON"][1]
@assert json["uuid"] == "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
@assert json["version"] == "0.19.0"
touch(build_artifact)
