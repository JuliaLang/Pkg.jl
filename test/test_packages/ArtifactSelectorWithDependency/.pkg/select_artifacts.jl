push!(LOAD_PATH, dirname(@__DIR__))

# Record every run so tests can count how often the selector is invoked.
open(io -> println(io, join(ARGS, " ")), joinpath(dirname(@__DIR__), "selector_runs"), "a")

using ArtifactSelectorDependency
using Artifacts, TOML
using Base.BinaryPlatforms

platform = HostPlatform(parse(Platform, only(ARGS)))
platform["selection"] = ArtifactSelectorDependency.selection
artifacts_toml = joinpath(dirname(@__DIR__), "Artifacts.toml")
TOML.print(stdout, select_downloadable_artifacts(artifacts_toml; platform))
