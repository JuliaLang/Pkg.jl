module Artifacts

import Base: get, SHA1
import ..depots1, ..depots, ..set_readonly
import ..GitTools
using ..BinaryPlatforms
import ..TOML
import ..Types: parse_toml, write_env_usage, printpkgstyle
import ...Pkg: pkg_server
using ..PlatformEngines
using SHA

export create_artifact, artifact_exists, artifact_path, remove_artifact, verify_artifact,
       artifact_meta, artifact_hash, bind_artifact!, unbind_artifact!, download_artifact,
       find_artifacts_toml, ensure_artifact_installed, @artifact_str, archive_artifact

# keep in sync with Base.project_names and Base.manifest_names
const artifact_names = ("JuliaArtifacts.toml", "Artifacts.toml")

const ARTIFACTS_DIR_OVERRIDE = Ref{Union{String,Nothing}}(nothing)
"""
    with_artifacts_directory(f::Function, artifacts_dir::String)

Helper function to allow temporarily changing the artifact installation and search
directory.  When this is set, no other directory will be searched for artifacts, and new
artifacts will be installed within this directory.  Similarly, removing an artifact will
only effect the given artifact directory.  To layer artifact installation locations, use
the typical Julia depot path mechanism.
"""
function with_artifacts_directory(f::Function, artifacts_dir::String)
    try
        ARTIFACTS_DIR_OVERRIDE[] = artifacts_dir
        f()
    finally
        ARTIFACTS_DIR_OVERRIDE[] = nothing
    end
end

"""
    artifacts_dirs(args...)

Return a list of paths joined into all possible artifacts directories, as dictated by the
current set of depot paths and the current artifact directory override via the method
`with_artifacts_dir()`.
"""
function artifacts_dirs(args...)
    if ARTIFACTS_DIR_OVERRIDE[] === nothing
        return [abspath(depot, "artifacts", args...) for depot in depots()]
    else
        # If we've been given an override, use _only_ that directory.
        return [abspath(ARTIFACTS_DIR_OVERRIDE[], args...)]
    end
end

"""
    ARTIFACT_OVERRIDES

Artifact locations can be overridden by writing `Override.toml` files within the artifact
directories of Pkg depots.  For example, in the default depot `~/.julia`, one may create
a `~/.julia/artifacts/Override.toml` file with the following contents:

    78f35e74ff113f02274ce60dab6e92b4546ef806 = "/path/to/replacement"
    c76f8cda85f83a06d17de6c57aabf9e294eb2537 = "fb886e813a4aed4147d5979fcdf27457d20aa35d"

    [d57dbccd-ca19-4d82-b9b8-9d660942965b]
    c_simple = "/path/to/c_simple_dir"
    libfoo = "fb886e813a4aed4147d5979fcdf27457d20aa35d""

This file defines four overrides; two which override specific artifacts identified
through their content hashes, two which override artifacts based on their bound names
within a particular package's UUID.  In both cases, there are two different targets of
the override: overriding to an on-disk location through an absolutet path, and
overriding to another artifact by its content-hash.
"""
const ARTIFACT_OVERRIDES = Ref{Union{Dict,Nothing}}(nothing)
function load_overrides(;force::Bool = false)
    if ARTIFACT_OVERRIDES[] !== nothing && !force
        return ARTIFACT_OVERRIDES[]
    end

    # We organize our artifact location overrides into two camps:
    #  - overrides per UUID with artifact names mapped to a new location
    #  - overrides per hash, mapped to a new location.
    #
    # Overrides per UUID/bound name are intercepted upon Artifacts.toml load, and new
    # entries within the "hash" overrides are generated on-the-fly.  Thus, all redirects
    # mechanisticly happen through the "hash" overrides.
    overrides = Dict(
        # Overrides by UUID
        :UUID => Dict{Base.UUID,Dict{String,Union{String,SHA1}}}(),

        # Overrides by hash
        :hash => Dict{SHA1,Union{String,SHA1}}(),
    )

    for override_file in reverse(artifacts_dirs("Overrides.toml"))
        !isfile(override_file) && continue

        # Load the toml file
        depot_override_dict = parse_toml(override_file)

        function parse_mapping(mapping::String, name::String)
            if !isabspath(mapping) && !isempty(mapping)
                try
                    mapping = Base.SHA1(mapping)
                catch e
                    @error("Invalid override in '$(override_file)': entry '$(name)' must map to an absolute path or SHA1 hash!")
                    rethrow()
                end
            end
            return mapping
        end
        function parse_mapping(mapping::Dict, name::String)
            return Dict(k => parse_mapping(v, name) for (k, v) in mapping)
        end

        for (k, mapping) in depot_override_dict
            # First, parse the mapping. Is it an absolute path, a valid SHA1-hash, or neither?
            try
                mapping = parse_mapping(mapping, k)
            catch
                @error("Invalid override in '$(override_file)': failed to parse entry `$(k)`")
                continue
            end

            # Next, determine if this is a hash override or a UUID/name override
            if isa(mapping, String) || isa(mapping, SHA1)
                # if this mapping is a direct mapping (e.g. a String), store it as a hash override
                hash = try
                    Base.SHA1(hex2bytes(k))
                catch
                    @error("Invalid override in '$(override_file)': Invalid SHA1 hash '$(k)'")
                    continue
                end

                # If this mapping is the empty string, un-override it
                if mapping == ""
                    delete!(overrides[:hash], hash)
                else
                    overrides[:hash][hash] = mapping
                end
            elseif isa(mapping, Dict)
                # Convert `k` into a uuid
                uuid = try
                    Base.UUID(k)
                catch
                    @error("Invalid override in '$(override_file)': Invalid UUID '$(k)'")
                    continue
                end

                # If this mapping is itself a dict, store it as a set of UUID/artifact name overrides
                if !haskey(overrides[:UUID], uuid)
                    overrides[:UUID][uuid] = Dict{String,Union{String,SHA1}}()
                end

                # For each name in the mapping, update appropriately
                for name in keys(mapping)
                    # If the mapping for this name is the empty string, un-override it
                    if mapping[name] == ""
                        delete!(overrides[:UUID][uuid], name)
                    else
                        # Otherwise, store it!
                        overrides[:UUID][uuid][name] = mapping[name]
                    end
                end
            end
        end
    end

    ARTIFACT_OVERRIDES[] = overrides
end

# Helpers to map an override to an actual path
map_override_path(x::String) = x
map_override_path(x::SHA1) = artifact_path(x)
map_override_path(x::Nothing) = nothing

"""
    query_override(hash::SHA1; overrides::Dict = load_overrides())

Query the loaded `<DEPOT>/artifacts/Overrides.toml` settings for artifacts that should be
redirected to a particular path or another content-hash.
"""
function query_override(hash::SHA1; overrides::Dict = load_overrides())
    return map_override_path(get(overrides[:hash], hash, nothing))
end
function query_override(pkg::Base.UUID, artifact_name::String; overrides::Dict = load_overrides())
    if haskey(overrides[:UUID], pkg)
        return map_override_path(get(overrides[:UUID][pkg], artifact_name, nothing))
    end
    return nothing
end

"""
    create_artifact(f::Function)

Creates a new artifact by running `f(artifact_path)`, hashing the result, and moving it
to the artifact store (`~/.julia/artifacts` on a typical installation).  Returns the
identifying tree hash of this artifact.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function create_artifact(f::Function)
    # Ensure the `artifacts` directory exists in our default depot
    artifacts_dir = first(artifacts_dirs())
    mkpath(artifacts_dir)

    # Temporary directory where we'll do our creation business
    temp_dir = mktempdir(artifacts_dir)

    try
        # allow the user to do their work inside the temporary directory
        f(temp_dir)

        # Calculate the tree hash for this temporary directory
        artifact_hash = SHA1(GitTools.tree_hash(temp_dir))

        # If we created a dupe, just let the temp directory get destroyed. It's got the
        # same contents as whatever already exists after all, so it doesn't matter.  Only
        # move its contents if it actually contains new contents.  Note that we explicitly
        # set `honor_overrides=false` here, as we wouldn't want to drop things into the
        # system directory by accidentally creating something with the same content-hash
        # as something that was foolishly overridden.  This should be virtually impossible
        # unless the user has been very unwise, but let's be cautious.
        new_path = artifact_path(artifact_hash; honor_overrides=false)
        if !isdir(new_path)
            # Move this generated directory to its final destination, set it to read-only
            mv(temp_dir, new_path)
            set_readonly(new_path)
        end

        # Give the people what they want
        return artifact_hash
    finally
        # Always attempt to cleanup
        rm(temp_dir; recursive=true, force=true)
    end
end

"""
    artifact_paths(hash::SHA1; honor_overrides::Bool=true)

Return all possible paths for an artifact given the current list of depots as returned
by `Pkg.depots()`.  All, some or none of these paths may exist on disk.
"""
function artifact_paths(hash::SHA1; honor_overrides::Bool=true)
    # First, check to see if we've got an override:
    if honor_overrides
        override = query_override(hash)
        if override !== nothing
            return [override]
        end
    end

    return artifacts_dirs(bytes2hex(hash.bytes))
end

"""
    artifact_path(hash::SHA1; honor_overrides::Bool=true)

Given an artifact (identified by SHA1 git tree hash), return its installation path.  If
the artifact does not exist, returns the location it would be installed to.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function artifact_path(hash::SHA1; honor_overrides::Bool=true)
    # Get all possible paths (rooted in all depots)
    possible_paths = artifact_paths(hash; honor_overrides=honor_overrides)

    # Find the first path that exists and return it
    for p in possible_paths
        if isdir(p)
            return p
        end
    end

    # If none exist, then just return the one that would exist within `depots1()`.
    return first(possible_paths)
end

"""
    artifact_exists(hash::SHA1; honor_overrides::Bool=true)

Returns whether or not the given artifact (identified by its sha1 git tree hash) exists
on-disk.  Note that it is possible that the given artifact exists in multiple locations
(e.g. within multiple depots).

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function artifact_exists(hash::SHA1; honor_overrides::Bool=true)
    return any(isdir.(artifact_paths(hash; honor_overrides=honor_overrides)))
end

"""
    remove_artifact(hash::SHA1; honor_overrides::Bool=false)

Removes the given artifact (identified by its SHA1 git tree hash) from disk.  Note that
if an artifact is installed in multiple depots, it will be removed from all of them.  If
an overridden artifact is requested for removal, it will be silently ignored; this method
will never attempt to remove an overridden artifact.

In general, we recommend that you use `Pkg.gc()` to manage artifact installations and do
not use `remove_artifact()` directly, as it can be difficult to know if an artifact is
being used by another package.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function remove_artifact(hash::SHA1)
    if query_override(hash) !== nothing
        # We never remove overridden artifacts.
        return
    end

    # Get all possible paths (rooted in all depots)
    possible_paths = artifacts_dirs(bytes2hex(hash.bytes))
    for path in possible_paths
        if isdir(path)
            rm(path; recursive=true, force=true)
        end
    end
end

"""
    verify_artifact(hash::SHA1; honor_overrides::Bool=false)

Verifies that the given artifact (identified by its SHA1 git tree hash) is installed on-
disk, and retains its integrity.  If the given artifact is overridden, skips the
verification unless `honor_overrides` is set to `true`.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function verify_artifact(hash::SHA1; honor_overrides::Bool=false)
    # Silently skip overridden artifacts unless we really ask for it
    if !honor_overrides
        if query_override(hash) !== nothing
            return true
        end
    end

    # If it doesn't even exist, then skip out
    if !artifact_exists(hash)
        return false
    end

    # Otherwise actually run the verification
    return hash.bytes == GitTools.tree_hash(artifact_path(hash))
end

"""
    archive_artifact(hash::SHA1, tarball_path::String; honor_overrides::Bool=false)

Archive an artifact into a tarball stored at `tarball_path`, returns the SHA256 of the
resultant tarball as a hexidecimal string. Throws an error if the artifact does not
exist.  If the artifact is overridden, throws an error unless `honor_overrides` is set.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function archive_artifact(hash::SHA1, tarball_path::String; honor_overrides::Bool=false)
    if !honor_overrides
        if query_override(hash) !== nothing
            error("Will not archive an overridden artifact unless `honor_overrides` is set!")
        end
    end

    if !artifact_exists(hash)
        error("Unable to archive artifact $(bytes2hex(hash.bytes)): does not exist!")
    end

    probe_platform_engines!()

    # Package it up
    package(artifact_path(hash), tarball_path)

    # Calculate its sha256 and return that
    return open(tarball_path, "r") do io
        return bytes2hex(sha256(io))
    end
end


"""
    unpack_platform(entry::Dict, name::String, artifacts_toml::String)

Given an `entry` for the artifact named `name`, located within the file `artifacts_toml`,
returns the `Platform` object that this entry specifies.  Returns `nothing` on error.
"""
function unpack_platform(entry::Dict, name::String, artifacts_toml::String)
    if !haskey(entry, "os")
        @error("Invalid artifacts file at '$(artifacts_toml)': platform-specific artifact entry '$name' missing 'os' key")
        return nothing
    end

    if !haskey(entry, "arch")
        @error("Invalid artifacts file at '$(artifacts_toml)': platform-specific artifact entrty '$name' missing 'arch' key")
        return nothing
    end

    # Helpers to pull out `Symbol`s and `VersionNumber`s while preserving `nothing`.
    nosym(x::Nothing) = nothing
    nosym(x) = Symbol(lowercase(x))
    nover(x::Nothing) = nothing
    nover(x) = VersionNumber(x)

    # Extract architecture, libc, libgfortran version and cxxabi (if given)
    arch = nosym(get(entry, "arch", nothing))
    libc = nosym(get(entry, "libc", nothing))
    libgfortran_version = nover(get(entry, "libgfortran_version", nothing))
    libstdcxx_version = nover(get(entry, "libstdcxx_version", nothing))
    cxxstring_abi = nosym(get(entry, "cxxstring_abi", nothing))

    # Construct the actual Platform object
    os = lowercase(entry["os"])
    compiler_abi=CompilerABI(
        libgfortran_version=libgfortran_version,
        libstdcxx_version=libstdcxx_version,
        cxxstring_abi=cxxstring_abi
    )
    if os == "linux"
        return Linux(arch; libc=libc, compiler_abi=compiler_abi)
    elseif os == "windows"
        return Windows(arch; libc=libc, compiler_abi=compiler_abi)
    elseif os == "macos"
        return MacOS(arch; libc=libc, compiler_abi=compiler_abi)
    elseif os == "freebsd"
        return FreeBSD(arch; libc=libc, compiler_abi=compiler_abi)
    else
        return UnknownPlatform()
    end
end

function pack_platform!(meta::Dict, p::Platform)
    @nospecialize meta p
    os_map = Dict(
        Windows => "windows",
        MacOS => "macos",
        FreeBSD => "freebsd",
        Linux => "linux",
    )
    meta["os"] = os_map[typeof(p)]
    meta["arch"] = string(arch(p))
    if libc(p) !== nothing
        meta["libc"] = string(libc(p))
    end
    if libgfortran_version(p) !== nothing
        meta["libgfortran_version"] = string(libgfortran_version(p))
    end
    if libstdcxx_version(p) !== nothing
        meta["libstdcxx_version"] = string(libstdcxx_version(p))
    end
    if cxxstring_abi(p) !== nothing
        meta["cxxstring_abi"] = string(cxxstring_abi(p))
    end
end

"""
    load_artifacts_toml(artifacts_toml::String;
                        pkg_uuid::Union{UUID,Nothing}=nothing)

Loads an `(Julia)Artifacts.toml` file from disk.  If `pkg_uuid` is set to the `UUID` of the
owning package, UUID/name overrides stored in a depot `Overrides.toml` will be resolved.
"""
function load_artifacts_toml(artifacts_toml::String;
                             pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    artifact_dict = parse_toml(artifacts_toml)

    # Process overrides for this `pkg_uuid`
    process_overrides(artifact_dict, pkg_uuid)
    return artifact_dict
end

"""
    process_overrides(artifact_dict::Dict, pkg_uuid::Base.UUID)

When loading an `Artifacts.toml` file, we must check `Override.toml` files to see if any
of the artifacts within it have been overridden by UUID.  If they have, we honor the
overrides by inspecting the hashes of the targeted artifacts, then overriding them to
point to the given override, punting the actual redirection off to the hash-based
override system.  This does not modify the `artifact_dict` object, it merely dynamically
adds more hash-based overrides as `Artifacts.toml` files that are overridden are loaded.
"""
function process_overrides(artifact_dict::Dict, pkg_uuid::Base.UUID)
    # Insert just-in-time hash overrides by looking up the names of anything we need to
    # override for this UUID, and inserting new overrides for those hashes.
    overrides = load_overrides()
    if haskey(overrides[:UUID], pkg_uuid)
        pkg_overrides = overrides[:UUID][pkg_uuid]

        for name in keys(artifact_dict)
            # Skip names that we're not overriding
            if !haskey(pkg_overrides, name)
                continue
            end

            # If we've got a platform-specific friend, override all hashes:
            if isa(artifact_dict[name], Array)
                for entry in artifact_dict[name]
                    hash = SHA1(entry["git-tree-sha1"])
                    overrides[:hash][hash] = overrides[:UUID][pkg_uuid][name]
                end
            elseif isa(artifact_dict[name], Dict)
                hash = SHA1(artifact_dict[name]["git-tree-sha1"])
                overrides[:hash][hash] = overrides[:UUID][pkg_uuid][name]
            end
        end
    end
    return artifact_dict
end

# If someone tries to call process_overrides() with `nothing`, do exactly that
process_overrides(artifact_dict::Dict, pkg_uuid::Nothing) = nothing

"""
    artifact_meta(name::String, artifacts_toml::String;
                  platform::Platform = platform_key_abi(),
                  pkg_uuid::Union{Base.UUID,Nothing}=nothing)

Get metadata about a given artifact (identified by name) stored within the given
`(Julia)Artifacts.toml` file.  If the artifact is platform-specific, use `platform` to choose the
most appropriate mapping.  If none is found, return `nothing`.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function artifact_meta(name::String, artifacts_toml::String;
                       platform::Platform = platform_key_abi(),
                       pkg_uuid::Union{Base.UUID,Nothing}=nothing)
    @nospecialize platform
    if !isfile(artifacts_toml)
        return nothing
    end

    # Parse the toml of the artifacts_toml file
    artifact_dict = load_artifacts_toml(artifacts_toml; pkg_uuid=pkg_uuid)
    return artifact_meta(name, artifact_dict, artifacts_toml; platform=platform)
end

function artifact_meta(name::String, artifact_dict::Dict, artifacts_toml::String;
                       platform::Platform = platform_key_abi())
    @nospecialize platform
    if !haskey(artifact_dict, name)
        return nothing
    end
    meta = artifact_dict[name]

    # If it's an array, find the entry that best matches our current platform
    if isa(meta, Array)
        dl_dict = Dict{Platform,Dict{String,Any}}(unpack_platform(x, name, artifacts_toml) => x for x in meta)
        meta = select_platform(dl_dict, platform)
    # If it's NOT a dict, complain
    elseif !isa(meta, Dict)
        @error("Invalid artifacts file at $(artifacts_toml): artifact '$name' malformed, must be array or dict!")
        return nothing
    end

    # This is such a no-no, we are going to call it out right here, right now.
    if meta !== nothing && !haskey(meta, "git-tree-sha1")
        @error("Invalid artifacts file at $(artifacts_toml): artifact '$name' contains no `git-tree-sha1`!")
        return nothing
    end

    # Return the full meta-dict.
    return meta
end

"""
    artifact_hash(name::String, artifacts_toml::String; platform::Platform = platform_key_abi())

Thin wrapper around `artifact_meta()` to return the hash of the specified, platform-
collapsed artifact.  Returns `nothing` if no mapping can be found.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function artifact_hash(name::String, artifacts_toml::String;
                       platform::Platform = platform_key_abi(),
                       pkg_uuid::Union{Base.UUID,Nothing}=nothing)
    @nospecialize platform
    meta = artifact_meta(name, artifacts_toml; platform=platform)
    if meta === nothing
        return nothing
    end

    return SHA1(meta["git-tree-sha1"])
end

"""
    bind_artifact!(artifacts_toml::String, name::String, hash::SHA1;
                   platform::Union{Platform,Nothing} = nothing,
                   download_info::Union{Vector{Tuple},Nothing} = nothing,
                   lazy::Bool = false,
                   force::Bool = false)

Writes a mapping of `name` -> `hash` within the given `(Julia)Artifacts.toml` file. If
`platform` is not `nothing`, this artifact is marked as platform-specific, and will be
a multi-mapping.  It is valid to bind multiple artifacts with the same name, but
different `platform`s and `hash`'es within the same `artifacts_toml`.  If `force` is set
to `true`, this will overwrite a pre-existant mapping, otherwise an error is raised.

`download_info` is an optional vector that contains tuples of URLs and a hash.  These
URLs will be listed as possible locations where this artifact can be obtained.  If `lazy`
is set to `true`, even if download information is available, this artifact will not be
downloaded until it is accessed via the `artifact"name"` syntax, or
`ensure_artifact_installed()` is called upon it.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function bind_artifact!(artifacts_toml::String, name::String, hash::SHA1;
                        platform::Union{Platform,Nothing} = nothing,
                        download_info::Union{Vector{<:Tuple},Nothing} = nothing,
                        lazy::Bool = false,
                        force::Bool = false)
    # First, check to see if this artifact is already bound:
    if isfile(artifacts_toml)
        artifact_dict = parse_toml(artifacts_toml)

        if !force && haskey(artifact_dict, name)
            meta = artifact_dict[name]
            if !isa(meta, Array)
                error("Mapping for '$name' within $(artifacts_toml) already exists!")
            elseif any((unpack_platform(x, name, artifacts_toml) for x in meta) .== Ref(platform))
                error("Mapping for '$name'/$(triplet(platform)) within $(artifacts_toml) already exists!")
            end
        end
    else
        artifact_dict = TOML.DictType()
    end

    # Otherwise, the new piece of data we're going to write out is this dict:
    meta = Dict{String,Any}(
        "git-tree-sha1" => bytes2hex(hash.bytes),
    )

    # If we're set to be lazy, then lazy we shall be
    if lazy
        meta["lazy"] = true
    end

    # Integrate download info, if it is given.  We represent the download info as a
    # vector of dicts, each with its own `url` and `sha256`, since different tarballs can
    # expand to the same tree hash.
    if download_info !== nothing
        meta["download"] = [
            Dict("url" => dl[1],
                 "sha256" => dl[2],
            ) for dl in download_info
        ]
    end

    if platform === nothing
        artifact_dict[name] = meta
    else
        # Add platform-specific keys to our `meta` dict
        pack_platform!(meta, platform)

        # Insert this entry into the list of artifacts
        if !haskey(artifact_dict, name)
            artifact_dict[name] = [meta]
        else
            # Delete any entries that contain identical platforms
            artifact_dict[name] = filter(
                x -> unpack_platform(x, name, artifacts_toml) != platform,
                artifact_dict[name]
            )
            push!(artifact_dict[name], meta)
        end
    end

    # Spit it out onto disk
    let artifact_dict = artifact_dict
        open(artifacts_toml, "w") do io
            TOML.print(io, artifact_dict, sorted=true)
        end
    end

    # Mark that we have used this Artifact.toml
    write_env_usage(artifacts_toml, "artifact_usage.toml")
    return
end


"""
    unbind_artifact!(artifacts_toml::String, name::String; platform = nothing)

Unbind the given `name` from an `(Julia)Artifacts.toml` file.
Silently fails if no such binding exists within the file.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function unbind_artifact!(artifacts_toml::String, name::String;
                         platform::Union{Platform,Nothing} = nothing)
    artifact_dict = parse_toml(artifacts_toml)
    if !haskey(artifact_dict, name)
        return
    end

    if platform === nothing
        delete!(artifact_dict, name)
    else
        artifact_dict[name] = filter(
            x -> unpack_platform(x, name, artifacts_toml) != platform,
            artifact_dict[name]
        )
    end

    open(artifacts_toml, "w") do io
        TOML.print(io, artifact_dict, sorted=true)
    end
    return
end

"""
    download_artifact(tree_hash::SHA1, tarball_url::String, tarball_hash::String;
                      verbose::Bool = false)

Download/install an artifact into the artifact store.  Returns `true` on success.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function download_artifact(
    tree_hash::SHA1,
    tarball_url::String,
    tarball_hash::Union{String, Nothing} = nothing;
    verbose::Bool = false,
    quiet_download::Bool = false,
)
    if artifact_exists(tree_hash)
        return true
    end

    # Ensure that we're ready to download things
    probe_platform_engines!()

    if Sys.iswindows()
        # The destination directory we're hoping to fill:
        dest_dir = artifact_path(tree_hash; honor_overrides=false)

        # On Windows, we have some issues around stat() and chmod() that make properly
        # determining the git tree hash problematic; for this reason, we use the "unsafe"
        # artifact unpacking method, which does not properly verify unpacked git tree
        # hash.  This will be fixed in a future Julia release which will properly interrogate
        # the filesystem ACLs for executable permissions, which git tree hashes care about.
        try
            download_verify_unpack(tarball_url, tarball_hash, dest_dir, ignore_existence=true,
                                   verbose=verbose, quiet_download=quiet_download)
        catch e
            # Clean that destination directory out if something went wrong
            rm(dest_dir; force=true, recursive=true)

            if isa(e, InterruptException)
                rethrow(e)
            end
            return false
        end
    else
        # We download by using `create_artifact()`.  We do this because the download may
        # be corrupted or even malicious; we don't want to clobber someone else's artifact
        # by trusting the tree hash that has been given to us; we will instead download it
        # to a temporary directory, calculate the true tree hash, then move it to the proper
        # location only after knowing what it is, and if something goes wrong in the process,
        # everything should be cleaned up.  Luckily, that is precisely what our
        # `create_artifact()` wrapper does, so we use that here.
        calc_hash = try
            create_artifact() do dir
                download_verify_unpack(tarball_url, tarball_hash, dir, ignore_existence=true, verbose=verbose)
            end
        catch e
            if isa(e, InterruptException)
                rethrow(e)
            end
            # If something went wrong during download, return false
            return false
        end

        # Did we get what we expected?  If not, freak out.
        if calc_hash.bytes != tree_hash.bytes
            msg  = "Tree Hash Mismatch!\n"
            msg *= "  Expected git-tree-sha1:   $(bytes2hex(tree_hash.bytes))\n"
            msg *= "  Calculated git-tree-sha1: $(bytes2hex(calc_hash.bytes))"
            @error(msg)
            # Tree hash calculation is still broken on some systems, e.g. Pkg.jl#1860,
            # so we return true here and only raise the warning on the lines above.
            # return false
        end
    end

    return true
end

"""
    find_artifacts_toml(path::String)

Given the path to a `.jl` file, (such as the one returned by `__source__.file` in a macro
context), find the `(Julia)Artifacts.toml` that is contained within the containing project (if it
exists), otherwise return `nothing`.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function find_artifacts_toml(path::String)
    if !isdir(path)
        path = dirname(path)
    end

    # Run until we hit the root directory.
    while dirname(path) != path
        for f in artifact_names
            artifacts_toml_path = joinpath(path, f)
            if isfile(artifacts_toml_path)
                return abspath(artifacts_toml_path)
            end
        end

        # Does a `(Julia)Project.toml` file exist here, in the absence of an Artifacts.toml?
        # If so, stop the search as we've probably hit the top-level of this package,
        # and we don't want to escape out into the larger filesystem.
        for f in Base.project_names
            if isfile(joinpath(path, f))
                return nothing
            end
        end

        # Move up a directory
        path = dirname(path)
    end

    # We never found anything, just return `nothing`
    return nothing
end

"""
    ensure_artifact_installed(name::String, artifacts_toml::String;
                              platform::Platform = platform_key_abi(),
                              pkg_uuid::Union{Base.UUID,Nothing}=nothing)

Ensures an artifact is installed, downloading it via the download information stored in
`artifacts_toml` if necessary.  Throws an error if unable to install.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function ensure_artifact_installed(name::String, artifacts_toml::String;
                                   platform::Platform = platform_key_abi(),
                                   pkg_uuid::Union{Base.UUID,Nothing}=nothing,
                                   verbose::Bool = false,
                                   quiet_download::Bool = false)
    @nospecialize platform
    meta = artifact_meta(name, artifacts_toml; pkg_uuid=pkg_uuid, platform=platform)
    if meta === nothing
        error("Cannot locate artifact '$(name)' in '$(artifacts_toml)'")
    end

    return ensure_artifact_installed(name, meta, artifacts_toml; platform=platform,
                                     verbose=verbose, quiet_download=quiet_download)
end

function ensure_artifact_installed(name::String, meta::Dict, artifacts_toml::String;
                                   platform::Platform = platform_key_abi(),
                                   verbose::Bool = false,
                                   quiet_download::Bool = false)
    @nospecialize platform
    hash = SHA1(meta["git-tree-sha1"])

    if !artifact_exists(hash)
        # first try downloading from Pkg server
        # TODO: only do this if Pkg server knows about this package
        if (server = pkg_server()) !== nothing
            url = "$server/artifact/$hash"
            download_success = with_show_download_info(name, quiet_download) do
                download_artifact(hash, url; verbose=verbose, quiet_download=quiet_download)
            end
            download_success && return artifact_path(hash)
        end

        # If this artifact does not exist on-disk already, ensure it has download
        # information, then download it!
        if !haskey(meta, "download")
            error("Cannot automatically install '$(name)'; no download section in '$(artifacts_toml)'")
        end

        # Attempt to download from all sources
        for entry in meta["download"]
            url = entry["url"]
            tarball_hash = entry["sha256"]
            download_success = with_show_download_info(name, quiet_download) do
                download_artifact(hash, url, tarball_hash; verbose=verbose, quiet_download=quiet_download)
            end
            download_success && return artifact_path(hash)
        end
        error("Unable to automatically install '$(name)' from '$(artifacts_toml)'")
    else
        return artifact_path(hash)
    end
end

function with_show_download_info(f, name, quiet_download)
    if !quiet_download
        # Should ideally pass ctx::Context as first arg here
        printpkgstyle(stdout, :Downloading, "artifact: $name")
        print(stdout, "\e[?25l") # disable cursor
    end
    try
        return f()
    finally
        if !quiet_download
            print(stdout, "\033[1A") # move cursor up one line
            print(stdout, "\033[2K") # clear line
            print(stdout, "\e[?25h") # put back cursor
        end
    end
end

"""
    ensure_all_artifacts_installed(artifacts_toml::String;
                                   platform = platform_key_abi(),
                                   pkg_uuid = nothing,
                                   include_lazy = false,
                                   verbose = false,
                                   quiet_download = false)

Installs all non-lazy artifacts from a given `(Julia)Artifacts.toml` file. `package_uuid` must
be provided to properly support overrides from `Overrides.toml` entries in depots.

If `include_lazy` is set to `true`, then lazy packages will be installed as well.

!!! compat "Julia 1.3"
    This function requires at least Julia 1.3.
"""
function ensure_all_artifacts_installed(artifacts_toml::String;
                                        platform::Platform = platform_key_abi(),
                                        pkg_uuid::Union{Nothing,Base.UUID} = nothing,
                                        include_lazy::Bool = false,
                                        verbose::Bool = false,
                                        quiet_download::Bool = false)
    @nospecialize platform
    if !isfile(artifacts_toml)
        return
    end
    artifact_dict = load_artifacts_toml(artifacts_toml; pkg_uuid=pkg_uuid)

    for name in keys(artifact_dict)
        # Get the metadata about this name for the requested platform
        meta = artifact_meta(name, artifact_dict, artifacts_toml; platform=platform)

        # If there are no instances of this name for the desired platform, skip it
        meta === nothing && continue

        # If this mapping doesn't have a `download` stanza or is lazy, skip it
        if !haskey(meta, "download") || (get(meta, "lazy", false) && !include_lazy)
            continue
        end

        # Otherwise, let's try and install it!
        ensure_artifact_installed(name, meta, artifacts_toml; platform=platform,
                                  verbose=verbose, quiet_download=quiet_download)
    end
end

"""
    extract_all_hashes(artifacts_toml::String;
                       platform = platform_key_abi(),
                       pkg_uuid = nothing,
                       include_lazy = false)

Extract all hashes from a given `(Julia)Artifacts.toml` file. `package_uuid` must
be provided to properly support overrides from `Overrides.toml` entries in depots.

If `include_lazy` is set to `true`, then lazy packages will be installed as well.
"""
function extract_all_hashes(artifacts_toml::String;
                            platform::Platform = platform_key_abi(),
                            pkg_uuid::Union{Nothing,Base.UUID} = nothing,
                            include_lazy::Bool = false)
    @nospecialize platform
    hashes = Base.SHA1[]
    if !isfile(artifacts_toml)
        return hashes
    end

    artifact_dict = load_artifacts_toml(artifacts_toml; pkg_uuid=pkg_uuid)

    for name in keys(artifact_dict)
        # Get the metadata about this name for the requested platform
        meta = artifact_meta(name, artifact_dict, artifacts_toml; platform=platform)

        # If there are no instances of this name for the desired platform, skip it
        meta === nothing && continue

        # If it's a lazy one and we aren't including lazy ones, skip
        if get(meta, "lazy", false) && !include_lazy
            continue
        end

        # Otherwise, add it to the list!
        push!(hashes, Base.SHA1(meta["git-tree-sha1"]))
    end

    return hashes
end

function do_artifact_str(name, artifact_dict, artifacts_toml, __module__)
    local pkg_uuid = nothing
    if haskey(Base.module_keys, __module__)
        # Process overrides for this UUID, if we know what it is
        process_overrides(artifact_dict, Base.module_keys[__module__].uuid)
    end

    # Get platform once to avoid extra work
    platform = platform_key_abi()

    # Get the metadata about this name for the requested platform
    meta = artifact_meta(name, artifact_dict, artifacts_toml; platform=platform)

    if meta === nothing
        error("Cannot locate artifact '$(name)' in '$(artifacts_toml)'")
    end

    # This is the resultant value at the end of all things
    return ensure_artifact_installed(name, meta, artifacts_toml; platform=platform)
end

"""
    macro artifact_str(name)

Macro that is used to automatically ensure an artifact is installed, and return its
location on-disk.  Automatically looks the artifact up by name in the project's
`(Julia)Artifacts.toml` file.  Throws an error on inability to install the requested artifact.
If run in the REPL, searches for the toml file starting in the current directory, see
`find_artifacts_toml()` for more.

!!! compat "Julia 1.3"
    This macro requires at least Julia 1.3.
"""
macro artifact_str(name)
    # Load Artifacts.toml at compile time, so that we don't have to use `__source__.file`
    # at runtime, which gets stale if the `.ji` file is relocated.
    srcfile = string(__source__.file)
    if startswith(srcfile, "REPL[") && !isfile(srcfile)
        srcfile = pwd()
    end
    local artifacts_toml = find_artifacts_toml(srcfile)
    if artifacts_toml === nothing
        error(string(
            "Cannot locate '(Julia)Artifacts.toml' file when attempting to use artifact '",
            name,
            "' in '",
            __module__,
            "'",
        ))
    end

    local artifact_dict = load_artifacts_toml(artifacts_toml)
    return quote
        # Invalidate .ji file if Artifacts.toml file changes
        Base.include_dependency($(artifacts_toml))

        # Use invokelatest() to introduce a compiler barrier, preventing many backedges from being added
        # and slowing down not only compile time, but also `.ji` load time.  This is critical here, as
        # artifact"" is used in other modules, so we don't want to be spreading backedges around everywhere.
        Base.invokelatest(do_artifact_str, $(esc(name)), $(artifact_dict), $(artifacts_toml), $__module__)
    end
end

end # module Artifacts
