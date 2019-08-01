module Artifacts

import Base: get, SHA1
import ..depots1
import ..GitTools: tree_hash, set_readonly
using ..BinaryPlatforms
import ..TOML
import ..Types: parse_toml
import ..PlatformEngines: download_verify_unpack, probe_platform_engines!, package

export create_artifact, artifact_exists, artifact_path, remove_artifact, verify_artifact,
       artifact_meta, artifact_hash, bind_artifact, unbind_artifact, download_artifact,
       find_artifact_toml, ensure_artifact_installed, @artifact_str, archive_artifact

## Philosophy of Artifacts:
#
# - At the lowest level, artifacts are content-addressed chunks of data.  Similarly to
#   how packages are identified by UUIDs but have human-readable mappings through the
#   registry, artifacts are identified by their SHA1 git tree hashes, but have human-
#   readable mappings through `Artifact.toml` files.
#
# - Artifacts do not _need_ to have names bound to them; they are first and foremost
#   identified by their tree hash.  A name is merely a pointer to a hash, and the hash
#   itself is what is used in all operations except the initial lookup.
#
# - A single name can be associated with multiple hashes, where one is chosen at runtime.
#   The canonical example of this is platform-dependent artifacts.  At `Artifact.toml`
#   parse-time one of the list of hashes will be chosen as the best match for the
#   current environment (Julia version, OS, processor architecture, etc...), and note
#   that it is acceptable for there to be multiple possible choices (e.g. an AVX2-
#   optimized build and a generic x86_64 build that will both run on a modern processor),
#   however one single hash will be stably chosen from the multiple possibilities.
#
# - Artifacts can be created on-machine through the `create()` functional API, and can
#   also be downloaded as tarballs from external webservers by embedding information into
#   the `Artifact.toml` file.  This can be done programmatically through the
#   `bind_artifact()` function.


# Levels of API:
#
# - Base level:
#   - create_artifact(): given no information, simply creates an artifact through a user-provided
#     callback and returns the hash of the resultant file.
#
# - Hash level:
#   - artifact_exists(hash): returns true if the hash exists on disk, false otherwise
#   - artifact_path(hash):   returns the path to a hash on disk, throws if it does not exist
#   - remove_artifact(hash): deletes `path(hash)` if it exists, does nothing otherwise.
#   - verify_artifact(hash): verifies that the artifact maintains integrity on-disk.
#   - archive_artifact(hash, out_path): compresses an artifact into a tarball.
#
# - Name level:
#   - artifact_meta(name, toml_path; platform): returns a `Dict` of the metadata stored
#     within a given `Artifact.toml` file, including things like URL, platform, etc...
#     If the artifact is a multi-map due to being platform-specific, chooses the best
#     match among its options. Returns `nothing` if no appropriate mapping exists.
#   - artifact_hash(args...; kwargs...): returns the hash of the requested name mapping
#     via `artifact_meta(args...; kwargs...)["git-tree-sha1"]`, or similar.
#   - bind_artifact(name, hash, toml_path; platform): builds a mapping from `name` to
#     `hash` within the given `Artifact.toml` file.  Optionally sets this as a platform-
#     specific artifact.
#   - unbind_artifact(name, toml_path; platform): deletes a mapping previously bound.
#   - download_artifact(hash, url, tarball_hash): downloads an artifact from a given URL
#     to the artifact store.
#   - ensure_artifact_installed(name, toml_path; platform): Wrapper around
#     `download_artifact()`, does the lookups and loop around multiple download URLs.
#
# - Utilities:
#   - find_artifact_toml(path): Attempts to find the Artifact.toml that exists for a
#     given source path.  Returns `nothing` if none could be found.


const ARTIFACT_DIR_OVERRIDE = Ref{Union{String,Nothing}}(nothing)
"""
    with_artifacts_directory(f::Function, artifacts_dir::String)

Helper function to allow temporarily changing the artifact installation directory.
"""
function with_artifacts_directory(f::Function, artifacts_dir::String)
    global ARTIFACT_DIR_OVERRIDE
    try
        ARTIFACT_DIR_OVERRIDE[] = artifacts_dir
        f()
    finally
        ARTIFACT_DIR_OVERRIDE[] = nothing
    end
end

function artifacts_dir(args...)
    global ARTIFACT_DIR_OVERRIDE
    if ARTIFACT_DIR_OVERRIDE[] === nothing
        return abspath(depots1(), "artifacts", args...)
    else
        return abspath(ARTIFACT_DIR_OVERRIDE[], args...)
    end
end

"""
    create_artifact(f::Function)

Creates a new artifact by running `f(artifact_path)`, hashing the result, and moving it
to the artifact store (`~/.julia/artifacts` on a typical installation).  Returns the
identifying tree hash of this artifact.
"""
function create_artifact(f::Function)
    # Ensure the `artifacts` directory exists.
    mkpath(artifacts_dir())

    # Temporary directory where we'll do our creation business
    temp_dir = mktempdir(artifacts_dir(); prefix="create_")

    try
        # allow the user to do their work inside the temporary directory
        f(temp_dir)

        # Calculate the tree hash for this temporary directory
        artifact_hash = SHA1(tree_hash(temp_dir))

        # If we created a dupe, just let the temp directory get destroyed. It's got the
        # same contents as whatever already exists after all, so it doesn't matter.  Only
        # move its contents if it actually contains new contents.
        if !artifact_exists(artifact_hash)
            # Move this generated directory to its final destination, set it to read-only
            mv(temp_dir, artifact_path(artifact_hash))
            set_readonly(artifact_path(artifact_hash))
        end

        # Give the people what they want
        return artifact_hash
    finally
        # Always attempt to cleanup
        rm(temp_dir; recursive=true, force=true)
    end
end

"""
    artifact_path(hash::SHA1)

Given an artifact (identified by SHA1 git tree hash), return its installation path.
"""
artifact_path(hash::SHA1) = artifacts_dir(bytes2hex(hash.bytes))

"""
    artifact_exists(hash::SHA1)

Returns whether or not the given artifact (identified by its sha1 git tree hash) exists
on-disk.  If it does not, 
"""
artifact_exists(hash::SHA1) = isdir(artifact_path(hash))

"""
    remove_artifact(hash::SHA1)

Removes the given artifact (identified by its SHA1 git tree hash) from disk.
"""
remove_artifact(hash::SHA1) = rm(artifact_path(hash); recursive=true, force=true)

"""
    verify_artifact(hash::SHA1)

Verifies that the given artifact (identified by its SHA1 git tree hash) is installed on-
disk, and retains its integrity. 
"""
function verify_artifact(hash::SHA1)
    if !artifact_exists(hash)
        return false
    end

    return hash.bytes == tree_hash(artifact_path(hash))
end

"""
    archive_artifact(hash::SHA1, tarball_path::String)

Archive an artifact into a tarball stored at `tarball_path`, returns the SHA256
of the resultant tarball.  Throws an error if the artifact does not exist.
"""
function archive_artifact(hash::SHA1, tarball_path::String)
    if !artifact_exists(hash)
        error("Unable to archive artifact $(bytes2hex(hash.bytes)): does not exist!")
    end

	# Package it up
	package(artifact_path(hash), tarball_path)

    # Calculate its sha256 and return that
    return open(tarball_path, "r") do io
        return bytes2hex(sha256(io))
    end
end


"""
    unpack_platform(entry::Dict, name::String, artifact_toml::String)

Given an `entry` for the artifact named `name`, located within the file `artifact_toml`,
returns the `Platform` object that this entry specifies.  Returns `nothing` on error.
"""
function unpack_platform(entry::Dict, name::String, artifact_toml::String)
    if !haskey(entry, "os")
        @warn("Invalid Artifact.toml at '$(artifact_toml)': platform-specific artifact entry '$name' missing 'os' key")
        return nothing
    end

    if !haskey(entry, "arch")
        @warn("Invalid Artfiact.toml at '$(artifact_toml)': platform-specific artifact entrty '$name' missing 'arch' key")
        return nothing
    end

    # Helpers to pull out `Symbol`s and `VersionNumber`s while preserving `nothing`.
    nosym(x::Nothing) = nothing
    nosym(x) = Symbol(lowercase(x))
    nover(x::Nothing) = nothing
    nover(x) = VersionNumber(x)

    # First, extract OS; we need to build a mapping here
    os_map = Dict(
        "windows" => Windows,
        "macos" => MacOS,
        "freebsd" => FreeBSD,
        "linux" => Linux,
    )
    P = get(os_map, lowercase(entry["os"]), UnknownPlatform)

    # Next, architecture, libc, libgfortran version and cxxabi (if given)
    arch = nosym(get(entry, "arch", nothing))
    libc = nosym(get(entry, "libc", nothing))
    libgfortran_version = nover(get(entry, "libgfortran_version", nothing))
    libstdcxx_version = nover(get(entry, "libstdcxx_version", nothing))
    cxxstring_abi = nosym(get(entry, "cxxstring_abi", nothing))

    # Construct the actual Platform object
    return P(arch;
        libc=libc,
        compiler_abi=CompilerABI(
            libgfortran_version=libgfortran_version,
            libstdcxx_version=libstdcxx_version,
            cxxstring_abi=cxxstring_abi
        ),
    )
end

function pack_platform!(meta::Dict, p::Platform)
    os_map = Dict(
        Windows => "windows",
        MacOS => "macos",
        FreeBSD => "freebsd",
        Linux => "linux",
    )
    meta["os"] = os_map[typeof(p)]
    meta["arch"] = string(arch(p))
    if libc(p) != nothing
        meta["libc"] = string(libc(p))
    end
    if libgfortran_version(p) != nothing
        meta["libgfortran_version"] = string(libgfortran_version(p))
    end
    if libstdcxx_version(p) != nothing
        meta["libstdcxx_version"] = string(libstdcxx_version(p))
    end
    if cxxstring_abi(p) != nothing
        meta["cxxstring_abi"] = string(cxxstring_abi(p))
    end
end

"""
    artifact_meta(name::String, artifact_toml::String;
                  platform::Platform = platform_key_abi())

Get metadata about a given artifact (identified by name) stored within the given
`Artifact.toml` file.  If the artifact is platform-specific, use `platform` to choose the
most appropriate mapping.  If none is found, return `nothing`.
"""
function artifact_meta(name::String, artifact_toml::String;
                       platform::Platform = platform_key_abi())
    if !isfile(artifact_toml)
        return nothing
    end

    # Parse the toml for the 
    return artifact_meta(name, parse_toml(artifact_toml), artifact_toml; platform=platform)
end

function artifact_meta(name::String, artifact_dict::Dict, artifact_toml::String;
                       platform::Platform = platform_key_abi())
    if !haskey(artifact_dict, name)
        return nothing
    end
    meta = artifact_dict[name]

    # If it's an array, find the entry that best matches our current platform
    if isa(meta, Array)
        dl_dict = Dict(unpack_platform(x, name, artifact_toml) => x for x in meta)
        meta = select_platform(dl_dict, platform)
    
    # If it's NOT a dict, complain
    elseif !isa(meta, Dict)
        @warn("Invalid Artifact.toml at $(artifact_toml): artifact '$name' malformed, must be array or dict!")
        return nothing
    end

    # This is such a no-no, we are going to call it out right here, right now.
    if meta != nothing && !haskey(meta, "git-tree-sha1")
        @warn("Invalid Artifact.toml at $(artifact_toml): artifact '$name' contains no `git-tree-sha1`!")
        return nothing
    end

    # Return the full meta-dict.
    return meta
end

"""
    artifact_hash(name::String, artifact_toml::String; platform::Platform = platform_key_abi())

Thin wrapper around `artifact_meta()` to return the hash of the specified, platform-
collapsed artifact.  Returns `nothing` if no mapping can be found.
"""
function artifact_hash(name::String, artifact_toml::String;
                       platform::Platform = platform_key_abi())
    meta = artifact_meta(name, artifact_toml; platform=platform)
    if meta === nothing
        return nothing
    end

    return SHA1(meta["git-tree-sha1"])
end

"""
    bind_artifact(name::String, hash::SHA1, artifact_toml::String;
                  platform::Union{Platform,Nothing} = nothing,
                  download_info::Union{Vector{Tuple},Nothing} = nothing,
                  force::Bool = false)

Writes a mapping of `name` -> `hash` within the given `Artifact.toml` file.  If
`platform` is not `nothing`, this artifact is marked as platform-specific, and will be
a multi-mapping.  It is valid to bind multiple artifacts with the same name, but
different `platform`s and `hash`'es within the same `artifact_toml`.  If `force` is set
to `true`, this will overwrite a pre-existant mapping, otherwise an error is raised.

`download_info` is an optional tuple that contains a vector of URLs and a hash.  These
URLs will be listed as possible locations where this artifact can be obtained.  The
"""
function bind_artifact(name::String, hash::SHA1, artifact_toml::String;
                       platform::Union{Platform,Nothing} = nothing,
                       download_info::Union{Vector{<:Tuple},Nothing} = nothing,
                       lazy::Bool = false,
                       force::Bool = false)
    # First, check to see if this artifact is already bound:
    if isfile(artifact_toml)
        artifact_dict = parse_toml(artifact_toml)
    
        if !force && haskey(artifact_dict, name)
            meta = artifact_dict[name]
            if !isa(meta, Array)
                error("Mapping for '$name' within $(artifact_toml) already exists!")
            elseif any((unpack_platform(x, name, artifact_toml) for x in meta) .== Ref(platform))
                error("Mapping for '$name'/$(triplet(platform)) within $(artifact_toml) already exists!")
            end
        end
    else
        artifact_dict = Dict()
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
    if download_info != nothing
        meta["download"] = [
            Dict("url" => dl[1],
                 "sha256" => dl[2],
            ) for dl in download_info
        ]
    end

    if platform == nothing
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
                x -> unpack_platform(x, name, artifact_toml) != platform,
                artifact_dict[name]
            )
            push!(artifact_dict[name], meta)
        end
    end

    # Spit it out onto disk
    open(artifact_toml, "w") do io
        TOML.print(io, artifact_dict, sorted=true)
    end
    return
end


"""
    unbind_artifact(name::String, artifact_toml::String; platform = nothing)

Unbind the given `name` from an `Artifact.toml` file.  Silently fails if no such binding
exists within the file.
"""
function unbind_artifact(name::String, artifact_toml::String;
                         platform::Union{Platform,Nothing} = nothing)
    artifact_dict = parse_toml(artifact_toml)
    if !haskey(artifact_dict, name)
        return
    end

    if platform == nothing
        delete!(artifact_dict, name)
    else
        artifact_dict[name] = filter(
            x -> unpack_platform(x, name, artifact_toml) != platform,
            artifact_dict[name]
        )
    end

    open(artifact_toml, "w") do io
        TOML.print(io, artifact_dict, sorted=true)
    end
    return
end

"""
    download_artifact(tree_hash::SHA1, tarball_url::String, tarball_hash::String;
                      verbose::Bool = false)

Download/install an artifact into the artifact store.  Returns `true` on success.
"""
function download_artifact(tree_hash::SHA1, tarball_url::String, tarball_hash::String;
                           verbose::Bool = false)
    if artifact_exists(tree_hash)
        return true
    end

    probe_platform_engines!()

    return download_verify_unpack(
        tarball_url,
        tarball_hash,
        artifact_path(tree_hash),
        verbose=verbose,
    )
end

"""
    find_artifact_toml(path::String)

Given the path to a `.jl` file, (such as the one returned by `__source__.file` in a macro
context), find the `Artifact.toml` that is contained within the containing project (if it
exists), otherwise return `nothing`.
"""
function find_artifact_toml(path::String)
    if !isdir(path)
        path = dirname(path)
    end

    while dirname(path) != path
        # Does this `Artifact.toml` exist?
        artifact_toml_path = joinpath(path, "Artifact.toml")
        if isfile(artifact_toml_path)
            return abspath(artifact_toml_path)
        end

        # Does a `Project.toml` file exist here, in the absence of an Artifact.toml?
        # If so, stop the search as we've probably hit the top-level of this 
        if isfile(joinpath(path, "Project.toml"))
            return nothing
        end
        
        # Move up a directory
        path = dirname(path)
    end

    # We never found anything, just return `nothing`
    return nothing
end

"""
    ensure_artifact_installed(name::String, artifact_toml::String;
                              platform::Platform = platform_key_abi())

Ensures an artifact is installed, downloading it via the download information stored in
`artifact_toml` if necessary.  Throws an error if unable to install.
"""
function ensure_artifact_installed(name::String, artifact_toml::String;
                                   platform::Platform = platform_key_abi())
    meta = artifact_meta(name, artifact_toml)
    if meta === nothing
        error("Cannot locate artifact '$(name)' in '$(artifact_toml)'")
    end

    return ensure_artifact_installed(name, meta; platform=platform)
end

function ensure_artifact_installed(name::String, meta::Dict;
                                   platform::Platform = platform_key_abi())
    hash = SHA1(meta["git-tree-sha1"])

    if !artifact_exists(hash)
        # If this artifact does not exist on-disk already, ensure it has download
        # information, then download it!
        if !haskey(meta, "download")
            error("Cannot automatically install '$(name)'; no download section in '$(artifact_toml)'")
        end
    
        # Attempt to download from all sources
        for entry in meta["download"]
            url = entry["url"]
            tarball_hash = entry["sha256"]
            if download_artifact(hash, url, tarball_hash)
                return artifact_path(hash)
            end
        end
        error("Unable to automatically install '$(name)' from '$(artifact_toml)'")
    else
        return artifact_path(hash)
    end
end


"""
    ensure_all_artifacts_installed(artifact_toml::String;
                                   platform = platform_key_abi())

Installs all non-lazy artifacts from a given `Artifact.toml` file.
"""
function ensure_all_artifacts_installed(artifact_toml::String;
                                        platform::Platform = platform_key_abi())
    if !isfile(artifact_toml)
        return
    end
    artifact_dict = parse_toml(artifact_toml)

    for name in keys(artifact_dict)
        meta = artifact_meta(name, artifact_dict, artifact_toml; platform=platform)
        hash = SHA1(meta["git-tree-sha1"])
        if artifact_exists(hash) || !haskey(meta, "download") || get(meta, "lazy", false)
            continue
        end

        ensure_artifact_installed(name, meta; platform=platform)
    end
end


"""
    macro artifact_str(name)

Macro that is used to automatically ensure an artifact is installed, and return its
location on-disk.  Automatically looks the artifact up by name in the project's
`Artifact.toml` file.  Throws an error on inability to install the requested artifact.
"""
macro artifact_str(name)
    return quote
        local artifact_toml = $(find_artifact_toml)($(string(__source__.file)))
        if artifact_toml === nothing
            error(string(
                "Cannot locate 'Artifact.toml' file when attempting to use artifact '",
                $(esc(name)),
                "' in '",
                $(esc(__module__)),
                "'",
            ))
        end

        # This is the resultant value at the end of all things
        $(ensure_artifact_installed)($(esc(name)), artifact_toml)
    end
end

end # module Artifacts
