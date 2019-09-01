module RegistrySpecs

export RegistrySpec, collect_registries, read_registry, verify_registry

using  UUIDs
import ..TOML, ..depots

###
### Constants
###

# path -> (mtime, TOML Dict)
const REGISTRY_CACHE = Dict{String, Tuple{Float64, Dict{String, Any}}}()
const REQUIRED_REGISTRY_ENTRIES = ("name", "uuid", "repo", "packages") # ??

###
### RegistrySpec
###
mutable struct RegistrySpec
    name::Union{String,Nothing}
    uuid::Union{UUID,Nothing}
    url::Union{String,Nothing}
    # the path field can be a local source when adding a registry
    # otherwise it is the path where the registry is installed
    path::Union{String,Nothing}
    RegistrySpec(name::String) = RegistrySpec(name = name)
    RegistrySpec(;name=nothing, uuid=nothing, url=nothing, path=nothing) =
        new(name, isa(uuid, String) ? UUID(uuid) : uuid, url, path)
end

###
###
###

# Return `RegistrySpec`s of each registry in a depot
function collect_registries(depot::String)
    d = joinpath(depot, "registries")
    regs = RegistrySpec[]
    ispath(d) || return regs
    for name in readdir(d)
        file = joinpath(d, name, "Registry.toml")
        if isfile(file)
            registry = read_registry(file)
            verify_registry(registry)
            spec = RegistrySpec(name = registry["name"],
                                uuid = UUID(registry["uuid"]),
                                url = get(registry, "repo", nothing),
                                path = dirname(file))
            push!(regs, spec)
        end
    end
    return regs
end

# Return `RegistrySpec`s of all registries in all depots
function collect_registries()
    isempty(depots()) && return RegistrySpec[]
    return RegistrySpec[r for d in depots() for r in collect_registries(d)]
end

# verify that the registry looks like a registry
function verify_registry(registry::Dict{String, Any})
    for key in REQUIRED_REGISTRY_ENTRIES
        haskey(registry, key) || pkgerror("no `$key` entry in `Registry.toml`.")
    end
end

function read_registry(reg_file; cache=true)
    t = mtime(reg_file)
    if haskey(REGISTRY_CACHE, reg_file)
        prev_t, registry = REGISTRY_CACHE[reg_file]
        t == prev_t && return registry
    end
    registry = TOML.parsefile(reg_file)
    cache && (REGISTRY_CACHE[reg_file] = (t, registry))
    return registry
end

end #module
