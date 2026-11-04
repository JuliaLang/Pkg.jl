# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Finding precompilation cache files (`compiled/vX.Y/**/*.ji` and their native code
images) that can never be loaded again, so that `Pkg.gc` can delete them.

A cache file is dead when

1. the source file it was compiled from (its first include) no longer exists, as after
   `Pkg.gc` deleted the package version it belonged to, or
2. one of the modules it was compiled against is no longer provided by any cache file,
   so it cannot be loaded either. Build ids are unique to one compilation, so a
   dependency recompiled after an update never satisfies it again.

Rule 2 is applied until nothing changes, so deleting a package version also takes the
caches that were compiled against it.

The headers are read here instead of with `Base.parse_cache_header`, which only reads
cache files from the running Julia build: caches from other Julia versions and builds are
dead for the same reasons and make up most of what accumulates in a depot. A header whose
layout is not one known here, or that does not parse consistently, is left alone.
"""
module CompiledCaches

using UUIDs
import ..Types

struct CacheHeader
    path::String
    julia_version::VersionNumber
    # the modules this file provides and the ones it was compiled against, with full build ids
    modules::Vector{Pair{Base.PkgId, UInt128}}
    required::Vector{Pair{Base.PkgId, UInt128}}
    # the first include, the file the package was compiled from (raw, may start with `@depot`)
    entry::String
end

struct BadHeader <: Exception end
check(cond::Bool) = cond || throw(BadHeader())

const JI_MAGIC = b"\xfbjli\r\n\x1a\n"
const MAX_NAME_LEN = 1 << 16

function read_cstring(io::IO)
    bytes = readuntil(io, 0x00; keep = true)
    check(!isempty(bytes) && last(bytes) == 0x00)
    return String(bytes[1:(end - 1)])
end

function read_name(io::IO, n::Integer)
    check(0 < n <= MAX_NAME_LEN)
    bytes = read(io, n)
    check(length(bytes) == n)
    return String(bytes)
end

function read_module_list(io::IO, checksum::UInt64, has_buildid_hi::Bool)
    modules = Pair{Base.PkgId, UInt128}[]
    while true
        n = read(io, Int32)
        n == 0 && break
        name = read_name(io, n)
        uuid = UUID((read(io, UInt64), read(io, UInt64)))
        # the modules a file provides only store the low half of their build id,
        # the high half is the checksum of the file
        hi = has_buildid_hi ? UInt128(read(io, UInt64)) : UInt128(checksum)
        build_id = (hi << 64) | read(io, UInt64)
        push!(modules, Base.PkgId(uuid == UUID(0) ? nothing : uuid, name) => build_id)
    end
    return modules
end

"""
    read_cache_header(path) -> Union{CacheHeader, Nothing}

Read the parts of the header of the cache file at `path` needed to tell whether it is
dead. Returns `nothing` for a file that is not a cache file or whose header layout is not
known here.
"""
function read_cache_header(path::String)
    return try
        open(io -> read_cache_header(io, path), path)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
end

function read_cache_header(io::IO, path::String)
    # The part written by `write_header` in `src/staticdata_utils.c`
    check(read(io, length(JI_MAGIC)) == JI_MAGIC)
    format = read(io, UInt16)
    check(read(io, UInt16) == 0xfeff)
    check(read(io, UInt8) == sizeof(Ptr{Cvoid}))
    read_cstring(io) # OS
    read_cstring(io) # arch
    julia_version = VersionNumber(read_cstring(io))
    # 12: Julia 1.10 to 1.13, 13: syntax version, 14: header flags, 15: GC ABI,
    # 16: second cache flags byte, 17 and 18: no change to the header
    12 <= format <= 18 || return nothing
    if format <= 13
        read_cstring(io) # git branch
        read_cstring(io) # git commit
        check(read(io, UInt8) == 0) # the header of a native code image, not of a .ji
        checksum = read(io, UInt64)
    else
        format >= 15 && read_cstring(io) # GC ABI
        flags = read(io, UInt32)
        check(flags & 0x01 != 0) # a package image, not a system image
        read_cstring(io) # git branch
        read_cstring(io) # git commit
        checksum = UInt64(read(io, UInt32))
    end
    skip(io, 16) # datastartpos, dataendpos

    # The part written by `write_header` in `base/loading.jl`; see `_parse_cache_header`
    skip(io, format >= 16 ? 3 : format >= 13 ? 2 : 1) # cache flags (and syntax version)
    modules = read_module_list(io, checksum, false)
    check(!isempty(modules))
    totbytes = read(io, Int64)
    entry = nothing
    while true
        n = read(io, Int32)
        totbytes -= 4
        n == 0 && break
        name = read_name(io, n)
        totbytes -= n
        # file size and hash (since 1.11), mtime
        nbytes = julia_version >= v"1.11-" ? 20 : 8
        skip(io, nbytes)
        totbytes -= nbytes
        n1 = read(io, Int32)
        totbytes -= 4
        if n1 != 0 # the path of the module that included it
            while true
                n1 = read(io, Int32)
                totbytes -= 4
                n1 == 0 && break
                read_name(io, n1)
                totbytes -= n1
            end
        end
        # a name starting with NUL is a `require` and not an include
        if entry === nothing && name[1] != '\0'
            entry = name
        end
    end
    # The preferences became one TOML blob, instead of a list of names and a hash, during
    # 1.14.0-DEV (and in 1.13), which the version does not tell exactly: take the layout
    # that accounts for all the bytes.
    check(entry !== nothing)
    prefs_pos = position(io)
    blob_first = julia_version >= v"1.13-"
    check(
        skip_preferences_at(io, prefs_pos, totbytes, blob_first) ||
            skip_preferences_at(io, prefs_pos, totbytes, !blob_first)
    )
    required = read_module_list(io, checksum, true)
    return CacheHeader(path, julia_version, modules, required, entry)
end

function skip_preferences_at(io::IO, pos::Integer, totbytes::Int64, blob::Bool)
    seek(io, pos)
    return try
        skip_preferences(io, totbytes, blob)
    catch e
        e isa EOFError || rethrow()
        false
    end
end

# Skip the preferences and `srctextpos`, the rest of the `totbytes` accounted part of the
# header; whether the bytes add up.
function skip_preferences(io::IO, totbytes::Int64, blob::Bool)
    if blob
        n = read(io, Int32)
        0 <= n <= totbytes || return false
        skip(io, n)
        totbytes -= 4 + n
    else
        while true
            n = read(io, Int32)
            totbytes -= 4
            n == 0 && break
            0 < n <= totbytes || return false
            skip(io, n)
            totbytes -= n
        end
        skip(io, 8)
        totbytes -= 8
    end
    skip(io, 8) # srctextpos
    totbytes -= 8
    return totbytes == 0
end

"""
    cachefiles(depot) -> Vector{String}

All `.ji` files in the `compiled` directory of `depot`, for every Julia version: those of
packages in `compiled/vX.Y/Name/` and those of modules without a UUID in `compiled/vX.Y/`.
"""
function cachefiles(depot::String)
    files = String[]
    compiled = joinpath(depot, "compiled")
    for version_dir in readdir_nothrow(compiled)
        for name in readdir_nothrow(version_dir)
            if endswith(name, ".ji")
                push!(files, name)
            elseif !endswith(name, ".dSYM")
                append!(files, filter(endswith(".ji"), readdir_nothrow(name)))
            end
        end
    end
    return files
end

function readdir_nothrow(dir::String)
    return try
        isdir(dir) ? readdir(dir; join = true) : String[]
    catch e
        e isa Base.IOError || rethrow()
        String[]
    end
end

"""
    companion_files(cachefile) -> Vector{String}

The files that belong to the cache file `cachefile`: itself, its native code image and,
on macOS, the debug info of the image.
"""
function companion_files(cachefile::String)
    ocachefile = Base.ocachefile_from_cachefile(cachefile)
    files = [cachefile, ocachefile]
    Sys.isapple() && push!(files, ocachefile * ".dSYM")
    return filter(ispath, files)
end

# A cache of a stdlib shipped with Julia, whose source is in the Julia installation (or
# on the machine Julia was built on) and is found through `Sys.STDLIB` of that Julia.
is_stdlib_entry(entry::String) = occursin(r"[/\\]stdlib[/\\]v\d+\.\d+[/\\]", entry)

is_stdlib_id(id::Base.PkgId) = id.uuid === nothing ? id.name in ("Core", "Base", "Main") :
    Types.is_stdlib(id.uuid) || id.uuid in Types.UPGRADABLE_STDLIBS_UUIDS

# Whether the entry file exists; a path that can not be checked counts as existing.
function entry_exists(entry::String, depots::Vector{String})
    return try
        for prefix in ("@depot/", "@depot\\")
            if startswith(entry, prefix)
                rest = entry[(length(prefix) + 1):end]
                return any(depot -> ispath(joinpath(depot, rest)), depots)
            end
        end
        ispath(entry)
    catch e
        e isa InterruptException && rethrow()
        true
    end
end

# The build id of `Base` the cache was compiled against, which identifies the system image
function base_build_id(h::CacheHeader)
    for (id, build_id) in h.required
        id.uuid === nothing && id.name == "Base" && return build_id
    end
    return nothing
end

"""
    dead_cachefiles(scan_depots, gc_depots) -> Vector{String}

The `.ji` files in the depots `gc_depots` that can never be loaded again. `scan_depots`
are all depots whose cache files may provide the dependencies of others (the whole depot
path, including the depots bundled with Julia).
"""
function dead_cachefiles(scan_depots::Vector{String}, gc_depots::Vector{String})
    headers = CacheHeader[]
    deletable = Bool[]
    for depot in unique(scan_depots)
        can_delete = depot in gc_depots
        for file in cachefiles(depot)
            h = read_cache_header(file)
            h === nothing && continue
            push!(headers, h)
            push!(deletable, can_delete)
        end
    end
    return String[h.path for h in headers[dead_cachefiles(headers, deletable, scan_depots)]]
end

function dead_cachefiles(headers::Vector{CacheHeader}, deletable::Vector{Bool}, depots::Vector{String})
    n = length(headers)
    dead = falses(n)

    # Rule 1: the source file is gone. The source of a stdlib is found through the
    # `Sys.STDLIB` of the Julia that compiled it, which may not be this one, so those
    # are not judged.
    for (i, h) in enumerate(headers)
        deletable[i] || continue
        is_stdlib_entry(h.entry) && continue
        entry_exists(h.entry, depots) || (dead[i] = true)
    end

    # The packages that have cache files compiled against each system image, and so are
    # not in that system image: a dependency in the image itself is provided by the
    # image and not by any cache file.
    not_in_sysimage = Dict{UInt128, Set{Base.PkgId}}()
    for h in headers
        is_stdlib_entry(h.entry) && continue
        base = base_build_id(h)
        base === nothing && continue
        union!(get!(Set{Base.PkgId}, not_in_sysimage, base), first.(h.modules))
    end

    providers = Dict{UInt128, Int}()
    for (i, h) in enumerate(headers)
        dead[i] && continue
        for (_, build_id) in h.modules
            providers[build_id] = get(providers, build_id, 0) + 1
        end
    end

    # Rule 2: a dependency is no longer provided by any cache file. Only dependencies that
    # are known to come from a cache file (and not from the system image, or from the
    # stdlib depot of another Julia, which is not scanned) are judged: for the running
    # system image that is known exactly, for others a package is known not to be in the
    # image when some cache file of it was compiled against the image.
    running_base = Base.module_build_id(Base)
    # a module loaded in this session can be required without its cache file
    loaded = Set{UInt128}(Base.module_build_id(m) for m in @lock(Base.require_lock, collect(values(Base.loaded_modules))))
    function missing_dependency(h::CacheHeader)
        base = base_build_id(h)
        base === nothing && return false
        known = base == running_base ? nothing : get(not_in_sysimage, base, nothing)
        base == running_base || known !== nothing || return false
        for (id, build_id) in h.required
            is_stdlib_id(id) && continue
            if known === nothing
                Base.in_sysimage(id) && continue
            else
                id in known || continue
            end
            get(providers, build_id, 0) == 0 && !(build_id in loaded) && return true
        end
        return false
    end
    changed = true
    while changed
        changed = false
        for (i, h) in enumerate(headers)
            (dead[i] || !deletable[i]) && continue
            missing_dependency(h) || continue
            dead[i] = true
            changed = true
            for (_, build_id) in h.modules
                providers[build_id] -= 1
            end
        end
    end
    return findall(dead)
end

end # module
