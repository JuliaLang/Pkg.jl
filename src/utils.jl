# "Precompiling" is the longest operation
const pkgstyle_indent = textwidth(string(:Precompiling))

using ArtifactDownloads: set_readonly, mv_temp_dir_retries, atomic_toml_write

function printpkgstyle(io::IO, cmd::Symbol, text::String, ignore_indent::Bool = false; color = :green)
    indent = ignore_indent ? 0 : pkgstyle_indent
    return @lock io begin
        printstyled(io, lpad(string(cmd), indent), color = color, bold = true)
        println(io, " ", text)
    end
end

function linewrap(str::String; io = stdout_f(), padding = 0, width = Base.displaysize(io)[2])
    text_chunks = split(str, ' ')
    lines = String[""]
    for chunk in text_chunks
        new_line_attempt = string(last(lines), chunk, " ")
        if length(strip(new_line_attempt)) > width - padding
            lines[end] = strip(last(lines))
            push!(lines, string(chunk, " "))
        else
            lines[end] = new_line_attempt
        end
    end
    return lines
end

const URL_regex = r"((file|git|ssh|http(s)?)|([\w\-\.]+@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)?(/)?"x
isurl(r::String) = occursin(URL_regex, r)

stdlib_path(stdlib::String) = joinpath(Sys.STDLIB, stdlib)

function pathrepr(path::String)
    # print stdlib paths as @stdlib/Name
    if startswith(path, Sys.STDLIB)
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

"""
    normalize_path_for_toml(path::String)

Normalize a path for writing to TOML files (Project.toml/Manifest.toml).
On Windows, converts relative paths to use forward slashes for cross-platform compatibility.
Absolute paths are left unchanged as they are platform-specific by nature.
"""
function normalize_path_for_toml(path::String)
    if Sys.iswindows() && !isabspath(path)
        return join(splitpath(path), "/")
    end
    return path
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
    # path cannot be reduced at the root or drive, avoid stack overflow
    isempty(b) && return path
    return joinpath(safe_realpath(a), b)
end

# Windows sometimes throw on `isdir`...
function isdir_nothrow(path::String)
    return try
        isdir(path)
    catch e
        false
    end
end

function isfile_nothrow(path::String)
    return try
        isfile(path)
    catch e
        false
    end
end


## ordering of UUIDs ##
if VERSION < v"1.2.0-DEV.269"  # Defined in Base as of #30947
    Base.isless(a::UUID, b::UUID) = a.value < b.value
end

function discover_repo(path::AbstractString)
    dir = abspath(path)
    stop_dir = homedir()
    depot = Pkg.depots1()

    while true
        dir == depot && return nothing
        gitdir = joinpath(dir, ".git")
        if isdir(gitdir) || isfile(gitdir)
            return dir
        end
        dir == stop_dir && return nothing
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
    return
end

# Resolve a manifest-relative path to an absolute path
# Note: Despite the name "manifest_rel_path", this resolves relative to the manifest file
manifest_rel_path(env, path::String) = normpath(joinpath(dirname(env.manifest_file), path))
