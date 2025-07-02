import TOML
build_artifact = joinpath(@__DIR__, "artifact")
isfile(build_artifact) && rm(build_artifact)
project = TOML.parsefile(Base.active_project())
@assert get(project["deps"], "JSON", nothing) === nothing
manifest = Base.get_deps(TOML.parsefile(joinpath(dirname(Base.active_project()), "Manifest.toml")))
json = manifest["JSON"][1]
@assert json["uuid"] == "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
@assert json["version"] == "0.19.0"
touch(build_artifact)
