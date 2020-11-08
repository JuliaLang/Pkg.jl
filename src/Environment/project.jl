const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")

struct Package
    name::String
    uuid::UUID
    version::Union{Nothing, VersionNumber} # stdlibs don't have a version
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

@enum ProjectParseExceptionTypes begin
    InsufficientPackageKeys
    UnexpectedType
    UUIDParseError
    VersionParseError
    CompatParseError
end

mutable struct ProjectParseException <: Exception
    typ::ProjectParseExceptionTypes
    data::Any
    path::Union{String, Nothing} # make @lazy
end
ProjectParseException(typ::ProjectParseExceptionTypes, data=nothing) = 
    ProjectParseException(typ, data, nothing)

function Base.showerror(io::IO, exc::ProjectParseException)
    print(io, "invalid project file: ", repr(exc.path), ": ")
    if exc.typ == InsufficientPackageKeys
        print(io, "expected keys `name`, `uuid` to exist if one of them exist")
    elseif exc.typ == UnexpectedType
        key, T = exc.data::Tuple{String, DataType}
        print(io, "expected value of key `", key, "` to be of type `", T, "`")
    elseif exc.typ in (UUIDParseError, VersionParseError)
        s = exc.typ = UUIDParseError ? "UUID" :
            exc.typ = VersionNumber  ? "VersionNumber" : error()
        print(io, "failed to parse: ", repr(exc.data::String), "as a ", s)
    elseif exc.typ == CompatParseError
        s, msg = exc.data::Tuple{String, String}
        print(io, "failed to parse: ", repr(s), " as a compat entry: ", msg)
    end
end

@eval macro $(Symbol("try"))(expr)
    return quote
        v = $(esc(expr))
        # v isa ProjectParseException && throw(v)
        v isa ProjectParseException && return v
        v
    end
end

function parse_uuid(uuid)
    uuid isa String || return ProjectParseException(UnexpectedType, ("uuid",    String))
    uuid′ = tryparse(UUID, uuid)
    uuid′ === nothing && return ProjectParseException(UUIDParseError, uuid)
    return uuid′
end

function parse_version(version)
    version === nothing && return version
    version isa String || return ProjectParseException(UnexpectedType, ("version", String))
    version′ = tryparse(VersionNumber, version)
    version′ === nothing && return ProjectParseException(VersionParseError, version)
    return version′
end

function parse_package_part!(d::Dict{String, Any})::Union{Package, Nothing, ProjectParseException}
    name        = pop!(d, "name",    nothing)
    version_str = pop!(d, "version", nothing)
    uuid_str    = pop!(d, "uuid",    nothing)

    if name === nothing && uuid_str === nothing
        return nothing
    elseif !(name !== nothing && uuid_str !== nothing)
        return ProjectParseException(InsufficientPackageKeys)
    end

    # Check fields are expected types
    name        isa String || return ProjectParseException(UnexpectedType, ("name",    String))

    # Check relevant fields are parsable
    version = @try parse_version(version_str)

    uuid = @try parse_uuid(uuid_str)

    return Package(name, uuid, version)
end

function parse_compat_part!(d::Dict{String, Any})::Union{Dict{String, Pair{String, VersionSpec}}, ProjectParseException}
    compats_toml = pop!(d, "compat", nothing)
    compats = Dict{String, Pair{String, VersionSpec}}()
    compats_toml === nothing && return compats
    compats_toml isa Dict{String, Any} || return ProjectParseException(UnexpectedType, ("compat", Dict{String, Any}))

    for (name, compat_toml) in compats_toml
        compat_toml isa String || return ProjectParseException(UnexpectedType, (name, String))
        function parse_version(compat_toml::String)
            # Ugly
            try
                return semver_spec(compat_toml)
            catch e
                if e isa ErrorException
                    return ProjectParseException(CompatParseError, (compat_toml, e.msg))
                else
                    rehtrow(e)
                end
            end
        end
        compat = @try parse_version(compat_toml)

        compats[name] = compat_toml => compat
    end
    return compats
end


function Project(project_path::String)
    isfile(project_path) || error("no such file: ", repr(project_path))
    project_path = realpath(project_path)
    p = tryparsefile(project_path)
    if p isa ProjectParseException
        p.path = project_path
        throw(p)
    end
    return p
end

function tryparsefile(project_path::String)::Union{Project, ProjectParseException}

    d = isfile(project_path) ? TOML.parsefile(project_path) : Dict{String, Any}()

    # Package
    pkg = @try parse_package_part!(d)

    # Compat

    name_to_uuid = Dict{String, UUID}()

    compats_toml = @try parse_compat_part!(d)

    function compat_data(name)
        compat_toml = get(compats_toml, name, nothing)
        if compat_toml !== nothing
            return compat_toml
        end
        return "" => default_compat()
    end

    function extract_deps(key)
        deps_toml = pop!(d, key, nothing)
        deps = Dict{UUID, Dependency}()
        if deps_toml === nothing
            return deps
        end
        deps_toml isa Dict{String, Any} || return ProjectParseException(UnexpectedType, ("deps", Dict{String, Any}))
        deps_toml == nothing && return
        for (name, uuid_str) in deps_toml
            uuid = @try parse_uuid(uuid_str)
            name_to_uuid[name] = uuid
            compat_str, compat = compat_data(name)
            deps[uuid] = Dependency(
                name,
                uuid,
                compat,
                compat_str
            )
        end
        return deps
    end

    julia_compat_str, julia_compat = @try compat_data("julia")
    mdeps = @try extract_deps("deps")

    mdeps[JULIA_UUID] = Dependency(
        "julia",
        JULIA_UUID,
        julia_compat,
        julia_compat_str,
    )
    extras = extract_deps("extras")

    # Verify
    # TODO:
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

