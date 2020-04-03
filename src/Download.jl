module Download

import Pkg.GitTools
import Pkg.TOML

import HTTP
import Tar
import SHA: sha256

"""
    download(url, [ path ]; [ file_hash = <sha256> ]) -> path

Download the file at `url`, saving the resulting download at `path`. All
arguments are strings. If `path` is not provided, the file is saved to a
temporary location which is returned. If the `file_hash` keyword argument is
provided, the SHA2-256 hash of the downloaded file is computed and if it does
not match the provided hash value, the path is deleted and an error is thrown.

If `path` and `file_hash` are both provided and a file at that location already
exists, the hash of the existing file will be computed and if it matches the
given `file_hash`, no download is performed.
"""
function download(
    url :: AbstractString,
    path :: AbstractString = tempname();
    file_hash :: Union{AbstractString, Nothing} = nothing,
)
    file_hash = normalize_file_hash(file_hash)
    if file_hash !== nothing && isfile(path)
        hash_file(path) == file_hash && return path
        rm(path)
    end
    # TODO: should write directly to path but can't because of
    # https://github.com/JuliaWeb/HTTP.jl/issues/526
    response = HTTP.get(url, status_exception=false)
    try write(path, response.body)
    catch
        rm(path, force=true)
        rethrow()
    end
    if response.status != 200
        # TODO: handle 401 auth error
        rm(path, force=true)
        error("Download $url failed, status code $(response.status)")
    end
    if file_hash !== nothing
        calc_hash = hash_file(path)
        if calc_hash != file_hash
            msg  = "File hash mismatch!\n"
            msg *= "  Expected SHA2-256: $file_hash\n"
            msg *= "  Computed SHA2-256: $calc_hash"
            rm(path)
            error(msg)
        end
    end
    return path
end

"""
    unpack(tarball, [ path ]; [ tree_hash = <sha1> ]) -> path

Extract `tarball` to `path`, checking that the resulting tree has the git tree
SHA1 hash provided (if any is). All arguments are strings. When the tree is
unpacked, the file `\$path/.tree_info.toml` is written containing these entries:

* `git-tree-sha1`: the git tree SHA1 hash of the extracted tarball contents
* `contents`: a table of extracted paths mapped to each file's type, one of
  * `directory` — a directory
  * `file` — a plain file, not executable
  * `executable` — a file with the user executable bit set
  * `symlink: \$link` — a symbolic link followed by the link target

If `path` is already a tree and `tree_hash` is passed, the tree is checked:

* If `\$path/.tree_info.toml` exists and is a valid TOML file with a top-level
  `git-tree-sha1` key, then the associated value is compared to `tree_hash` and
  if they match the tree is presumed to have that hash and nothing is done.

* Otherwise, the existing tree at `path` is removed and replaced by the result
  of extracting `path` where `\$path/.tree_info.toml` is written as described.

If `tree_hash` is provided and after extracting the given tarball its computed
tree hash does not match the given hash value, `path` is deleted and an error
is thrown indicating the hash mismatch. Thus, successful completion guarantees
that the unpacked tree has the correct content.

If `path` is not provided, `path = tempname()` is used and returned.
"""
function unpack(
    tarball :: AbstractString,
    path :: AbstractString = tempname();
    tree_hash :: Union{AbstractString, Nothing} = nothing,
)
   unpack_core(() -> tarball, path, tree_hash = tree_hash)
end

function unpack_core(
    get_tarball :: Function,
    path :: AbstractString;
    tree_hash :: Union{AbstractString, Nothing},
)
    tree_info = joinpath(path, ".tree_info.toml")
    tree_hash = normalize_tree_hash(tree_hash)
    if tree_hash === nothing || isdir(path)
        if tree_hash !== nothing && isfile(tree_info)
            tree_info_hash = try
                get(TOML.parsefile(tree_info), "git-tree-sha1", nothing)
            catch err
                @warn "invalid TOML" path=tree_info err
            end
            tree_info_hash == tree_hash && return path
        end
        rm(path, force=true, recursive=true)
    end
    tarball = get_tarball()
    contents = Dict{String,String}()
    symlinks = Dict{String,String}()
    open(`gzcat $tarball`) do io
        Tar.extract(io, path) do hdr
            executable = hdr.type == :file && (hdr.mode & 0o100) != 0
            contents[hdr.path] = executable ? "executable" : string(hdr.type)
            hdr.type == :symlink && (symlinks[hdr.path] = hdr.link)
            return true # extract everything
        end
    end
    calc_hash = hash_tree(path)
    if tree_hash !== nothing && calc_hash != tree_hash
        msg  = "Tree hash mismatch!\n"
        msg *= "  Expected SHA1: $tree_hash\n"
        msg *= "  Computed SHA1: $calc_hash"
        rm(path, recursive=true)
        error(msg)
    end
    # make the TOML data structure
    tree_info_data = Dict{String,Any}("git-tree-sha1" => calc_hash)
    !isempty(contents) && (tree_info_data["contents"] = contents)
    !isempty(symlinks) && (tree_info_data["symlinks"] = symlinks)
    # if ".tree_info.toml" exists, warn and save its git hash
    if haskey(contents, ".tree_info.toml") && ispath(tree_info)
        @warn "Overwriting extracted `.tree_info.toml`" path=tree_info
        hash_func = (isdir(tree_info) ? GitTools.tree_hash : GitTools.blob_hash)
        tree_info_data["git-path-sha1s"] = Dict(
            ".tree_info.toml" => bytes2hex(hash_func(tree_info))
        )
        rm(tree_info, force=true, recursive=true)
    end
    open(tree_info, write=true) do io
        TOML.print(io, sorted=true, tree_info_data)
    end
    return path
end

"""
    download_unpack(url, [ path ];
        [ file_hash = <sha256> ], [ tree_hash = <sha1> ]) -> path

Download the file at `url` and unpack its contents to `path`, checking the
hash of both the downloaded file and the extracted tree if given. This is
similar to doing `unpack(download(url; file_hash)); tree_hash)` except that
if the output tree already exists with the correct tree hash, downloading
is skipped and on error the downloaded temp file is deleted immediately.

If `path` is not provided, `path = tempname()` is used and returned.
"""
function download_unpack(
    url :: AbstractString,
    path :: AbstractString = tempname();
    file_hash :: Union{AbstractString, Nothing} = nothing,
    tree_hash :: Union{AbstractString, Nothing} = nothing,
)
    tarball = nothing
    try
        unpack_core(path, tree_hash = tree_hash) do
            tarball = download(url, file_hash = file_hash)
        end
    catch
        tarball !== nothing && rm(tarball, force=true)
        rethrow()
    end
end

# file hashing

function hash_file(path::AbstractString)
    open(path) do io
        bytes2hex(sha256(io))
    end
end

function hash_tree(path::AbstractString)
    bytes2hex(GitTools.tree_hash(path))
end

# hash string normalization & validity checking

normalize_file_hash(path) = normalize_hash(256, path) # SHA256
normalize_tree_hash(path) = normalize_hash(160, path) # SHA1

normalize_hash(bits::Int, ::Nothing) = nothing
normalize_hash(bits::Int, hash::AbstractString) = normalize_hash(bits, String(hash))

function normalize_hash(bits::Int, hash::String)
    bits % 16 == 0 ||
        throw(ArgumentError("Invalid number of bits for a hash: $bits"))
    len = bits >> 2
    len_ok = length(hash) == len
    chars_ok = occursin(r"^[0-9a-f]*$"i, hash)
    if !len_ok || !chars_ok
        msg = "Hash value must be $len hexadecimal characters ($bits bits); "
        msg *= "Given hash value "
        if !chars_ok
            if isascii(hash)
                msg *= "contains non-hexadecimal characters"
            else
                msg *= "is non-ASCII"
            end
        end
        if !chars_ok && !len_ok
            msg *= " and "
        end
        if !len_ok
            msg *= "has the wrong length ($(length(hash)))"
        end
        msg *= ": $(repr(hash))"
        throw(ArgumentError(msg))
    end
    return lowercase(hash)
end

end # module
