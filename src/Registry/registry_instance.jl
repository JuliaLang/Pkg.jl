using Base: UUID, SHA1
using TOML
using Tar
using ..Versions: VersionSpec, VersionRange
using ..LazilyInitializedFields

# The content of a registry is assumed to be constant during the
# lifetime of a `Registry`. Create a new `Registry` if you want to have
# a new view on the current registry.

function to_tar_path_format(file::AbstractString)
    @static if Sys.iswindows()
        file = replace(file, "\\" => "/")
    end
    return file
end

# See loading.jl
const TOML_CACHE = Base.TOMLCache(TOML.Parser(), Dict{String, Dict{String, Any}}())
const TOML_LOCK = ReentrantLock()
_parsefile(toml_file::AbstractString) = Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK)
function parsefile(in_memory_registry::Union{Dict, Nothing}, folder::AbstractString, file::AbstractString)
    if in_memory_registry === nothing
        return _parsefile(joinpath(folder, file))
    else
        content = in_memory_registry[to_tar_path_format(file)]
        return TOML.Internals.parse(TOML.Parser(content; filepath=file))
    end
end

custom_isfile(in_memory_registry::Union{Dict, Nothing}, folder::AbstractString, file::AbstractString) =
    in_memory_registry === nothing ? isfile(joinpath(folder, file)) : haskey(in_memory_registry, to_tar_path_format(file))

# Info about each version of a package
@lazy mutable struct VersionInfo
    git_tree_sha1::Base.SHA1
    yanked::Bool
    @lazy uncompressed_compat::Union{Dict{UUID, VersionSpec}}
    @lazy weak_uncompressed_compat::Union{Dict{UUID, VersionSpec}}
end
VersionInfo(git_tree_sha1::Base.SHA1, yanked::Bool) = VersionInfo(git_tree_sha1, yanked, uninit, uninit)

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

    # WeakCompat.toml
    weak_compat::Dict{VersionRange, Dict{String, VersionSpec}}

    # WeakDeps.toml
    weak_deps::Dict{VersionRange, Dict{String, UUID}}
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
                    error("Overlapping ranges for $(key) for version $v in registry.")
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

    uncompressed_compat      = uncompress(pkg.compat,      versions)
    uncompressed_deps        = uncompress(pkg.deps,        versions)

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

function initialize_weak_uncompressed!(pkg::PkgInfo, versions = keys(pkg.version_info))
    # Only valid to call this with existing versions of the package
    # Remove all versions we have already uncompressed
    versions = filter!(v -> !isinit(pkg.version_info[v], :weak_uncompressed_compat), collect(versions))

    sort!(versions)

    weak_uncompressed_compat = uncompress(pkg.weak_compat, versions)
    weak_uncompressed_deps   = uncompress(pkg.weak_deps,   versions)

    for v in versions
        vinfo = pkg.version_info[v]
        weak_compat = Dict{UUID, VersionSpec}()
        weak_uncompressed_deps_v = weak_uncompressed_deps[v]
        weak_uncompressed_compat_v = weak_uncompressed_compat[v]
        for (pkg, uuid) in weak_uncompressed_deps_v
            vspec = get(weak_uncompressed_compat_v, pkg, nothing)
            weak_compat[uuid] = vspec === nothing ? VersionSpec() : vspec
        end
        @init! vinfo.weak_uncompressed_compat = weak_compat
    end
    return pkg
end

function compat_info(pkg::PkgInfo)
    initialize_uncompressed!(pkg)
    return Dict(v => info.uncompressed_compat for (v, info) in pkg.version_info)
end

function weak_compat_info(pkg::PkgInfo)
    if isempty(pkg.weak_deps)
        return nothing
    end
    initialize_weak_uncompressed!(pkg)
    return Dict(v => info.weak_uncompressed_compat for (v, info) in pkg.version_info)
end

@lazy struct PkgEntry
    # Registry.toml:
    path::String
    registry_path::String
    name::String
    uuid::UUID

    in_memory_registry::Union{Dict{String, String}, Nothing}
    # Version.toml / (Compat.toml / Deps.toml):
    @lazy info::PkgInfo
end

registry_info(pkg::PkgEntry) = init_package_info!(pkg)

function init_package_info!(pkg::PkgEntry)
    # Already uncompressed the info for this package, return early
    @isinit(pkg.info) && return pkg.info
    path = pkg.registry_path

    d_p = parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Package.toml"))
    name = d_p["name"]::String
    name != pkg.name && error("inconsistent name in Registry.toml ($(name)) and Package.toml ($(pkg.name)) for pkg at $(path)")
    repo = get(d_p, "repo", nothing)::Union{Nothing, String}
    subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}

    # Versions.toml
    d_v = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) : Dict{String, Any}()
    version_info = Dict{VersionNumber, VersionInfo}(VersionNumber(k) =>
        VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool) for (k, v) in d_v)

    # Compat.toml
    compat_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Compat.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Compat.toml")) : Dict{String, Any}()
    compat = Dict{VersionRange, Dict{String, VersionSpec}}()
    for (v, data) in compat_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, VersionSpec}(dep => VersionSpec(vr_dep) for (dep, vr_dep::Union{String, Vector{String}}) in data)
        compat[vr] = d
    end

    # Deps.toml
    deps_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Deps.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Deps.toml")) : Dict{String, Any}()
    deps = Dict{VersionRange, Dict{String, UUID}}()
    for (v, data) in deps_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, UUID}(dep => UUID(uuid) for (dep, uuid::String) in data)
        deps[vr] = d
    end
    # All packages depend on julia
    deps[VersionRange()] = Dict("julia" => JULIA_UUID)

    # WeakCompat.toml
    weak_compat_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakCompat.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakCompat.toml")) : Dict{String, Any}()
    weak_compat = Dict{VersionRange, Dict{String, VersionSpec}}()
    for (v, data) in weak_compat_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, VersionSpec}(dep => VersionSpec(vr_dep) for (dep, vr_dep::Union{String, Vector{String}}) in data)
        weak_compat[vr] = d
    end

    # WeakDeps.toml
    weak_deps_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakDeps.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakDeps.toml")) : Dict{String, Any}()
    weak_deps = Dict{VersionRange, Dict{String, UUID}}()
    for (v, data) in weak_deps_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, UUID}(dep => UUID(uuid) for (dep, uuid::String) in data)
        weak_deps[vr] = d
    end

    @init! pkg.info = PkgInfo(repo, subdir, version_info, compat, deps, weak_compat, weak_deps)

    return pkg.info
end


function uncompress_registry(tar_gz::AbstractString)
    if !isfile(tar_gz)
        error("$(repr(tar_gz)): No such file")
    end
    data = Dict{String, String}()
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    io = IOBuffer()
    open(`$(exe7z()) x $tar_gz -so`) do tar
        Tar.read_tarball(x->true, tar; buf=buf) do hdr, _
            if hdr.type == :file
                Tar.read_data(tar, io; size=hdr.size, buf=buf)
                data[hdr.path] = String(take!(io))
            end
        end
    end
    return data
end

struct RegistryInstance
    path::String
    name::String
    uuid::UUID
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    pkgs::Dict{UUID, PkgEntry}
    tree_info::Union{Base.SHA1, Nothing}
    in_memory_registry::Union{Nothing, Dict{String, String}}
    # various caches
    name_to_uuids::Dict{String, Vector{UUID}}
end

const REGISTRY_CACHE = Dict{String, Tuple{Base.SHA1, Bool, RegistryInstance}}()

function get_cached_registry(path, tree_info::Base.SHA1, compressed::Bool)
    if !ispath(path)
        delete!(REGISTRY_CACHE, path)
        return nothing
    end
    v = get(REGISTRY_CACHE, path, nothing)
    if v !== nothing
        cached_tree_info, cached_compressed, reg = v
        if cached_tree_info == tree_info && cached_compressed == compressed
            return reg
        end
    end
    # Prevent hogging up memory indefinitely
    length(REGISTRY_CACHE) > 20 && empty!(REGISTRY_CACHE)
    return nothing
end

function RegistryInstance(path::AbstractString)
    compressed_file = nothing
    if isfile(path)
        @assert splitext(path)[2] == ".toml"
        d_reg_info = parsefile(nothing, dirname(path), basename(path))
        compressed_file = d_reg_info["path"]::String
        tree_info = Base.SHA1(d_reg_info["git-tree-sha1"]::String)
    else
        tree_info_file = joinpath(path, ".tree_info.toml")
        tree_info = if isfile(tree_info_file)
            Base.SHA1(parsefile(nothing, path, ".tree_info.toml")["git-tree-sha1"]::String)
        else
            nothing
        end
    end
    # Reuse an existing cached registry if it exists for this content
    if tree_info !== nothing
        reg = get_cached_registry(path, tree_info, compressed_file !== nothing)
        if reg isa RegistryInstance
            return reg
        end
    end

    in_memory_registry = if compressed_file !== nothing
        uncompress_registry(joinpath(dirname(path), compressed_file))
    else
        nothing
    end

    d = parsefile(in_memory_registry, path, "Registry.toml")
    pkgs = Dict{UUID, PkgEntry}()
    for (uuid, info) in d["packages"]::Dict{String, Any}
        uuid = UUID(uuid::String)
        info::Dict{String, Any}
        name = info["name"]::String
        pkgpath = info["path"]::String
        pkg = PkgEntry(pkgpath, path, name, uuid, in_memory_registry, uninit)
        pkgs[uuid] = pkg
    end
    reg = RegistryInstance(
        path,
        d["name"]::String,
        UUID(d["uuid"]::String),
        get(d, "repo", nothing)::Union{String, Nothing},
        get(d, "description", nothing)::Union{String, Nothing},
        pkgs,
        tree_info,
        in_memory_registry,
        Dict{String, UUID}(),
    )
    if tree_info !== nothing
        REGISTRY_CACHE[path] = (tree_info, compressed_file !== nothing, reg)
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

function verify_compressed_registry_toml(path::String)
    d = TOML.tryparsefile(path)
    if d isa TOML.ParserError
        @warn "Failed to parse registry TOML file at $(repr(path))" exception=d
        return false
    end
    for key in ("git-tree-sha1", "uuid", "path")
        if !haskey(d, key)
            @warn "Expected key $(repr(key)) to exist in registry TOML file at $(repr(path))"
            return false
        end
    end
    compressed_file = joinpath(dirname(path), d["path"]::String)
    if !isfile(compressed_file)
        @warn "Expected the compressed registry for $(repr(path)) to exist at $(repr(compressed_file))"
        return false
    end
    return true
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
        reg_paths = readdir(reg_dir; join=true)
        candidate_registries = String[]
        # All folders could be registries
        append!(candidate_registries, filter(isdir, reg_paths))
        if registry_read_from_tarball()
            compressed_registries = filter(endswith(".toml"), reg_paths)
            # if we are reading compressed registries, ignore compressed registries
            # with the same name
            compressed_registry_names = Set([splitext(basename(file))[1] for file in compressed_registries])
            filter!(x -> !(basename(x) in compressed_registry_names), candidate_registries)
            for compressed_registry in compressed_registries
                if verify_compressed_registry_toml(compressed_registry)
                    push!(candidate_registries, compressed_registry)
                end
            end
        end

        for candidate in candidate_registries
            # candidate can be either a folder or a TOML file
            if isfile(joinpath(candidate, "Registry.toml")) || isfile(candidate)
                push!(registries, RegistryInstance(candidate))
            end
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
