module Download

import HTTP
import Tar
import SHA: sha256

"""
    download_file(url, [ path ]; [ file_hash = <sha256 hash> ]) -> path

Download the file at `url`, saving the resulting download at `path`. If `path`
is not provided, the file is saved to a temporary location which is returned. If
the `file_hash` keyword argument is provided, the SHA2-256 hash of the
downloaded file is computed and if it does not match the provided hash value,
the path is deleted and an error is thrown.
"""
function download_file(
    url :: AbstractString,
    path :: AbstractString = tempname();
    file_hash :: Union{AbstractString, Nothing} = nothing,
)
    file_hash = normalize_hash(256, file_hash)
    if file_hash !== nothing && isfile(path)
        hash_file(path) == file_hash && return path
        rm(path, force=true)
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
            msg  = "Hash mismatch!\n"
            msg *= "  Expected sha256: $file_hash\n"
            msg *= "  Received sha256: $calc_hash"
            rm(path, force=true)
            error(msg)
        end
    end
    return path
end

function download_tree(
    url :: AbstractString,
    path :: AbstractString;
    file_hash :: Union{AbstractString, Nothing} = nothing,
    tree_hash :: Union{AbstractString, Nothing} = nothing,
)
    temp = download_file(url, file_hash = file_hash)

end

# file hashing

function hash_file(path::AbstractString, hash::Function = sha256)
    open(path) do io
        bytes2hex(hash(io))
    end
end

# hash string normalization & validity checking

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
