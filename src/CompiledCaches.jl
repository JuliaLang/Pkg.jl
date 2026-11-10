# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Finding precompilation cache files (`compiled/vX.Y/**/*.ji` and their native code
images) that can never be loaded again, so that `Pkg.gc` can delete them.

A cache file is dead when

1. it was compiled by a Julia build that is gone, so nothing can load it: one recorded in
   `logs/julia_usage.toml` (see `Types.record_julia_usage`) whose system image no longer
   exists or was replaced, as when Julia was uninstalled or updated, or one never recorded
   that is evidently superseded by a later build (see `unrecorded_builds!`), or
2. the source file it was compiled from (its first include) no longer exists, as after
   `Pkg.gc` deleted the package version it belonged to, or
3. one of the modules it was compiled against is no longer provided by any cache file,
   so it cannot be loaded either. Build ids are unique to one compilation, so a
   dependency recompiled after an update never satisfies it again.

Rule 3 is applied until nothing changes, so deleting a package version also takes the
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
    julia_version::VersionNumber  # without the build number of a prerelease
    git_commit::String  # of the Julia build, empty if not built from git
    # the modules this file provides and the ones it was compiled against, with full build ids
    modules::Vector{Pair{Base.PkgId, UInt128}}
    required::Vector{Pair{Base.PkgId, UInt128}}
    # the first include, the file the package was compiled from (raw, may start with `@depot`)
    entry::String
end

@enum BuildStatus BUILD_RUNNING BUILD_INSTALLED BUILD_GONE BUILD_SUPERSEDED BUILD_UNKNOWN

# Whether the caches of a build with this status can never be loaded again
is_gone(status::BuildStatus) = status == BUILD_GONE || status == BUILD_SUPERSEDED

# How long (in seconds) a build that was never recorded must have compiled nothing before
# it can count as superseded
global SUPERSEDED_AGE::Float64 = 14 * 24 * 60 * 60

"""
    julia_builds(depots) -> Dict{UInt128, BuildStatus}

The Julia builds recorded in the `julia_usage.toml` logs of `depots`, keyed by their `Base`
build id. A build is gone when none of the system images it was recorded with is still the
same file (same modification time and size); the running build never is.
"""
function julia_builds(depots::Vector{String})
    running = Base.module_build_id(Base)
    builds = Dict{UInt128, BuildStatus}(running => BUILD_RUNNING)
    for (build, entries) in usage_entries(depots)
        get(builds, build, BUILD_GONE) == BUILD_GONE || continue
        builds[build] = any(image_unchanged, entries) ? BUILD_INSTALLED : BUILD_GONE
    end
    return builds
end

# The builds and their entries in the `julia_usage.toml` logs of `depots`, a build once per
# depot whose log records it
function usage_entries(depots::Vector{String})
    result = Pair{UInt128, Vector}[]
    for depot in unique(depots)
        usage = Types.parse_toml_nothrow(joinpath(depot, "logs", "julia_usage.toml"))
        usage isa Dict || continue
        for (key, entries) in usage
            build = tryparse(UInt128, key; base = 16)
            (build === nothing || !(entries isa Vector)) && continue
            push!(result, build => entries)
        end
    end
    return result
end

# Whether the system image of a `julia_usage.toml` entry is still the recorded file. Only a
# missing image (which `stat` reports without throwing) or one observed to differ counts as
# changed; an entry or image that can not be checked (say, for lack of permissions) counts
# as unchanged, so that its caches are kept.
function image_unchanged(entry)
    return try
        image = entry["image"]::String
        st = stat(image)
        isfile(st) && st.mtime == entry["image_mtime"] && st.size == entry["image_size"]
    catch e
        e isa InterruptException && rethrow()
        true
    end
end

"""
    unrecorded_builds!(builds, headers, mtimes; installed = Set{VersionNumber}(), now = time())

Judge the builds that are not recorded in `builds` (they predate `julia_usage.toml`, or
their Julia ships a Pkg that does not record them). A release whose version is in
`installed` (see `Types.installed_julia_releases`) is marked `BUILD_INSTALLED`. Any other
is marked `BUILD_SUPERSEDED` when it is evidently replaced: they have not compiled anything for `SUPERSEDED_AGE` (loading caches
leaves no trace, so a build that is still used but compiles nothing new can be taken for
superseded; its caches are then compiled again), while later

- for a prerelease (a nightly, alpha, beta or release candidate), another build of the same
  minor version compiled something, or
- for a release, a build of a newer patch release of the same minor version did.

Two builds of the same release (say, one installed and one built from source) do not
supersede each other. `mtimes[i]` is the modification time of `headers[i]`.
"""
function unrecorded_builds!(
        builds::Dict{UInt128, BuildStatus}, headers::Vector{CacheHeader}, mtimes::Vector{Float64};
        installed::Set{VersionNumber} = Set{VersionNumber}(), now::Float64 = time(),
    )
    newest = Dict{UInt128, Float64}()
    versions = Dict{UInt128, VersionNumber}()
    for (h, t) in zip(headers, mtimes)
        build = base_build_id(h)
        build === nothing && continue
        newest[build] = max(get(newest, build, 0.0), t)
        versions[build] = h.julia_version
    end
    for (build, v) in versions
        isempty(v.prerelease) && v in installed && !haskey(builds, build) && (builds[build] = BUILD_INSTALLED)
    end
    for (build, t) in newest
        haskey(builds, build) && continue
        now - t > SUPERSEDED_AGE || continue
        v = versions[build]
        prerelease = !isempty(v.prerelease)
        superseded = any(newest) do (other, t_other)
            w = versions[other]
            other != build && t_other > t && (w.major, w.minor) == (v.major, v.minor) &&
                (prerelease || (isempty(w.prerelease) && w.patch > v.patch))
        end
        superseded && (builds[build] = BUILD_SUPERSEDED)
    end
    return builds
end

"""
    logged_versions(depots) -> Dict{UInt128, VersionNumber}

The full versions (with the build number of a prerelease, which cache headers do not have)
of the Julia builds recorded in the `julia_usage.toml` logs of `depots`.
"""
function logged_versions(depots::Vector{String})
    versions = Dict{UInt128, VersionNumber}(Base.module_build_id(Base) => VERSION)
    for (build, entries) in usage_entries(depots), e in entries
        v = e isa Dict ? get(e, "version", nothing) : nothing
        v isa String || continue
        v = tryparse(VersionNumber, v)
        v === nothing || (versions[build] = v)
    end
    return versions
end

build_status(builds::Dict{UInt128, BuildStatus}, h::CacheHeader) =
    get(builds, base_build_id(h), BUILD_UNKNOWN)

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
        git_commit = read_cstring(io)
        check(read(io, UInt8) == 0) # the header of a native code image, not of a .ji
        checksum = read(io, UInt64)
    else
        format >= 15 && read_cstring(io) # GC ABI
        flags = read(io, UInt32)
        check(flags & 0x01 != 0) # a package image, not a system image
        read_cstring(io) # git branch
        git_commit = read_cstring(io)
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
    return CacheHeader(path, julia_version, git_commit, modules, required, entry)
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

# Whether `path` is one of the directories `removed` or inside one of them
function is_removed(path::String, removed::Vector{String})
    path = normpath(path)
    return any(removed) do dir
        dir = normpath(dir)
        path == dir || startswith(path, joinpath(dir, ""))
    end
end

# Whether the entry file exists, and is not in one of the directories `removed` (which are
# about to be deleted); a path that can not be checked counts as existing.
function entry_exists(entry::String, depots::Vector{String}, removed::Vector{String} = String[])
    exists(path) = ispath(path) && !is_removed(path, removed)
    return try
        for prefix in ("@depot/", "@depot\\")
            if startswith(entry, prefix)
                rest = entry[(length(prefix) + 1):end]
                return any(depot -> exists(joinpath(depot, rest)), depots)
            end
        end
        exists(entry)
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
    dead_cachefiles(scan_depots, gc_depots; removed = String[]) -> Vector{String}

The `.ji` files in the depots `gc_depots` that can never be loaded again. `scan_depots`
are all depots whose cache files may provide the dependencies of others (the whole depot
path, including the depots bundled with Julia). Sources in the directories `removed`
count as gone, so that this can be worked out before deleting them. The builds that were
not recorded are judged and added to `builds` (see `unrecorded_builds!`), and the builds
that some cache file that stays was compiled with are added to `live_builds`.
"""
function dead_cachefiles(
        scan_depots::Vector{String}, gc_depots::Vector{String};
        removed::Vector{String} = String[], builds::Dict{UInt128, BuildStatus} = julia_builds(scan_depots),
        live_builds::Set{UInt128} = Set{UInt128}(),
        installed::Set{VersionNumber} = Types.installed_julia_releases(scan_depots),
    )
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
    unrecorded_builds!(builds, headers, Float64[mtime(h.path) for h in headers]; installed)
    dead = dead_cachefiles(headers, deletable, scan_depots, removed, builds)
    alive = trues(length(headers))
    alive[dead] .= false
    for h in headers[alive]
        build = base_build_id(h)
        build === nothing || push!(live_builds, build)
    end
    return String[h.path for h in headers[dead]]
end

function dead_cachefiles(
        headers::Vector{CacheHeader}, deletable::Vector{Bool}, depots::Vector{String},
        removed::Vector{String} = String[], builds::Dict{UInt128, BuildStatus} = Dict{UInt128, BuildStatus}(),
    )
    n = length(headers)
    dead = falses(n)

    # Rule 1: the Julia build that compiled it is gone (or superseded), so nothing can load
    # it. This includes the caches of stdlibs that build compiled into this depot.
    for (i, h) in enumerate(headers)
        deletable[i] && is_gone(build_status(builds, h)) && (dead[i] = true)
    end

    # Rule 2: the source file is gone. The source of a stdlib is found through the
    # `Sys.STDLIB` of the Julia that compiled it, which may not be this one, so those
    # are not judged.
    for (i, h) in enumerate(headers)
        (deletable[i] && !dead[i]) || continue
        is_stdlib_entry(h.entry) && continue
        entry_exists(h.entry, depots, removed) || (dead[i] = true)
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

    # Rule 3: a dependency is no longer provided by any cache file. Only dependencies that
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
