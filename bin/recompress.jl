import Pkg: TOML, Compress
import Pkg.Types: VersionSpec, compress_versions

const registry_path = joinpath(DEPOT_PATH[1], "registries", "General")
const registry_file = joinpath(registry_path, "Registry.toml")
const packages = TOML.parsefile(registry_file)["packages"]

const julia_uuid = "1222c4b2-2114-5bfd-aeef-88e4692bbb3e"
const version_map = Dict{String,Vector{VersionNumber}}()

for (uuid, info) in packages
    path = joinpath(registry_path, info["path"])
    versions_file = joinpath(path, "Versions.toml")
    versions = Compress.load(versions_file)
    version_map[uuid] = sort!(collect(keys(versions)))
end

for (_, info) in packages
    path = joinpath(registry_path, info["path"])
    # load and normalize Deps.toml
    deps_file = joinpath(path, "Deps.toml")
    isfile(deps_file) || continue
    deps = Compress.load(deps_file)
    Compress.save(deps_file, deps)
    # load and normalize Compat.toml
    compat_file = joinpath(path, "Compat.toml")
    isfile(compat_file) || continue
    compat = Compress.load(compat_file)
    for (ver, data) in compat
        for (dep, spec) in data
            uuid = dep == "julia" ? julia_uuid : deps[ver][dep]
            ranges = VersionSpec(spec).ranges
            compat[ver][dep] =
                length(ranges) == 1 ? string(ranges[1]) : map(string, ranges)
        end
    end
    Compress.save(compat_file, compat)
end
