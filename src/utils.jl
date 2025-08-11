# "Precompiling" is the longest operation
const pkgstyle_indent = textwidth(string(:Precompiling))

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
            # `chmod` on a link would change the permissions of the target.  If
            # the link points to a file within the same root, it will be
            # chmod'ed anyway, but we don't want to make directories read-only.
            # It's better not to mess with the other cases (links to files
            # outside of the root, links to non-file/non-directories, etc...)
            islink(filepath) && continue
            fmode = filemode(filepath)
            @static if Sys.iswindows()
                if Sys.isexecutable(filepath)
                    fmode |= 0o111
                end
            end
            try
                chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
            catch
            end
        end
    end
    return nothing
end
set_readonly(::Nothing) = nothing

"""
    mv_temp_dir_retries(temp_dir::String, new_path::String; set_permissions::Bool=true)::Nothing

Either rename the directory at `temp_dir` to `new_path` and set it to read-only
or if `new_path` already exists try to do nothing. Both `temp_dir` and `new_path` must
be on the same filesystem.
"""
function mv_temp_dir_retries(temp_dir::String, new_path::String; set_permissions::Bool = true)::Nothing
    # Sometimes a rename can fail because the temp_dir is locked by
    # anti-virus software scanning the new files.
    # In this case we want to sleep and try again.
    # I am using the list of error codes to retry from:
    # https://github.com/isaacs/node-graceful-fs/blob/234379906b7d2f4c9cfeb412d2516f42b0fb4953/polyfills.js#L87
    # Retry for up to about 60 seconds by retrying 20 times with exponential backoff.
    retry = 0
    max_num_retries = 20 # maybe this should be configurable?
    sleep_amount = 0.01 # seconds
    max_sleep_amount = 5.0 # seconds
    while true
        isdir(new_path) && return
        # This next step is like
        # `mv(temp_dir, new_path)`.
        # However, `mv` defaults to `cp` if `rename` returns an error.
        # `cp` is not atomic, so avoid the potential of calling it.
        err = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), temp_dir, new_path)
        if err ≥ 0
            if set_permissions
                # rename worked
                new_path_mode = filemode(dirname(new_path))
                if Sys.iswindows()
                    # If this is Windows, ensure the directory mode is executable,
                    # as `filemode()` is incomplete.  Some day, that may not be the
                    # case, there exists a test that will fail if this is changes.
                    new_path_mode |= 0o111
                end
                chmod(new_path, new_path_mode)
                set_readonly(new_path)
            end
            return
        else
            # Ignore rename error if `new_path` exists.
            isdir(new_path) && return
            if retry < max_num_retries && err ∈ (Base.UV_EACCES, Base.UV_EPERM, Base.UV_EBUSY)
                sleep(sleep_amount)
                sleep_amount = min(sleep_amount * 2.0, max_sleep_amount)
                retry += 1
            else
                Base.uv_error("rename of $(repr(temp_dir)) to $(repr(new_path))", err)
            end
        end
    end
    return
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


"""
    atomic_toml_write(path::String, data; kws...)

Write TOML data to a file atomically by first writing to a temporary file and then moving it into place.
This prevents "teared" writes if the process is interrupted or if multiple processes write to the same file.

The `kws` are passed to `TOML.print`.
"""
function atomic_toml_write(path::String, data; kws...)
    dir = dirname(path)
    isempty(dir) && (dir = pwd())

    temp_path, temp_io = mktemp(dir)
    return try
        TOML.print(temp_io, data; kws...)
        close(temp_io)
        mv(temp_path, path; force = true)
    catch
        close(temp_io)
        rm(temp_path; force = true)
        rethrow()
    end
end

## ordering of UUIDs ##
if VERSION < v"1.2.0-DEV.269"  # Defined in Base as of #30947
    Base.isless(a::UUID, b::UUID) = a.value < b.value
end

function discover_repo(path::AbstractString)
    dir = abspath(path)
    stop_dir = homedir()
    depot = depots1()

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
