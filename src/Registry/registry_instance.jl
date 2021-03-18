using Base: UUID, SHA1
using TOML
using ..Versions: VersionSpec, VersionRange
using ..LazilyInitializedFields

# The content of a registry is assumed to be constant during the
# lifetime of a `Registry`. Create a new `Registry` if you want to have
# a new view on the current registry.

# See loading.jl
const TOML_CACHE = Base.TOMLCache(TOML.Parser(), Dict{String, Dict{String, Any}}())
const TOML_LOCK = ReentrantLock()
parsefile(toml_file::AbstractString) = Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK)

# Info about each version of a package
@lazy mutable struct VersionInfo
    git_tree_sha1::Base.SHA1
    yanked::Bool
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
    for v in vsorted
        uncompressed[v] = Dict{String, T}()
    end
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
            uv = uncompressed[v]
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
function initialize_uncompressed!(pkg::PkgInfo, versions = keys(pkg.version_info))
    # Only valid to call this with existing versions of the package
    # Remove all versions we have already uncompressed
    versions = filter!(v -> !isinit(pkg.version_info[v], :uncompressed_compat), collect(versions))

    sort!(versions)

    uncompressed_compat = uncompress(pkg.compat, versions)
    uncompressed_deps   = uncompress(pkg.deps,   versions)

    for v in versions
        vinfo = pkg.version_info[v]
        compat = Dict{UUID, VersionSpec}()
        uncompressed_deps_v = uncompressed_deps[v]
        # Everything depends on Julia
        uncompressed_deps_v["julia"] = JULIA_UUID
        uncompressed_compat_v = uncompressed_compat[v]
        for (pkg, uuid) in uncompressed_deps_v
            vspec = get(uncompressed_compat_v, pkg, nothing)
            compat[uuid] = vspec === nothing ? VersionSpec() : vspec
        end
        @init! vinfo.uncompressed_compat = compat
    end
    return pkg
end

function compat_info(pkg::PkgInfo)
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


struct RegistryInstance
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

const REGISTRY_CACHE = Dict{UUID, Tuple{Base.SHA1, RegistryInstance}}()

function get_cached_registry(uuid::UUID, tree_info::Base.SHA1)
    v = get(REGISTRY_CACHE, uuid, nothing)
    if v !== nothing
        cached_tree_info, reg = v
        if cached_tree_info == tree_info
            return reg
        end
    end
    # Prevent hogging up memory indefinitely
    length(REGISTRY_CACHE) > 20 && empty!(REGISTRY_CACHE)
    return nothing
end
    

function RegistryInstance(path::AbstractString)
    d = parsefile(joinpath(path, "Registry.toml"))
    tree_info_file = joinpath(path, ".tree_info.toml")
    tree_info = if isfile(tree_info_file)
        Base.SHA1(parsefile(tree_info_file)["git-tree-sha1"]::String)
    else
        nothing
    end
    reg_uuid = UUID(d["uuid"]::String)
    
    # Reuse an existing cached registry if it exists for this content
    if tree_info !== nothing
        reg = get_cached_registry(reg_uuid, tree_info)
        if reg isa RegistryInstance
            return reg
        end
    end
    pkgs = Dict{UUID, PkgEntry}()
    for (uuid, info) in d["packages"]::Dict{String, Any}
        uuid = UUID(uuid::String)
        info::Dict{String, Any}
        name = info["name"]::String
        pkgpath = info["path"]::String
        pkg = PkgEntry(pkgpath, path, name, uuid, uninit)
        pkgs[uuid] = pkg
    end
    reg = RegistryInstance(
        path,
        d["name"]::String,
        reg_uuid,
        get(d, "url", nothing)::Union{String, Nothing},
        get(d, "repo", nothing)::Union{String, Nothing},
        get(d, "description", nothing)::Union{String, Nothing},
        pkgs,
        tree_info,
        Dict{String, UUID}(),
    )
    if tree_info !== nothing
        REGISTRY_CACHE[reg_uuid] = (tree_info, reg)
    end
    return reg
end

function Base.show(io::IO, ::MIME"text/plain", r::RegistryInstance)
    println(io, "Registry: $(repr(r.name)) at $(repr(r.path)):")
    println(io, "  uuid: ", r.uuid)
    println(io, "  repo: ", r.repo)
    if r.tree_info !== nothing
        println(io, "  git-tree-sha1: ", r.tree_info)
    end
    println(io, "  packages: ", length(r.pkgs))
end

function uuids_from_name(r::RegistryInstance, name::String)
    create_name_uuid_mapping!(r)
    return get(Vector{UUID}, r.name_to_uuids, name)
end

function create_name_uuid_mapping!(r::RegistryInstance)
    isempty(r.name_to_uuids) || return
    for (uuid, pkg) in r.pkgs
        uuids = get!(Vector{UUID}, r.name_to_uuids, pkg.name)
        push!(uuids, pkg.uuid)
    end
    return
end

function reachable_registries(; depots::Union{String, Vector{String}}=Base.DEPOT_PATH)
    # collect registries
    if depots isa String
        depots = [depots]
    end
    registries = RegistryInstance[]
    for d in depots
        isdir(d) || continue
        reg_dir = joinpath(d, "registries")
        isdir(reg_dir) || continue
        for name in readdir(reg_dir)
            file = joinpath(reg_dir, name, "Registry.toml")
            isfile(file) || continue
            push!(registries, RegistryInstance(joinpath(reg_dir, name)))
        end
    end
    return registries
end

# Dict interface

function Base.haskey(r::RegistryInstance, uuid::UUID)
    return haskey(r.pkgs, uuid)
end

function Base.keys(r::RegistryInstance)
    return keys(r.pkgs)
end

Base.getindex(r::RegistryInstance, uuid::UUID) = r.pkgs[uuid]

Base.get(r::RegistryInstance, uuid::UUID, default) = get(r.pkgs, uuid, default)

Base.iterate(r::RegistryInstance) = iterate(r.pkgs)
Base.iterate(r::RegistryInstance, state) = iterate(r.pkgs, state)
