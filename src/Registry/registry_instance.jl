using Base: UUID, SHA1
using TOML
using Dates
using Tar
using ..Versions: VersionSpec, VersionRange

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
const TOML_CACHE = Base.TOMLCache(Base.TOML.Parser{Dates}())
const TOML_LOCK = ReentrantLock()
_parsefile(toml_file::AbstractString) = Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK)
function parsefile(in_memory_registry::Union{Dict, Nothing}, folder::AbstractString, file::AbstractString)
    if in_memory_registry === nothing
        return _parsefile(joinpath(folder, file))
    else
        content = in_memory_registry[to_tar_path_format(file)]
        parser = Base.TOML.Parser{Dates}(content; filepath = file)
        return Base.TOML.parse(parser)
    end
end

custom_isfile(in_memory_registry::Union{Dict, Nothing}, folder::AbstractString, file::AbstractString) =
    in_memory_registry === nothing ? isfile(joinpath(folder, file)) : haskey(in_memory_registry, to_tar_path_format(file))

# Info about each version of a package
mutable struct VersionInfo
    const git_tree_sha1::Base.SHA1
    const yanked::Bool
end

# This is the information that exists in e.g. General/A/ACME
struct PkgInfo
    # Package.toml:
    repo::Union{String, Nothing}
    subdir::Union{String, Nothing}

    # Package.toml [metadata.deprecated]:
    deprecated::Union{Dict{String, Any}, Nothing}

    # Versions.toml:
    version_info::Dict{VersionNumber, VersionInfo}

    # Deps.toml - which dependencies exist
    deps::Dict{VersionRange, Set{UUID}}

    # Compat.toml - version constraints on deps
    compat::Dict{VersionRange, Dict{UUID, VersionSpec}}

    # WeakDeps.toml - which weak dependencies exist
    weak_deps::Dict{VersionRange, Set{UUID}}

    # WeakCompat.toml - version constraints on weak deps
    weak_compat::Dict{VersionRange, Dict{UUID, VersionSpec}}
end

isyanked(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].yanked
treehash(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].git_tree_sha1
isdeprecated(pkg::PkgInfo) = pkg.deprecated !== nothing

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")


mutable struct PkgEntry
    # Registry.toml:
    const path::String
    const registry_path::String
    const name::String
    const uuid::UUID

    # Version.toml / (Compat.toml / Deps.toml):
    info::PkgInfo # lazily initialized

    PkgEntry(path, registry_path, name, uuid) = new(path, registry_path, name, uuid #= undef =#)
end

# Helper to load deps data from Deps.toml or WeakDeps.toml
# Returns Dict{VersionRange, Set{UUID}} - just lists which deps exist
function load_deps_data(in_memory_registry, registry_path, pkg_path, filename, name_to_uuid)
    deps_data_toml = custom_isfile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) ?
        parsefile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) : Dict{String, Any}()
    deps = Dict{VersionRange, Set{UUID}}()
    for (v, data) in deps_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Set{UUID}()
        for (dep, uuid_str) in data
            uuid_val = UUID(uuid_str::String)
            push!(d, uuid_val)
            name_to_uuid[dep] = uuid_val
        end
        deps[vr] = d
    end
    return deps
end

# Helper to load compat data from Compat.toml or WeakCompat.toml
function load_compat_data(in_memory_registry, registry_path, pkg_path, filename, name_to_uuid)
    compat_data_toml = custom_isfile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) ?
        parsefile(in_memory_registry, registry_path, joinpath(pkg_path, filename)) : Dict{String, Any}()
    compat = Dict{VersionRange, Dict{UUID, VersionSpec}}()
    for (v, data) in compat_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{UUID, VersionSpec}()
        for (dep, vr_dep::Union{String, Vector{String}}) in data
            d[name_to_uuid[dep]] = VersionSpec(vr_dep)
        end
        compat[vr] = d
    end
    return compat
end

# Helper function to query just the dependencies (without compat specs) for a version
# Returns Set{UUID} of all dependencies (both strong and weak) for the given version
function query_deps_for_version(
        deps_compressed::Dict{VersionRange, Set{UUID}},
        weak_deps_compressed::Dict{VersionRange, Set{UUID}},
        version::VersionNumber
    )::Set{UUID}
    result = Set{UUID}()
    for compressed in (deps_compressed, weak_deps_compressed)
        for (vrange, deps_set) in compressed
            if version in vrange
                union!(result, deps_set)
            end
        end
    end
    return result
end

# Helper function to query deps for a specific version from multi-registry maps
function query_deps_for_version(
        deps_map::Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}},
        weak_deps_map::Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}},
        uuid::UUID,
        version::VersionNumber
    )::Set{UUID}
    result = Set{UUID}()
    deps_list = get(Vector{Dict{VersionRange, Set{UUID}}}, deps_map, uuid)
    weak_deps_list = get(Vector{Dict{VersionRange, Set{UUID}}}, weak_deps_map, uuid)

    # Query each registry's data
    for i in eachindex(deps_list)
        deps_compressed = deps_list[i]
        weak_deps_compressed = weak_deps_list[i]
        union!(result, query_deps_for_version(deps_compressed, weak_deps_compressed, version))
    end

    return result
end

# Helper function to query compressed compat data from PkgInfo
# Convenience wrapper that uses PkgInfo's compressed data directly
# Returns Dict{UUID, VersionSpec} if target_uuid is nothing
# Returns Union{VersionSpec, Nothing} if target_uuid is provided
function query_compat_for_version(
        pkg_info::PkgInfo,
        version::VersionNumber,
        target_uuid::Union{UUID, Nothing} = nothing
    )
    return query_compat_for_version(pkg_info.deps, pkg_info.compat, pkg_info.weak_deps, pkg_info.weak_compat, version, target_uuid)
end

# Mutating helper function to query compressed compat data for a specific version
# Merges deps (which dependencies exist) with compat (version constraints on those deps)
# Dependencies without explicit compat entries get VersionSpec() (any version)
# Includes both strong and weak dependencies
# If target_uuid is provided, only includes that UUID if it exists
# The result dictionary is emptied before populating
function query_compat_for_version!(
        result::Dict{UUID, VersionSpec},
        deps_compressed::Dict{VersionRange, Set{UUID}},
        compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        weak_deps_compressed::Dict{VersionRange, Set{UUID}},
        weak_compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        version::VersionNumber,
        target_uuid::Union{UUID, Nothing} = nothing
    )
    empty!(result)

    for deps_dict in (deps_compressed, weak_deps_compressed)
        for (vrange, deps_set) in deps_dict
            if version in vrange
                for dep_uuid in deps_set
                    if target_uuid === nothing || dep_uuid == target_uuid
                        result[dep_uuid] = VersionSpec()  # Default: any version
                    end
                end
            end
        end
    end

    # Override with explicit compat specs from regular and weak compat
    for compat_dict in (compat_compressed, weak_compat_compressed)
        for (vrange, compat_entries) in compat_dict
            if version in vrange
                for (dep_uuid, vspec) in compat_entries
                    if target_uuid === nothing || dep_uuid == target_uuid
                        result[dep_uuid] = vspec
                    end
                end
            end
        end
    end

    return nothing
end

# Non-mutating wrapper for backwards compatibility
# If target_uuid is provided, returns VersionSpec or nothing for that specific UUID
# If target_uuid is nothing, returns Dict{UUID, VersionSpec} for all dependencies
function query_compat_for_version(
        deps_compressed::Dict{VersionRange, Set{UUID}},
        compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        weak_deps_compressed::Dict{VersionRange, Set{UUID}},
        weak_compat_compressed::Dict{VersionRange, Dict{UUID, VersionSpec}},
        version::VersionNumber,
        target_uuid::Union{UUID, Nothing} = nothing
    )
    result = Dict{UUID, VersionSpec}()
    query_compat_for_version!(result, deps_compressed, compat_compressed, weak_deps_compressed, weak_compat_compressed, version, target_uuid)

    # If a specific UUID was requested, return just its VersionSpec (or nothing)
    if target_uuid !== nothing
        return get(result, target_uuid, nothing)
    end

    return result
end

# Helper to check if a UUID is in the weak deps for a specific version
function is_weak_dep(
        weak_compressed::Dict{VersionRange, Set{UUID}},
        version::VersionNumber,
        dep_uuid::UUID
    )::Bool
    for (vrange, weak_set) in weak_compressed
        if version in vrange && (dep_uuid in weak_set)
            return true
        end
    end
    return false
end

# Helper function to query compat across multiple registries
# Each registry has its own compressed dictionaries and version set
# Only queries a registry if the version actually exists in that registry
function query_compat_for_version_multi_registry!(
        result::Dict{UUID, VersionSpec},
        reg_result::Dict{UUID, VersionSpec},
        deps_list::Vector{Dict{VersionRange, Set{UUID}}},
        compat_list::Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}},
        weak_deps_list::Vector{Dict{VersionRange, Set{UUID}}},
        weak_compat_list::Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}},
        versions_per_registry::Vector{Set{VersionNumber}},
        version::VersionNumber
    )
    empty!(result)

    # Query each registry's data separately
    for i in eachindex(deps_list)
        # CRITICAL: Only query this registry if the version exists in it!
        if !(version in versions_per_registry[i])
            continue
        end

        reg_deps = deps_list[i]
        reg_compat = compat_list[i]
        reg_weak_deps = weak_deps_list[i]
        reg_weak_compat = weak_compat_list[i]

        # Use the mutating query function to avoid allocation
        query_compat_for_version!(reg_result, reg_deps, reg_compat, reg_weak_deps, reg_weak_compat, version)

        # Merge results, preferring the first registry's compat if there's overlap
        for (uuid, vspec) in reg_result
            if !haskey(result, uuid)
                result[uuid] = vspec
            end
            # If uuid already exists, keep the first registry's vspec (first wins)
        end
    end

    return nothing
end

# Validate that no version ranges overlap for the same dependency
# This enforces the registry invariant that each dependency should be specified
# at most once for any given version
# Works with any collection type (Set, Dict, etc.) and any key type (UUID, String, etc.)
function validate_no_overlapping_ranges(
        compressed::Dict{VersionRange, T},
        versions::Vector{VersionNumber},
        pkg_name::String,
        data_type::String, # "Deps", "WeakDeps", "Compat", or "WeakCompat"
        name_to_uuid::Dict{String, UUID}
    ) where {T}
    # Build inverse mapping for better error messages
    uuid_to_name = Dict{UUID, String}(uuid => name for (name, uuid) in name_to_uuid)

    # For each version, check that no dependency UUID appears in multiple ranges
    for v in versions
        seen_deps = Dict{UUID, VersionRange}()
        for (vrange, dep_collection) in compressed
            if v in vrange
                # Works for both Set{UUID} (iterate directly) and Dict{UUID,...} (iterate keys)
                for dep_uuid in (dep_collection isa AbstractDict ? keys(dep_collection) : dep_collection)
                    if haskey(seen_deps, dep_uuid)
                        dep_name = get(uuid_to_name, dep_uuid, string(dep_uuid))
                        error(
                            "Overlapping ranges for dependency $(dep_name) in $(pkg_name) $(data_type).toml: " *
                                "version $v is covered by both $(seen_deps[dep_uuid]) and $(vrange)"
                        )
                    end
                    seen_deps[dep_uuid] = vrange
                end
            end
        end
    end
    return
end

# Simplified tarball reader without path tracking overhead
function read_tarball_simple(
        callback::Function,
        predicate::Function,
        tar::IO;
        buf::Vector{UInt8} = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE),
    )
    globals = Dict{String, String}()
    while !eof(tar)
        hdr = Tar.read_header(tar, globals = globals, buf = buf)
        hdr === nothing && break
        predicate(hdr)::Bool || continue
        Tar.check_header(hdr)
        before = applicable(position, tar) ? position(tar) : 0
        callback(hdr)
        applicable(position, tar) || continue
        advanced = position(tar) - before
        expected = Tar.round_up(hdr.size)
        advanced == expected ||
            error("callback read $advanced bytes instead of $expected")
    end
    return
end

function uncompress_registry(compressed_tar::AbstractString)
    if !isfile(compressed_tar)
        error("$(repr(compressed_tar)): No such file")
    end
    data = Dict{String, String}()
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    io = IOBuffer()
    open(get_extract_cmd(compressed_tar)) do tar
        read_tarball_simple(x -> true, tar; buf = buf) do hdr
            Tar.read_data(tar, io; size = hdr.size, buf = buf)
            data[hdr.path] = String(take!(io))
        end
    end
    return data
end

mutable struct RegistryInstance
    path::String
    tree_info::Union{Base.SHA1, Nothing}
    compressed_file::Union{String, Nothing}
    const load_lock::ReentrantLock # Lock for thread-safe lazy loading

    # Lazily loaded fields
    name::String
    uuid::UUID
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    pkgs::Dict{UUID, PkgEntry}
    in_memory_registry::Union{Nothing, Dict{String, String}}
    # various caches
    name_to_uuids::Dict{String, Vector{UUID}}

    # Inner constructor for lazy loading - leaves fields undefined
    function RegistryInstance(path::String, tree_info::Union{Base.SHA1, Nothing}, compressed_file::Union{String, Nothing})
        return new(path, tree_info, compressed_file, ReentrantLock())
    end

    # Full constructor for when all fields are known
    function RegistryInstance(
            path::String, tree_info::Union{Base.SHA1, Nothing}, compressed_file::Union{String, Nothing},
            name::String, uuid::UUID, repo::Union{String, Nothing}, description::Union{String, Nothing},
            pkgs::Dict{UUID, PkgEntry}, in_memory_registry::Union{Nothing, Dict{String, String}},
            name_to_uuids::Dict{String, Vector{UUID}}
        )
        return new(path, tree_info, compressed_file, ReentrantLock(), name, uuid, repo, description, pkgs, in_memory_registry, name_to_uuids)
    end
end

const REGISTRY_CACHE = Dict{String, Tuple{Base.SHA1, Bool, RegistryInstance}}()

function init_package_info!(registry::RegistryInstance, pkg::PkgEntry)
    # Thread-safe lazy loading with double-check pattern
    # Use the registry's load_lock to protect lazy loading of package info
    return @lock registry.load_lock begin
        # Double-check: if another thread loaded while we were waiting for the lock
        isdefined(pkg, :info) && return pkg.info

        path = pkg.registry_path
        in_memory_registry = registry.in_memory_registry

        d_p = parsefile(in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Package.toml"))
        name = d_p["name"]::String
        name != pkg.name && error("inconsistent name in Registry.toml ($(name)) and Package.toml ($(pkg.name)) for pkg at $(path)")
        repo = get(d_p, "repo", nothing)::Union{Nothing, String}
        subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}

        # The presence of a [metadata.deprecated] table indicates the package is deprecated
        # We store the raw table to allow other tools to use the metadata
        metadata = get(d_p, "metadata", nothing)::Union{Nothing, Dict{String, Any}}
        deprecated = metadata !== nothing ? get(metadata, "deprecated", nothing)::Union{Nothing, Dict{String, Any}} : nothing

        # Versions.toml
        d_v = custom_isfile(in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) ?
            parsefile(in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) : Dict{String, Any}()
        version_info = Dict{VersionNumber, VersionInfo}(
            VersionNumber(k) =>
                VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool) for (k, v) in d_v
        )

        # Deps.toml (load first to build name -> UUID mapping)
        name_to_uuid = Dict{String, UUID}()
        deps = load_deps_data(in_memory_registry, pkg.registry_path, pkg.path, "Deps.toml", name_to_uuid)
        # All packages depend on julia
        deps[VersionRange()] = Set([JULIA_UUID])
        name_to_uuid["julia"] = JULIA_UUID

        # WeakDeps.toml (load to extend name -> UUID mapping)
        weak_deps = load_deps_data(in_memory_registry, pkg.registry_path, pkg.path, "WeakDeps.toml", name_to_uuid)

        # Compat.toml (convert names to UUIDs using the mapping)
        compat = load_compat_data(in_memory_registry, pkg.registry_path, pkg.path, "Compat.toml", name_to_uuid)

        # WeakCompat.toml (convert names to UUIDs using the mapping)
        weak_compat = load_compat_data(in_memory_registry, pkg.registry_path, pkg.path, "WeakCompat.toml", name_to_uuid)

        #=
        # These validations are a bit too expensive
        # RegistryTools does this already: https://github.com/JuliaRegistries/RegistryTools.jl/blob/b5ff4d541b0aad2261ac21416113cee9718e28b3/src/Compress.jl#L64
        # Validate that no ranges overlap for the same dependency (registry invariant)
        versions_list = sort!(collect(keys(version_info)))
        if !isempty(deps)
            validate_no_overlapping_ranges(deps, versions_list, pkg.name, "Deps", name_to_uuid)
        end
        if !isempty(weak_deps)
            validate_no_overlapping_ranges(weak_deps, versions_list, pkg.name, "WeakDeps", name_to_uuid)
        end
        if !isempty(compat)
            validate_no_overlapping_ranges(compat, versions_list, pkg.name, "Compat", name_to_uuid)
        end
        if !isempty(weak_compat)
            validate_no_overlapping_ranges(weak_compat, versions_list, pkg.name, "WeakCompat", name_to_uuid)
        end
        =#

        @assert !isdefined(pkg, :info)
        pkg.info = PkgInfo(repo, subdir, deprecated, version_info, deps, compat, weak_deps, weak_compat)

        # Free memory: delete the package's files from in_memory_registry since we've fully parsed them
        if in_memory_registry !== nothing
            for filename in ("Package.toml", "Versions.toml", "Deps.toml", "WeakDeps.toml", "Compat.toml", "WeakCompat.toml")
                delete!(in_memory_registry, to_tar_path_format(joinpath(pkg.path, filename)))
            end
        end

        return pkg.info
    end
end

registry_info(registry::RegistryInstance, pkg::PkgEntry) = init_package_info!(registry, pkg)

@noinline function _ensure_registry_loaded_slow!(r::RegistryInstance)
    return @lock r.load_lock begin
        # Double-check pattern: if another thread loaded while we were waiting for the lock
        isdefined(r, :pkgs) && return r

        if getfield(r, :compressed_file) !== nothing
            r.in_memory_registry = uncompress_registry(joinpath(dirname(getfield(r, :path)), getfield(r, :compressed_file)))
        else
            r.in_memory_registry = nothing
        end

        d = parsefile(r.in_memory_registry, getfield(r, :path), "Registry.toml")
        r.name = d["name"]::String
        r.uuid = UUID(d["uuid"]::String)
        r.repo = get(d, "repo", nothing)::Union{String, Nothing}
        r.description = get(d, "description", nothing)::Union{String, Nothing}

        r.pkgs = Dict{UUID, PkgEntry}()
        for (uuid, info) in d["packages"]::Dict{String, Any}
            uuid = UUID(uuid::String)
            info::Dict{String, Any}
            name = info["name"]::String
            pkgpath = info["path"]::String
            pkg = PkgEntry(pkgpath, getfield(r, :path), name, uuid)
            r.pkgs[uuid] = pkg
        end

        r.name_to_uuids = Dict{String, Vector{UUID}}()

        return r
    end
end

# Property accessors that trigger lazy loading
@inline function Base.getproperty(r::RegistryInstance, f::Symbol)
    if f === :name || f === :uuid || f === :repo || f === :description || f === :pkgs || f === :name_to_uuids
        _ensure_registry_loaded_slow!(r) # Takes a lock to ensure thread safety
    end
    return getfield(r, f)
end

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

    # Create partially initialized registry - defer expensive operations
    reg = RegistryInstance(path, tree_info, compressed_file)

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
    return println(io, "  packages: ", length(r.pkgs))
end
Base.show(io::IO, r::RegistryInstance) = Base.show(io, MIME"text/plain"(), r)

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
        @warn "Failed to parse registry TOML file at $(repr(path))" exception = d
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

function reachable_registries(; depots::Union{String, Vector{String}} = Base.DEPOT_PATH)
    # collect registries
    if depots isa String
        depots = [depots]
    end
    registries = RegistryInstance[]
    for d in depots
        isdir(d) || continue
        reg_dir = joinpath(d, "registries")
        isdir(reg_dir) || continue
        reg_paths = readdir(reg_dir; join = true)
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
