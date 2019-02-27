import Pkg
build_artifact = joinpath(@__DIR__, "artifact")
isfile(build_artifact) && rm(build_artifact)
@assert Pkg.installed()["JSON"] == v"0.19.0"
touch(build_artifact)