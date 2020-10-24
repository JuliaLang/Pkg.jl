module RegistryHandling

export isyanked, treehash, uncompressed_data, registry_info

using Base: UUID, SHA1, RefValue
using TOML
using Pkg.Versions: VersionSpec, VersionRange
using Pkg.LazilyInitializedFields

# The content of a registry is assumed to be constant during the
# lifetime of a `Registry`. Create a new `Registry` if you want to have
# a new view on the current registry.

# See loading.jl
const TOML_CACHE = Base.TOMLCache(TOML.Parser(), Dict{String, Dict{String, Any}}())
const TOML_LOCK = ReentrantLock()
parsefile(project_file::AbstractString) = Base.parsed_toml(project_file, TOML_CACHE, TOML_LOCK)

# Info about each version of a package
@lazy mutable struct VersionInfo
    git_tree_sha1::Base.SHA1
    yanked::Bool

    # This is the uncompressed info and is lazily computed because it is kinda expensive
    # TODO: Collapse the two dictionaries below into a single dictionary,
    # we should only need to know the `Dict{UUID, VersionSpec}` mapping
    # (therebe getting rid of the package names).
    @lazy uncompressed_compat::Union{Dict{UUID, VersionSpec}}
end
VersionInfo(git_tree_sha1::Base.SHA1, yanked::Bool) = VersionInfo(git_tree_sha1, yanked, uninit)

# This is the information that exists in e.g. General/A/ACME
struct PkgInfo
    # Package.toml:
    repo::Union{String, Nothing}
    subdir::Union{String, Nothing}

    # Versions.toml:
    version_info::Dict{VersionNumber, VersionInfo}

    # Compat.toml
    compat::Dict{VersionRange, Dict{String, VersionSpec}}

    # Deps.toml
    deps::Dict{VersionRange, Dict{String, UUID}}
end

isyanked(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].yanked
treehash(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].git_tree_sha1

function uncompress(compressed::Dict{VersionRange, Dict{String, T}}, vsorted::Vector{VersionNumber}) where {T}
    @assert issorted(vsorted)
    uncompressed = Dict{VersionNumber, Dict{String, T}}()
    for (vs, data) in compressed
        first = length(vsorted) + 1
        # We find the first and last version that are in the range
        # and since the versions are sorted, all versions in between are sorted
        for i in eachindex(vsorted)
            v = vsorted[i]
            v in vs && (first = i; break)
        end
        last = 0
        for i in reverse(eachindex(vsorted))
            v = vsorted[i]
            v in vs && (last = i; break)
        end
        for i in first:last
            v = vsorted[i]
            uv = get!(Dict{String, T}, uncompressed, v)
            for (key, value) in data
                if haskey(uv, key)
                    # Change to an error?
                    error("Overlapping ranges for $(key) in $(repr(path)) for version $v.")
                else
                    uv[key] = value
                end
            end
        end
    end
    return uncompressed
end

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
# Call this before accessing uncompressed data
function initialize_uncompressed!(pkg::PkgInfo, versions = keys(pkg.version_info))

    # Only valid to call this with existing versions of the package
    # Remove all versions we have already uncompressed
    versions = filter!(v -> !isinit(pkg.version_info[v], :uncompressed_compat), collect(versions))

    sort!(versions)

    uncompressed_compat = uncompress(pkg.compat, versions)
    uncompressed_deps   = uncompress(pkg.deps,   versions)

    for v in versions
        vinfo = pkg.version_info[v]
        d = Dict{UUID, VersionSpec}()
        uncompressed_deps_v = get(uncompressed_deps, v, nothing)
        if uncompressed_deps_v !== nothing
            uncompressed_compat_v = get(uncompressed_compat, v, nothing)
            if uncompressed_compat_v !== nothing
                for (name, compat) in uncompressed_compat_v
                    uuid = name == "julia" ? JULIA_UUID : uncompressed_deps_v[name]
                    d[uuid] = compat
                end
            end
        end
        @init! vinfo.uncompressed_compat = d
    end
    return pkg
end

function uncompressed_data(pkg::PkgInfo)
    initialize_uncompressed!(pkg)
    return Dict(v => info.uncompressed_compat for (v, info) in pkg.version_info)
end

@lazy struct PkgEntry
    # Registry.toml:
    path::String
    registry_path::String
    name::String
    uuid::UUID

    # Version.toml / (Compat.toml / Deps.toml):
    @lazy info::PkgInfo
end

registry_info(pkg::PkgEntry) = init_package_info!(pkg)

function init_package_info!(pkg::PkgEntry)
    # Already uncompressed the info for this package, return early
    @isinit(pkg.info) && return pkg.info
    path = joinpath(pkg.registry_path, pkg.path)

    path_package = joinpath(path, "Package.toml")
    d_p = parsefile(path_package)
    name = d_p["name"]::String
    name != pkg.name && error("inconsistend name in Registry.toml and Package.toml for pkg at $(path)")
    repo = get(d_p, "repo", nothing)::Union{Nothing, String}
    subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}

    # Versions.toml
    path_vers = joinpath(path, "Versions.toml")
    d_v = isfile(path_vers) ? parsefile(path_vers) : Dict{String, Any}()
    version_info = Dict{VersionNumber, VersionInfo}(VersionNumber(k) =>
        VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool) for (k, v) in d_v)

    # Compat.toml
    compat_file = joinpath(path, "Compat.toml")
    compat_data_toml = isfile(compat_file) ? parsefile(compat_file) : Dict{String, Any}()
    # The Compat.toml file might have string or vector values
    compat_data_toml = convert(Dict{String, Dict{String, Union{String, Vector{String}}}}, compat_data_toml)
    compat = Dict{VersionRange, Dict{String, VersionSpec}}()
    for (v, data) in compat_data_toml
        vr = VersionRange(v)
        d = Dict{String, VersionSpec}(dep => VersionSpec(vr_dep) for (dep, vr_dep) in data)
        compat[vr] = d
    end

    # Deps.toml
    deps_file = joinpath(path, "Deps.toml")
    deps_data_toml = isfile(deps_file) ? parsefile(deps_file) : Dict{String, Any}()
    # But the Deps.toml only have strings as values
    deps_data_toml = convert(Dict{String, Dict{String, String}}, deps_data_toml)
    deps = Dict{VersionRange, Dict{String, UUID}}()
    for (v, data) in deps_data_toml
        vr = VersionRange(v)
        d = Dict{String, UUID}(dep => UUID(uuid) for (dep, uuid) in data)
        deps[vr] = d
    end
    # All packages depend on julia
    deps[VersionRange()] = Dict("julia" => JULIA_UUID)

    @init! pkg.info = PkgInfo(repo, subdir, version_info, compat, deps)

    return pkg.info
end


struct Registry
    path::String
    name::String
    uuid::UUID
    url::Union{String, Nothing}
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    pkgs::Dict{UUID, PkgEntry}
    tree_info::Union{Base.SHA1, Nothing}
    # various caches
    name_to_uuids::Dict{String, Vector{UUID}}
end

function Registry(path::AbstractString)
    d = parsefile(joinpath(path, "Registry.toml"))
    pkgs = Dict{UUID, PkgEntry}()
    for (uuid, info) in d["packages"]::Dict{String, Any}
        uuid = UUID(uuid::String)
        info::Dict{String, Any}
        name = info["name"]::String
        pkgpath = info["path"]::String
        pkg = PkgEntry(pkgpath, path, name, uuid, uninit)
        pkgs[uuid] = pkg
    end
    tree_info_file = joinpath(path, ".tree_info.toml")
    tree_info = if isfile(tree_info_file)
        Base.SHA1(parsefile(tree_info_file)["git-tree-sha1"]::String)
    else
        nothing
    end
    return Registry(
        path,
        d["name"]::String,
        UUID(d["uuid"]::String),
        get(d, "url", nothing)::Union{String, Nothing},
        get(d, "repo", nothing)::Union{String, Nothing},
        get(d, "description", nothing)::Union{String, Nothing},
        pkgs,
        tree_info,
        Dict{String, UUID}(),
    )
end

function Base.show(io::IO, ::MIME"text/plain", r::Registry)
    println(io, "Registry: $(repr(r.name)) at $(repr(r.path)):")
    println(io, "  uuid: ", r.uuid)
    println(io, "  repo: ", r.repo)
    if r.tree_info !== nothing
        println(io, "  git-tree-sha1: ", r.tree_info)
    end
    println(io, "  packages: ", length(r.pkgs))
end

function uuids_from_name(r::Registry, name::String)
    create_name_uuid_mapping!(r)
    return get(Vector{UUID}, r.name_to_uuids, name)
end

function create_name_uuid_mapping!(r::Registry)
    isempty(r.name_to_uuids) || return
    for (uuid, pkg) in r.pkgs
        uuids = get!(Vector{UUID}, r.name_to_uuids, pkg.name)
        push!(uuids, pkg.uuid)
    end
    return
end

# Dict interface

function Base.haskey(r::Registry, uuid::UUID)
    return haskey(r.pkgs, uuid)
end

function Base.keys(r::Registry)
    return keys(r.pkgs)
end

Base.getindex(r::Registry, uuid::UUID) = r.pkgs[uuid]

Base.get(r::Registry, uuid::UUID, default) = get(r.pkgs, uuid, default)

Base.iterate(r::Registry) = iterate(r.pkgs)
Base.iterate(r::Registry, state) = iterate(r.pkgs, state)

end # module

