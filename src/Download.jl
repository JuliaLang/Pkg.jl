module Download

import Pkg.GitTools
import Pkg.TOML

import HTTP
import Tar
import SHA: sha256

"""
    download(url, [ path ]; [ file_hash = <sha256> ]) -> path

Download the file at `url`, saving the resulting download at `path`. If `path`
is not provided, the file is saved to a temporary location which is returned. If
the `file_hash` keyword argument is provided, the SHA2-256 hash of the
downloaded file is computed and if it does not match the provided hash value,
the path is deleted and an error is thrown.
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
SHA1 hash provided (if any is). If `path` is already a tree, it will be checked
for being the expected tree:

* If `\$path/.tree_info.toml` exists and is a valid TOML file with a top-level
  `git-tree-sha1` key, then the associated value is compared to `tree_hash` and
  if they match the tree is presumed to have that hash and left as is.

* Otherwise, the existing tree at `path` is removed and replaced by the result
  of extracting `path` and `\$path/.tree_info.toml` is written as well with the
  value of `git-tree-sha1` set to the tree hash of the unpacked tree.

If `tree_hash` is provided and the hash of the extracted tree does not match,
then `path` is removed entirely and hash mismatch error is thrown.

If `path` is not provided, `path = tempname()` is used and returned.
"""
function unpack(
    tarball :: AbstractString,
    path :: AbstractString = tempname();
    tree_hash :: Union{AbstractString, Nothing} = nothing,
)
    tree_info = joinpath(path, ".tree_info.toml")
    tree_hash = normalize_tree_hash(tree_hash)
    if tree_hash !== nothing && isdir(path)
        if isfile(tree_info)
            tree_info_hash = try
                get(TOML.parsefile(), "git-tree-sha1", nothing)
            catch err
                @warn "invalid TOML" path=tree_info err
            end
            tree_info_hash == tree_hash && return path
        end
        rm(path, recursive=true)
    end
    contents = Dict{String,String}()
    open(`gzcat $tarball`) do io
        Tar.extract(io, path) do hdr
            x = hdr.type == :file && (hdr.mode & 0o100) != 0
            contents[hdr.path] = x ? "executable" : string(hdr.type)
            return true # extract everything
        end
    end
    # TODO: use .tree_info.toml aware tree_hash?
    calc_hash = hash_tree(path)
    if tree_hash !== nothing && calc_hash != tree_hash
        msg  = "Tree hash mismatch!\n"
        msg *= "  Expected SHA1: $tree_hash\n"
        msg *= "  Computed SHA1: $calc_hash"
        rm(path, recursive=true)
        error(msg)
    end
    if ispath(tree_info)
        @warn "Overwriting extracted `.tree_info.toml`" path=tree_info
        rm(tree_info, force=true, recursive=true)
    end
    open(tree_info, write=true) do io
        TOML.print(io, sorted=true, Dict(
            "git-tree-sha1" => calc_hash,
            "contents" => contents,
        ))
    end
    return path
end

"""
    download_unpack(url, [ path ];
        [ file_hash = <sha256> ], [ tree_hash = <sha1> ]) -> path

Download the file at `url`, saving the resulting download at `path`. If `path`
is not provided, the file is saved to a temporary location which is returned. If
the `file_hash` keyword argument is provided, the SHA2-256 hash of the
downloaded file is computed and if it does not match the provided hash value,
the path is deleted and an error is thrown.
"""
function download_unpack(
    url :: AbstractString,
    path :: AbstractString = tempname();
    file_hash :: Union{AbstractString, Nothing} = nothing,
    tree_hash :: Union{AbstractString, Nothing} = nothing,
)
    # TODO: don't download if path is already correct
    tarball = download(url, file_hash = file_hash)
    try unpack(tarball, path, tree_hash = tree_hash)
    catch
        rm(tarball, force=true)
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
