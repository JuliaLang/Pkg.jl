const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

struct Package
    name::String
    uuid::UUID
    # Is a version required?
    version::VersionNumber
end

struct Dependency
    name::String
    uuid::UUID
    compat::VersionSpec
    # for roundtripping we keep the unexpanded compat string
    compat_str::String
end

struct Project
    filename::String
    pkg::Union{Nothing, Package}
    deps::Dict{UUID, Dependency}
    extras::Dict{UUID, Dependency}
    targets::Dict{String, Vector{UUID}}

    # Convenient to have a reverse lookup
    name_to_uuid::Dict{String, UUID}

    # Other stuff in the project file
    # that are not tracked
    stuff::Dict{String, Any}
end

function Base.copy(p::Project)
    Project(
        p.filename,
        p.pkg,
        copy(p.deps),
        copy(p.extras),
        copy(p.targets),
        copy(p.name_to_uuid),
        copy(p.stuff),
    )
end

default_compat() = VersionSpec()

function Project(project_path::String)
    d = isfile(project_path) ? TOML.parsefile(project_path) : Dict{String, Any}()

    # Package
    name = pop!(d, "name", nothing)::Union{Nothing, String}
    uuid = pop!(d, "uuid", nothing)::Union{Nothing, String}
    version = pop!(d, "version", nothing)::Union{Nothing, String}
    pkg = if name !== nothing
        uuid === nothing && error("todo")
        version === nothing && error("todo")
        Package(name, UUID(uuid), VersionNumber(version))
    else
        nothing
    end

    # Compat
    compats_toml = pop!(d, "compat", nothing)::Union{Nothing, Dict{String, Any}}
    compats = Dict{String, VersionSpec}()
    if compats_toml !== nothing
        for (name, compat_toml) in compats_toml
            compat_toml::String
            compats[name] = semver_spec(compat_toml)
        end
    end

    name_to_uuid = Dict{String, UUID}()

    function compat_data(name)
        if compats_toml !== nothing
            compat_toml = get(compats_toml, name, nothing)::Union{String, Nothing}
            if compat_toml !== nothing
                return semver_spec(compat_toml), compat_toml
            end
        end
        return default_compat(), ""
    end

    function extract_deps(key)
        deps_toml = pop!(d, key, nothing)::Union{Nothing, Dict{String, Any}}
        deps = Dict{UUID, Dependency}()
        if deps_toml !== nothing
            for (name, uuid) in deps_toml
                uuid = UUID(uuid::String)
                name_to_uuid[name] = uuid
                compat, compat_str = compat_data(name)
                deps[uuid] = Dependency(
                    name,
                    uuid,
                    compat,
                    compat_str
                )
            end
        end
        return deps
    end

    julia_compat, julia_compat_str = compat_data("julia")
    mdeps = extract_deps("deps")
    mdeps[JULIA_UUID] = Dependency(
        "julia",
        JULIA_UUID,
        julia_compat,
        julia_compat_str,
    )
    extras = extract_deps("extras")

    # Targets
    targets_toml = pop!(d, "targets", nothing)::Union{Nothing, Dict{String, Any}}
    targets = Dict{String, Vector{UUID}}()
    if targets_toml !== nothing
        for (target, pkgs) in targets_toml
            targets[target] = UUID[name_to_uuid[pkg] for pkg in pkgs]
        end
    end

    # everything that is not deleted from `d` is extra stuff that we keep around
    # so we can round trip it
    Project(basename(project_path), pkg, mdeps, extras, targets, name_to_uuid, d)
end

# Printing
function destructure(p::Project)
    d = Dict{String, Any}()

    # Package
    if p.pkg !== nothing
        pkg = p.pkg
        d["name"] = pkg.name
        d["uuid"] = string(pkg.uuid)
        d["version"] = string(pkg.version)
    end

    # Deps
    d["deps"] = Dict(dep.name => string(dep.uuid) for (_, dep) in p.deps)

    # Compat
    d["compat"] = Dict(dep.name => string(dep.compat_str) for (_, dep) in p.deps if dep.compat != default_compat())

    # Extras
    d["extras"] = Dict(dep.name => string(dep.uuid) for (_, dep) in p.extras)

    # Targets

    targets = Dict{String, Any}()
    for (target, uuids) in p.targets
        targets[target] = String[p.extras[uuid].name for uuid in uuids]
    end
    d["targets"] = targets

    merge!(d, p.stuff)

    return d
end

_project_key_order = ["name", "uuid", "keywords", "license", "desc", "deps", "compat"]
project_key_order(key::String) =
    something(findfirst(x -> x == key, _project_key_order), length(_project_key_order) + 1)

function write_project(dir::String, p::Project)
    d = destructure(p)

    # Remove empty dicts
    isempty(d["deps"])    && delete!(d, "deps")
    isempty(d["compat"])  && delete!(d, "compat")
    isempty(d["extras"])  && delete!(d, "extras")
    isempty(d["targets"]) && delete!(d, "targets")

    # Remove julia
    delete!(d["deps"], "julia")

    str = sprint(io -> TOML.print(io, d, sorted=true, by=key -> (project_key_order(key), key)))
    write(joinpath(dir, p.filename), str)
end

