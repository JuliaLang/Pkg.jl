
function printpkgstyle(io::IO, cmd::Symbol, text::String, ignore_indent::Bool=false)
    indent = textwidth(string(:Precompiling)) # "Precompiling" is the longest operation
    ignore_indent && (indent = 0)
    printstyled(io, lpad(string(cmd), indent), color=:green, bold=true)
    println(io, " ", text)
end

const URL_regex = r"((file|git|ssh|http(s)?)|(git@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)?(/)?"x
isurl(r::String) = occursin(URL_regex, r)

stdlib_dir() = normpath(joinpath(Sys.BINDIR::String, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"))
stdlib_path(stdlib::String) = joinpath(stdlib_dir(), stdlib)

function pathrepr(path::String)
    # print stdlib paths as @stdlib/Name
    if startswith(path, stdlib_dir())
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

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
set_readonly(::Nothing) = nothing

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
