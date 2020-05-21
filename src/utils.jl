function set_readonly(path)
    for (root, dirs, files) in walkdir(path)
        for file in files
            filepath = joinpath(root, file)
            fmode = filemode(filepath)
            try
                chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
            catch
            end
        end
    end
    return nothing
end

# try to call realpath on as much as possible
function safe_realpath(path)
    if ispath(path)
        try
            return realpath(path)
        catch
            return path
        end
    end
    a, b = splitdir(path)
    return joinpath(safe_realpath(a), b)
end

# Windows sometimes throw on `isdir`...
function isdir_nothrow(path::String)
    try isdir(path)
    catch e
        false
    end
end

function isfile_nothrow(path::String)
    try isfile(path)
    catch e
        false
    end
end

function casesensitive_isdir(dir::String)
    dir = abspath(dir)
    lastdir = splitpath(dir)[end]
    isdir_nothrow(dir) && lastdir in readdir(joinpath(dir, ".."))
end

## ordering of UUIDs ##
if VERSION < v"1.2.0-DEV.269"  # Defined in Base as of #30947
    Base.isless(a::UUID, b::UUID) = a.value < b.value
end

"""
    stringmetric(a::AbstractString, b::AbstractString)

An implementation of the Damerau-Levenshtein distance to measure `String` similarity.
Based on https://www.csharpstar.com/csharp-string-distance-algorithm/
"""
function stringmetric(a::AbstractString, b::AbstractString)
    height, width = length(a) + 1, length(b) + 1
    matrix = zeros(Int, height, width)
    for h = 1:height
        matrix[h, 1] = h - 1
    end
    for w = 1:width
        matrix[1, w] = w - 1
    end
    for h in 1:height - 1, w in 1:width - 1
        cost = a[h] == b[w] ? 0 : 1
        insertion = matrix[h + 1,w] + 1
        deletion = matrix[h, w + 1] + 1
        substitution = matrix[h, w] + cost

        distance = min(insertion, deletion, substitution)
        if h > 2 && w > 2 && a[h - 1] == b[w - 2] && a[h - 2] == b[w - 1]
            distance = min(distance, matrix[h - 2,w - 2] + cost)
        end
        matrix[h + 1, w + 1] = distance
    end

    matrix[end, end]
end