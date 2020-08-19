# This file is a part of Julia. License is MIT: https://julialang.org/license

# Content in this file is extracted from BinaryProvider.jl, see LICENSE.method

module PlatformEngines
using SHA, Logging
import ...Pkg: Pkg, TOML, pkg_server, depots1

export probe_platform_engines!, parse_7z_list, parse_tar_list, verify,
       download_verify, unpack, package, download_verify_unpack,
       list_tarball_files, list_tarball_symlinks

# To reduce method invalidation, it's best to call a logging method that
# avoids introduction of backedges.
# See https://github.com/JuliaLang/julia/pull/35714
const logging_level = isdefined(Base.CoreLogging, :_invoked_min_enabled_level) ? Base.CoreLogging._invoked_min_enabled_level : Base.CoreLogging.min_enabled_level

# In this file, we setup the `gen_download_cmd()`, `gen_unpack_cmd()` and
# `gen_package_cmd()` functions by providing methods to probe the environment
# and determine the most appropriate platform binaries to call.

"""
    gen_download_cmd(url::AbstractString, out_path::AbstractString, hdrs::AbstractString...)

Return a `Cmd` that will download resource located at `url` and store it at
the location given by `out_path`.

This method is initialized by `probe_platform_engines!()`, which should be
automatically called upon first import of `BinaryProvider`.
"""
gen_download_cmd = (url::AbstractString, out_path::AbstractString, hdrs::AbstractString...) ->
    error("Call `probe_platform_engines!()` before `gen_download_cmd()`")

"""
    gen_unpack_cmd(tarball_path::AbstractString, out_path::AbstractString;
                   excludelist::Union{AbstractString, Nothing} = nothing)

Return a `Cmd` that will unpack the given `tarball_path` into the given
`out_path`.  If `out_path` is not already a directory, it will be created.
excludlist is an optional file which contains a list of files that is not unpacked
This option is mainyl used to exclude symlinks from extraction (see: `copyderef`)

This method is initialized by `probe_platform_engines!()`, which should be
automatically called upon first import of `BinaryProvider`.
"""
gen_unpack_cmd = (tarball_path::AbstractString, out_path::AbstractString,
                  excludelist::Union{AbstractString, Nothing} = nothing) ->
    error("Call `probe_platform_engines!()` before `gen_unpack_cmd()`")

"""
    gen_package_cmd(in_path::AbstractString, tarball_path::AbstractString)

Return a `Cmd` that will package up the given `in_path` directory into a
tarball located at `tarball_path`.

This method is initialized by `probe_platform_engines!()`, which should be
automatically called upon first import of `BinaryProvider`.
"""
gen_package_cmd = (in_path::AbstractString, tarball_path::AbstractString) ->
    error("Call `probe_platform_engines!()` before `gen_package_cmd()`")

"""
    gen_list_tarball_cmd(tarball_path::AbstractString)

Return a `Cmd` that will list the files contained within the tarball located at
`tarball_path`.  The list will not include directories contained within the
tarball.

This method is initialized by `probe_platform_engines!()`.
"""
gen_list_tarball_cmd = (tarball_path::AbstractString) ->
    error("Call `probe_platform_engines!()` before `gen_list_tarball_cmd()`")

"""
    parse_tarball_listing(output::AbstractString)

Parses the result of `gen_list_tarball_cmd()` into something useful.

This method is initialized by `probe_platform_engines!()`.
"""
parse_tarball_listing = (output::AbstractString) ->
    error("Call `probe_platform_engines!()` before `parse_tarball_listing()`")

"""
    parse_symlinks(output::AbstractString)

Returns a regex to parse symlinks from tarball listings.

This method is initialized by `probe_platform_engines!()`.
"""

parse_symlinks = () ->
    error("Call `probe_platform_engines!()` before `parse_symlinks()`")

"""
    probe_cmd(cmd::Cmd; verbose::Bool = false)

Returns `true` if the given command executes successfully, `false` otherwise.
"""
function probe_cmd(cmd::Cmd; verbose::Bool = false)
    if verbose
        @info("Probing $(cmd.exec[1]) as a possibility...")
    end
    try
        success(cmd)
        if verbose
            @info("  Probe successful for $(cmd.exec[1])")
        end
        return true
    catch
        return false
    end
end

already_probed = false

"""
    probe_symlink_creation(dest::AbstractString)

Probes whether we can create a symlink within the given destination directory,
to determine whether a particular filesystem is "symlink-unfriendly".
"""
function probe_symlink_creation(dest::AbstractString)
    while !isdir(dest)
        dest = dirname(dest)
    end

    # Build arbitrary (non-existent) file path name
    link_path = joinpath(dest, "binaryprovider_symlink_test")
    while ispath(link_path)
        link_path *= "1"
    end

    loglevel = logging_level(current_logger())
    try
        disable_logging(Logging.Warn)
        symlink("foo", link_path)
        return true
    catch e
        if isa(e, Base.IOError)
            return false
        end
        rethrow(e)
    finally
        disable_logging(loglevel-1)
        rm(link_path; force=true)
    end
end

"""
    probe_platform_engines!(;verbose::Bool = false)

Searches the environment for various tools needed to download, unpack, and
package up binaries.  Searches for a download engine to be used by
`gen_download_cmd()` and a compression engine to be used by `gen_unpack_cmd()`,
`gen_package_cmd()`, `gen_list_tarball_cmd()` and `parse_tarball_listing()`.
Running this function
will set the global functions to their appropriate implementations given the
environment this package is running on.

This probing function will automatically search for download engines using a
particular ordering; if you wish to override this ordering and use one over all
others, set the `BINARYPROVIDER_DOWNLOAD_ENGINE` environment variable to its
name, and it will be the only engine searched for. For example, put:

    ENV["BINARYPROVIDER_DOWNLOAD_ENGINE"] = "fetch"

within your `~/.juliarc.jl` file to force `fetch` to be used over `curl`.  If
the given override does not match any of the download engines known to this
function, a warning will be printed and the typical ordering will be performed.

Similarly, if you wish to override the compression engine used, set the
`BINARYPROVIDER_COMPRESSION_ENGINE` environment variable to its name (e.g. `7z`
or `tar`) and it will be the only engine searched for.  If the given override
does not match any of the compression engines known to this function, a warning
will be printed and the typical searching will be performed.

If `verbose` is `true`, print out the various engines as they are searched.
"""
function probe_platform_engines!(;verbose::Bool = false)
    global already_probed
    global gen_download_cmd, gen_list_tarball_cmd, gen_package_cmd
    global gen_unpack_cmd, parse_tarball_listing, parse_symlinks

    # Quick-escape for Pkg, since we do this a lot
    if already_probed
        return
    end

    # download_engines is a list of (test_cmd, download_opts_functor)
    # The probulator will check each of them by attempting to run `$test_cmd`,
    # and if that works, will set the global download functions appropriately.
    download_engines = [
        (`curl --help`, (url, path, hdrs...) ->
            `curl -H$hdrs -C - -\# -f -o $path -L $url`),
        (`wget --help`, (url, path, hdrs...) ->
            `wget --tries=5 --header=$hdrs -c -O $path $url`),
        (`fetch --help`, (url, path, hdrs...) -> begin
            isempty(hdrs) || error("`fetch` does not support passing headers")
            `fetch -f $path $url`
        end),
        (`busybox wget --help`, (url, path, hdrs...) ->
            `busybox wget --header=$hdrs -c -O $path $url`),
    ]
    Sys.isapple() && pushfirst!(download_engines,
        (`/usr/bin/curl --help`, (url, path, hdrs...) ->
            `/usr/bin/curl -H$hdrs -C - -\# -f -o $path -L $url`))

    # 7z is rather intensely verbose.  We also want to try running not only
    # `7z` but also a direct path to the `7z.exe` bundled with Julia on
    # windows, so we create generator functions to spit back functors to invoke
    # the correct 7z given the path to the executable:
    unpack_7z = (exe7z) -> begin
        return (tarball_path, out_path, excludelist = nothing) ->
        pipeline(pipeline(`$exe7z x $(tarball_path) -y -so`,
                 `$exe7z x -si -y -ttar -o$(out_path) $(excludelist === nothing ? [] : "-x@$(excludelist)")`);
                 stdout=devnull, stderr=devnull)
    end
    package_7z = (exe7z) -> begin
        return (in_path, tarball_path) ->
            pipeline(pipeline(`$exe7z a -ttar -so a.tar "$(joinpath(".",in_path,"*"))"`,
                     `$exe7z a -si $(tarball_path)`); stdout=devnull, stderr=devnull)
    end
    list_7z = (exe7z) -> begin
        return (path; verbose = false) ->
            pipeline(`$exe7z x $path -so`, `$exe7z l -ttar -y -si $(verbose ? ["-slt"] : [])`)
    end

    # the regex at the last position is meant for parsing the symlinks from verbose 7z-listing
    # "Path = ([^\r\n]+)\r?\n" matches the symlink name which is followed by an optional return and a new line
    # (?:[^\r\n]+\r?\n)+ = a group of non-empty lines (information belonging to one file is written as a block of lines followed by an empty line)
    # more info on regex and a powerful online tester can be found at https://regex101.com
    # Symbolic Link = ([^\r\n]+)"s) matches the source filename
    # Demo 7z listing of tar files:
    # 7-Zip [64] 16.04 : Copyright (c) 1999-2016 Igor Pavlov : 2016-10-04
    #
    #
    # Listing archive:
    # --
    # Path =
    # Type = tar
    # Code Page = UTF-8
    #
    # ----------
    # Path = .
    # Folder = +
    # Size = 0
    # Packed Size = 0
    # Modified = 2018-08-22 11:44:23
    # Mode = 0rwxrwxr-x
    # User = travis
    # Group = travis
    # Symbolic Link =
    # Hard Link =

    # Path = .\lib\libpng.a
    # Folder = -
    # Size = 10
    # Packed Size = 0
    # Modified = 2018-08-22 11:44:51
    # Mode = 0rwxrwxrwx
    # User = travis
    # Group = travis
    # Symbolic Link = libpng16.a
    # Hard Link =
    #
    # Path = .\lib\libpng16.a
    # Folder = -
    # Size = 334498
    # Packed Size = 334848
    # Modified = 2018-08-22 11:44:49
    # Mode = 0rw-r--r--
    # User = travis
    # Group = travis
    # Symbolic Link =
    # Hard Link =
    gen_7z = (p) -> (unpack_7z(p), package_7z(p), list_7z(p), parse_7z_list, r"Path = ([^\r\n]+)\r?\n(?:[^\r\n]+\r?\n)+Symbolic Link = ([^\r\n]+)"s)
    compression_engines = Tuple[]

    (tmpfile, io) = mktemp()
    write(io, "Demo file for tar listing (Pkg.jl)")
    close(io)

    for tar_cmd in [`tar`, `busybox tar`]
        # try to determine the tar list format
        local symlink_parser
        try
            # Windows 10 now has a `tar` but it needs the `-f -` flag to use stdin/stdout
            # The Windows 10 tar does not work on substituted drives (`subst U: C:\Users`)
            # If a drive letter is part of the filename, then tar spits out a warning on stderr:
            # "tar: Removing leading drive letter from member names"
            # Therefore we cd to tmpdir() first
            cd(tempdir()) do
                tarListing = read(pipeline(`$tar_cmd -cf - $(basename(tmpfile))`, `$tar_cmd -tvf -`), String)
            end
            # obtain the text of the line before the filename
            m = match(Regex("((?:\\S+\\s+)+?)$tmpfile"), tarListing)[1]
            # count the number of words before the filename
            nargs = length(split(m, " "; keepempty = false))
            # build a regex for catching the symlink:
            # "^l" = line starting with l
            # "(?:\S+\s+){$nargs} = nargs non-capturing groups of many non-spaces "\S+" and many spaces "\s+"
            # "(.+?)" = a non-greedy sequence of characters: the symlink
            # "(?: -> (.+?))?" = an optional group of " -> " followed by a non-greedy sequence of characters: the source of the link
            # "\r?\$" = matches the end of line with an optional return character for some OSes
            # Demo listings
            # drwxrwxr-x  0 sabae  sabae       0 Sep  5  2018 collapse_the_symlink/
            # lrwxrwxrwx  0 sabae  sabae       0 Sep  5  2018 collapse_the_symlink/foo -> foo.1
            # -rw-rw-r--  0 sabae  sabae       0 Sep  5  2018 collapse_the_symlink/foo.1
            # lrwxrwxrwx  0 sabae  sabae       0 Sep  5  2018 collapse_the_symlink/foo.1.1 -> foo.1
            # lrwxrwxrwx  0 sabae  sabae       0 Sep  5  2018 collapse_the_symlink/broken -> obviously_broken
            #
            # drwxrwxr-x sabae/sabae       0 2018-09-05 18:19 collapse_the_symlink/
            # lrwxrwxrwx sabae/sabae       0 2018-09-05 18:19 collapse_the_symlink/foo -> foo.1
            #
            # lrwxrwxr-x 1000/1000 498007696 2009-11-27 00:14:00 link1 -> source1
            # lrw-rw-r-- 1000/1000 1359020032 2019-06-03 12:02:03 link2 -> sourcedir/source2
            #
            # now a pathological link "2009 link with blanks"
            # this can only be tracked by determining the tar format beforehand:
            # lrw-rw-r-- 0 1000 1000 1359020032 Jul  8 2009 2009 link with blanks -> target with blanks
            symlink_parser = Regex("^l(?:\\S+\\s+){$nargs}(.+?)(?: -> (.+?))?\\r?\$", "m")
        catch
            # generic expression for symlink parsing
            # this will fail, if the symlink contains space characters (which is highly improbable, though)
            # "^l.+?" = a line starting with an "l" followed by a sequence of non-greedy characters
            # \S+? the filename consisting of non-space characters, the rest as above
            symlink_parser = r"^l.+? (\S+?)(?: -> (.+?))?\r?$"m
        end
        # Some tar's aren't smart enough to auto-guess decompression method. :(
        unpack_tar = (tarball_path, out_path, excludelist = nothing) -> begin
            Jjz = "z"
            if endswith(tarball_path, ".xz")
                Jjz = "J"
            elseif endswith(tarball_path, ".bz2")
                Jjz = "j"
            end
            return `$tar_cmd --no-same-owner -mx$(Jjz)f $(tarball_path) -C$(out_path) $(excludelist === nothing ? [] : "-X$(excludelist)")`
        end
        package_tar = (in_path, tarball_path) -> begin
            Jjz = "z"
            if endswith(tarball_path, ".xz")
                Jjz = "J"
            elseif endswith(tarball_path, ".bz2")
                Jjz = "j"
            end
            return `$tar_cmd -c$(Jjz)f $tarball_path -C$(in_path) .`
        end
        list_tar = (in_path; verbose = false) -> begin
            Jjz = "z"
            if endswith(in_path, ".xz")
                Jjz = "J"
            elseif endswith(in_path, ".bz2")
                Jjz = "j"
            end
            return `$tar_cmd $(verbose ? "-t$(Jjz)vf" : "-t$(Jjz)f") $in_path`
        end
        push!(compression_engines, (
            `$tar_cmd --help`,
            unpack_tar,
            package_tar,
            list_tar,
            parse_tar_list,
            symlink_parser
        ))
    end
    rm(tmpfile, force = true)

    # For windows, we need to tweak a few things, as the tools available differ
    @static if Sys.iswindows()
        # For download engines, we will most likely want to use powershell.
        # Let's generate a functor to return the necessary powershell magics
        # to download a file, given a path to the powershell executable
        psh_download = (psh_path) -> begin
            return (url, path, hdrs...) -> begin
                webclient_code = """
                [System.Net.ServicePointManager]::SecurityProtocol =
                    [System.Net.SecurityProtocolType]::Tls12;
                \$webclient = (New-Object System.Net.Webclient);
                \$webclient.UseDefaultCredentials = \$true;
                \$webclient.Proxy.Credentials = \$webclient.Credentials;
                \$webclient.Headers.Add("user-agent", \"Pkg.jl (https://github.com/JuliaLang/Pkg.jl)\");
                """
                for hdr in hdrs
                    key, val = split(hdr, r":\s*", limit=2)
                    webclient_code *= """
                    \$webclient.Headers.Add($(repr(key)), $(repr(val)));
                    """
                end
                webclient_code *= """
                \$webclient.DownloadFile(\"$url\", \"$path\")
                """
                replace(webclient_code, "\n" => " ")
                return `$psh_path -NoProfile -Command "$webclient_code"`
            end
        end

        # We want to search both the `PATH`, and the direct path for powershell
        psh_path = joinpath(get(ENV, "SYSTEMROOT", "C:\\Windows"), "System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        prepend!(download_engines, [
            (`$psh_path -Command ""`, psh_download(psh_path))
        ])
        prepend!(download_engines, [
            (`powershell -Command ""`, psh_download(`powershell`))
        ])

        # We greatly prefer `7z` as a compression engine on Windows
        prepend!(compression_engines, [(`7z --help`, gen_7z("7z")...)])

        # For purposes of in-buildtree execution, we look in `bin`
        exe7z = joinpath(Sys.BINDIR, "7z.exe")
        prepend!(compression_engines, [(`$exe7z --help`, gen_7z(exe7z)...)])

        # But most commonly, we'll find `7z` sitting in `libexec`, bundled with Julia
        exe7z = joinpath(Sys.BINDIR, "..", "libexec", "7z.exe")
        prepend!(compression_engines, [(`$exe7z --help`, gen_7z(exe7z)...)])
    end

    # Allow environment override
    if haskey(ENV, "BINARYPROVIDER_DOWNLOAD_ENGINE")
        engine = ENV["BINARYPROVIDER_DOWNLOAD_ENGINE"]
        es = split(engine)
        dl_ngs = filter(e -> e[1].exec[1:length(es)] == es, download_engines)
        if isempty(dl_ngs)
            all_ngs = join([d[1].exec[1] for d in download_engines], ", ")
            warn_msg  = "Ignoring BINARYPROVIDER_DOWNLOAD_ENGINE as its value "
            warn_msg *= "of `$(engine)` doesn't match any known valid engines."
            warn_msg *= " Try one of `$(all_ngs)`."
            @warn(warn_msg)
        else
            # If BINARYPROVIDER_DOWNLOAD_ENGINE matches one of our download engines,
            # then restrict ourselves to looking only at that engine
            download_engines = dl_ngs
        end
    end

    if haskey(ENV, "BINARYPROVIDER_COMPRESSION_ENGINE")
        engine = ENV["BINARYPROVIDER_COMPRESSION_ENGINE"]
        es = split(engine)
        comp_ngs = filter(e -> e[1].exec[1:length(es)] == es, compression_engines)
        if isempty(comp_ngs)
            all_ngs = join([c[1].exec[1] for c in compression_engines], ", ")
            warn_msg  = "Ignoring BINARYPROVIDER_COMPRESSION_ENGINE as its "
            warn_msg *= "value of `$(engine)` doesn't match any known valid "
            warn_msg *= "engines. Try one of `$(all_ngs)`."
            @warn(warn_msg)
        else
            # If BINARYPROVIDER_COMPRESSION_ENGINE matches one of our download
            # engines, then restrict ourselves to looking only at that engine
            compression_engines = comp_ngs
        end
    end

    download_found = false
    compression_found = false

    if verbose
        @info("Probing for download engine...")
    end

    # Search for a download engine
    for (test, dl_func) in download_engines
        if probe_cmd(`$test`; verbose=verbose)
            # Set our download command generator
            gen_download_cmd = (url, out_path, hdrs...) -> begin
                isdefined(Base, :download_url) && (url = Base.download_url(url))
                dl_func(url, out_path, hdrs...)
            end
            download_found = true

            if verbose
                @info("Found download engine $(test.exec[1])")
            end
            break
        end
    end

    if verbose
        @info("Probing for compression engine...")
    end

    # Search for a compression engine
    for (test, unpack, package, list, parse, symlink) in compression_engines
        if probe_cmd(`$test`; verbose=verbose)
            # Set our compression command generators
            gen_unpack_cmd = unpack
            gen_package_cmd = package
            gen_list_tarball_cmd = list
            parse_tarball_listing = parse
            parse_symlinks = () -> symlink

            if verbose
                @info("Found compression engine $(test.exec[1])")
            end

            compression_found = true
            break
        end
    end

    # Build informative error messages in case things go sideways
    errmsg = ""
    if !download_found
        errmsg *= "No download engines found. We looked for: "
        errmsg *= join([d[1].exec[1] for d in download_engines], ", ")
        errmsg *= ". Install one and ensure it  is available on the path.\n"
    end

    if !compression_found
        errmsg *= "No compression engines found. We looked for: "
        errmsg *= join([c[1].exec[1] for c in compression_engines], ", ")
        errmsg *= ". Install one and ensure it is available on the path.\n"
    end

    # Error out if we couldn't find something
    if !download_found || !compression_found
        error(errmsg)
    end
    already_probed = true
end

"""
    parse_7z_list(output::AbstractString)

Given the output of `7z l`, parse out the listed filenames.  This funciton used
by  `list_tarball_files`.
"""
function parse_7z_list(output::AbstractString)
    lines = [chomp(l) for l in split(output, "\n")]

    # If we didn't get anything, complain immediately
    if isempty(lines)
        return []
    end

    # Remove extraneous "\r" for windows platforms
    for idx in 1:length(lines)
        if endswith(lines[idx], '\r')
            lines[idx] = lines[idx][1:end-1]
        end
    end

    # Find index of " Name".  Have to `collect()` as `findfirst()` doesn't work with
    # generators: https://github.com/JuliaLang/julia/issues/16884
    header_row = findfirst(collect(occursin(" Name", l) && occursin(" Attr", l) for l in lines))
    name_idx = findfirst("Name", lines[header_row])[1]
    attr_idx = findfirst("Attr", lines[header_row])[1] - 1

    # Filter out only the names of files, ignoring directories
    lines = [l[name_idx:end] for l in lines if length(l) > name_idx && l[attr_idx] != 'D']
    if isempty(lines)
        return []
    end

    # Extract within the bounding lines of ------------
    bounds = [i for i in 1:length(lines) if all([c for c in lines[i]] .== Ref('-'))]
    lines = lines[bounds[1]+1:bounds[2]-1]

    # Eliminate `./` prefix, if it exists
    for idx in 1:length(lines)
        if startswith(lines[idx], "./") || startswith(lines[idx], ".\\")
            lines[idx] = lines[idx][3:end]
        end
    end

    return lines
end

"""
    parse_7z_list(output::AbstractString)

Given the output of `tar -t`, parse out the listed filenames.  This function
used by `list_tarball_files`.
"""
function parse_tar_list(output::AbstractString)
    lines = [chomp(l) for l in split(output, "\n")]
    for idx in 1:length(lines)
        while endswith(lines[idx], '\r')
            lines[idx] = lines[idx][1:end-1]
        end
    end

    # Drop empty lines and and directories
    lines = [l for l in lines if !isempty(l) && !endswith(l, '/')]

    # Eliminate `./` prefix, if it exists
    for idx in 1:length(lines)
        if startswith(lines[idx], "./") || startswith(lines[idx], ".\\")
            lines[idx] = lines[idx][3:end]
        end
    end

    # make sure paths are always returned in the system's default way
    return Sys.iswindows() ? replace.(lines, ['/' => '\\']) : lines
end

is_secure_url(url::AbstractString) =
    occursin(r"^(https://|\w+://(127\.0\.0\.1|localhost)(:\d+)?($|/))"i, url)

function get_server_dir(url::AbstractString, server=pkg_server())
    server === nothing && return
    url == server || startswith(url, "$server/") || return
    m = match(r"^\w+://([^\\/]+)(?:$|/)", server)
    if m === nothing
        @warn "malformed Pkg server value" server
        return
    end
    joinpath(depots1(), "servers", m.captures[1])
end

const AUTH_ERROR_HANDLERS = []

function handle_auth_error(url, err; verbose::Bool = false)
    handled, should_retry = false, false
    for (scheme, handler) in AUTH_ERROR_HANDLERS
        occursin(scheme, url) || continue
        handled, should_retry = handler(url, pkg_server(), err)
        handled && break
    end
    handled && should_retry && return get_auth_header(url; verbose = verbose)
    return nothing
end

"""
    register_auth_error_handler(urlscheme::Union{AbstractString, Regex}, f)

Registers `f` as the topmost handler for failures in package server authentication.

A handler is only invoked if `occursin(urlscheme, url)` is true (where `url` is the URL Pkg
is currently trying to download.)

`f` must be a function that takes three input arguments `(url, pkgserver, err)`, where `url` is the
URL currently being downloaded, `pkgserver = Pkg.pkg_server()` the current package server, and
`err` is one of `no-auth-file`, `insecure-connection`, `malformed-file`, `no-access-token`,
`no-refresh-key` or `insecure-refresh-url`.

The handler `f` needs to return a tuple of `Bool`s `(handled, should_retry)`. If `handled` is `false`,
the next handler in the stack will be called, otherwise handling terminates; `get_auth_header` is called again if `should_retry`
is `true`.

`register_auth_error_handler` returns a zero-arg function that can be called to deregister the handler.
"""
function register_auth_error_handler(urlscheme::Union{AbstractString, Regex}, f)
    unique!(pushfirst!(AUTH_ERROR_HANDLERS, urlscheme => f))
    return () -> deregister_auth_error_handler(urlscheme, f)
end

"""
    deregister_auth_error_handler(urlscheme::Union{AbstractString, Regex}, f)

Removes `f` from the stack of authentication error handlers.
"""
function deregister_auth_error_handler(urlscheme::Union{AbstractString, Regex}, f)
    filter!(handler -> handler !== (urlscheme => f), AUTH_ERROR_HANDLERS)
    return nothing
end

function get_auth_header(url::AbstractString; verbose::Bool = false)
    server_dir = get_server_dir(url)
    server_dir === nothing && return
    auth_file = joinpath(server_dir, "auth.toml")
    isfile(auth_file) || return handle_auth_error(url, "no-auth-file"; verbose=verbose)
    # TODO: check for insecure auth file permissions
    if !is_secure_url(url)
        @warn "refusing to send auth info over insecure connection" url=url
        return handle_auth_error(url, "insecure-connection"; verbose=verbose)
    end
    # parse the auth file
    auth_info = try
        TOML.parsefile(auth_file)
    catch err
        @error "malformed auth file" file=auth_file err=err
        return handle_auth_error(url, "malformed-file"; verbose=verbose)
    end
    # check for an auth token
    if !haskey(auth_info, "access_token")
        @warn "auth file without access_token field" file=auth_file
        return handle_auth_error(url, "no-access-token"; verbose=verbose)
    end
    auth_header = "Authorization: Bearer $(auth_info["access_token"])"
    # handle token expiration and refresh
    expires_at = Inf
    if haskey(auth_info, "expires_at")
        expires_at = min(expires_at, auth_info["expires_at"]::Integer)
    end
    if haskey(auth_info, "expires_in")
        expires_at = min(expires_at, mtime(auth_file) + auth_info["expires_in"]::Integer)
    end
    # if token is good until ten minutes from now, use it
    time_now = time()
    if expires_at ≥ time_now + 10*60 # ten minutes
        return auth_header
    end
    if !haskey(auth_info, "refresh_url") || !haskey(auth_info, "refresh_token")
        if expires_at ≤ time_now
            @warn "expired auth without refresh keys" file=auth_file
        end
        # try it anyway since we can't refresh
        return something(handle_auth_error(url, "no-refresh-key"; verbose=verbose), auth_header)
    end
    refresh_url = auth_info["refresh_url"]
    if !is_secure_url(refresh_url)
        @warn "ignoring insecure auth refresh URL" url=refresh_url
        return something(handle_auth_error(url, "insecure-refresh-url"; verbose=verbose), auth_header)
    end
    verbose && @info "Refreshing expired auth token..." file=auth_file
    tmp = tempname()
    refresh_auth = "Authorization: Bearer $(auth_info["refresh_token"])"
    try download(refresh_url, tmp, auth_header=refresh_auth, verbose=verbose)
    catch err
        @warn "token refresh failure" file=auth_file url=refresh_url err=err
        rm(tmp, force=true)
        return handle_auth_error(url, "token-refresh-failed"; verbose=verbose)
    end
    auth_info = try TOML.parsefile(tmp)
    catch err
        @warn "discarding malformed auth file" url=refresh_url err=err
        rm(tmp, force=true)
        return something(handle_auth_error(url, "malformed-file"; verbose=verbose), auth_header)
    end
    if !haskey(auth_info, "access_token")
        if haskey(auth_info, "refresh_token")
            auth_info["refresh_token"] = "*"^64
        end
        @warn "discarding auth file without access token" auth=auth_info
        rm(tmp, force=true)
        return something(handle_auth_error(url, "no-access-token"; verbose=verbose), auth_header)
    end
    if haskey(auth_info, "expires_in")
        expires_in = auth_info["expires_in"]
        if expires_in isa Number
            expires_at = floor(Int64, time_now + expires_in)
            # overwrite expires_at (avoids clock skew issues)
            auth_info["expires_at"] = expires_at
        end
    end
    let auth_info = auth_info
        open(tmp, write=true) do io
            TOML.print(io, auth_info, sorted=true)
        end
    end
    mv(tmp, auth_file, force=true)
    return "Authorization: Bearer $(auth_info["access_token"])"
end

# based on information in this post:
# https://github.community/t5/GitHub-Actions/Have-the-CI-environment-variable-set-by-default/m-p/32358/highlight/true#M1097
const CI_VARIABLES = [
    "APPVEYOR",
    "CI",
    "CI_SERVER",
    "CIRCLECI",
    "CONTINUOUS_INTEGRATION",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "JULIA_CI",
    "JULIA_PKGEVAL",
    "JULIA_REGISTRYCI_AUTOMERGE",
    "TF_BUILD",
    "TRAVIS",
]

function get_metadata_headers(url::AbstractString)
    headers = String[]
    server = pkg_server()
    server_dir = get_server_dir(url, server)
    server_dir === nothing && return headers
    push!(headers, "Julia-Pkg-Protocol: 1.0")
    push!(headers, "Julia-Version: $VERSION")
    system = Pkg.BinaryPlatforms.triplet(Pkg.BinaryPlatforms.platform_key_abi())
    push!(headers, "Julia-System: $system")
    ci_info = String[]
    for var in CI_VARIABLES
        val = get(ENV, var, nothing)
        state = val === nothing ? "n" :
            lowercase(val) in ("true", "t", "1", "yes", "y") ? "t" :
            lowercase(val) in ("false", "f", "0", "no", "n") ? "f" : "o"
        push!(ci_info, "$var=$state")
    end
    push!(headers, "Julia-CI-Variables: "*join(ci_info, ';'))
    push!(headers, "Julia-Interactive: $(isinteractive())")
    return headers
end

"""
    download(
        url::AbstractString,
        dest::AbstractString;
        verbose::Bool = false,
        auth_header::Union{AbstractString, Nothing} = nothing,
    )

Download file located at `url`, store it at `dest`, continuing if `dest`
already exists and the server and download engine support it.
"""
function download(
    url::AbstractString,
    dest::AbstractString;
    verbose::Bool = false,
    auth_header::Union{AbstractString, Nothing} = nothing,
)
    headers = String[]
    if auth_header === nothing
        auth_header = get_auth_header(url, verbose=verbose)
    end
    if auth_header !== nothing
        push!(headers, auth_header)
    end
    for header in get_metadata_headers(url)
        push!(headers, header)
    end
    download_cmd = gen_download_cmd(url, dest, headers...)
    if verbose
        # @info("Downloading $(url) to $(dest)...")
    end
    try
        run(download_cmd, (devnull, verbose ? stdout : devnull, verbose ? stderr : devnull))
    catch e
        if isa(e, InterruptException)
            rethrow()
        end
        error("Could not download $(url) to $(dest):\n$(e)")
    end
end

"""
    download_verify(
        url::AbstractString,
        hash::Union{AbstractString, Nothing},
        dest::AbstractString;
        verbose::Bool = false,
        force::Bool = false,
        quiet_download::Bool = false,
    )

Download file located at `url`, verify it matches the given `hash`, and throw
an error if anything goes wrong.  If `dest` already exists, just verify it. If
`force` is set to `true`, overwrite the given file if it exists but does not
match the given `hash`.

This method returns `true` if the file was downloaded successfully, `false`
if an existing file was removed due to the use of `force`, and throws an error
if `force` is not set and the already-existent file fails verification, or if
`force` is set, verification fails, and then verification fails again after
redownloading the file.

If `quiet_download` is set to `false`, this method will print to
stdout when downloading a new file.  If it is set to `true` (default, and `verbose` is
set to `false`) the downloading process will be completely silent.  If
`verbose` is set to `true`, messages about integrity verification will be
printed in addition to messages regarding downloading.
"""
function download_verify(
    url::AbstractString,
    hash::Union{AbstractString, Nothing},
    dest::AbstractString;
    verbose::Bool = false,
    force::Bool = false,
    quiet_download::Bool = false,
)
    # Whether the file existed in the first place
    file_existed = false

    if isfile(dest)
        file_existed = true
        if verbose
            @info("Destination file $(dest) already exists, verifying...")
        end

        # verify download, if it passes, return happy.  If it fails, (and
        # `force` is `true`, re-download!)
        if hash !== nothing && verify(dest, hash; verbose=verbose)
            return true
        elseif !force
            error("Verification failed, not overwriting $(dest)")
        end
    end

    # Make sure the containing folder exists
    mkpath(dirname(dest))

    # Download the file, optionally continuing
    download(url, dest; verbose=verbose || !quiet_download)
    if hash !== nothing && !verify(dest, hash; verbose=verbose)
        # If the file already existed, it's possible the initially downloaded chunk
        # was bad.  If verification fails after downloading, auto-delete the file
        # and start over from scratch.
        if file_existed
            if verbose
                @info("Continued download didn't work, restarting from scratch")
            end
            Base.rm(dest; force=true)

            # Download and verify from scratch
            download(url, dest; verbose=verbose || !quiet_download)
            if hash !== nothing && !verify(dest, hash; verbose=verbose)
                error("Verification failed")
            end
        else
            # If it didn't verify properly and we didn't resume, something is
            # very wrong and we must complain mightily.
            error("Verification failed")
        end
    end

    # If the file previously existed, this means we removed it (due to `force`)
    # and redownloaded, so return `false`.  If it didn't exist, then this means
    # that we successfully downloaded it, so return `true`.
    return !file_existed
end

function get_tarball_contents(path::AbstractString; verbose_tar::Bool = false)
    if !isfile(path)
        error("Tarball path $(path) does not exist")
    end

    # Run the listing command, then parse the output
    cmd = gen_list_tarball_cmd(path; verbose=verbose_tar)
    output = try
        out_pipe = Pipe()
        P = run(pipeline(cmd; stdout=out_pipe); wait=false)
        close(out_pipe.in)
        output = @async String(read(out_pipe))
		wait(P)
		fetch(output)
    catch
        error("Could not list contents of tarball $(path)")
    end

    return output
end

"""
    list_tarball_files(path::AbstractString; verbose::Bool = false)

Given a `.tar.gz` filepath, list the compressed contents.
"""
function list_tarball_files(tarball_path::AbstractString)
    return parse_tarball_listing(get_tarball_contents(tarball_path))
end

"""
    list_tarball_symlinks(path::AbstractString; verbose::Bool = false)

Given a `.tar.gz` filepath, return a dictionary of symlinks in the archive
"""
function list_tarball_symlinks(tarball_path::AbstractString)
    output = get_tarball_contents(tarball_path; verbose_tar = true)
    mm = [m.captures for m in eachmatch(parse_symlinks(), output)]
    symlinks = [String(m[1]) => joinpath(dirname(m[1]), m[2]) for m in mm if m[1] !== nothing && m[2] !== nothing]
    return symlinks
end


"""
    unpack(tarball_path::AbstractString, dest::AbstractString;
           verbose::Bool = false)

Unpack tarball located at file `tarball_path` into directory `dest`.
"""
function unpack(tarball_path::AbstractString, dest::AbstractString;
                verbose::Bool = false)
    # unpack into dest
    mkpath(dest)

    # The user can force usage of our dereferencing workarounds for filesystems
    # that don't support symlinks, but it is also autodetected.
    copyderef = (get(ENV, "BINARYPROVIDER_COPYDEREF", "") == "true") || !probe_symlink_creation(dest)

    # If we should "copyderef" what we do is to unpack everything except symlinks
    # then copy the sources of the symlinks to the destination of the symlink instead.
    # This is to work around filesystems that are mounted (such as SMBFS filesystems)
    # that do not support symlinks.
    excludelist = nothing

    if copyderef
        symlinks = list_tarball_symlinks(tarball_path)
        if length(symlinks) > 0
            (excludelist, io) = mktemp()
            write(io, join([s[1] for s in symlinks], "\n"))
            close(io)
        end
    end

    cmd = gen_unpack_cmd(tarball_path, dest, excludelist)
    try
        run(cmd)
    catch e
        if isa(e, InterruptException)
            rethrow()
        end
        error("Could not unpack $(tarball_path) into $(dest)")
    end

    if copyderef && length(symlinks) > 0
        @info("Replacing symlinks in tarball by their source files ...\n" * join(string.(symlinks),"\n"))
        for s in symlinks
            sourcefile = normpath(joinpath(dest, s[2]))
            destfile   = normpath(joinpath(dest, s[1]))

            if isfile(sourcefile)
                cp(sourcefile, destfile, force = true)
            else
                @warn("Symlink source '$sourcefile' does not exist!")
            end
        end
        rm(excludelist; force = true)
    end
end

"""
    package(src_dir::AbstractString, tarball_path::AbstractString)

Compress `src_dir` into a tarball located at `tarball_path`.
"""
function package(src_dir::AbstractString, tarball_path::AbstractString)
    # For now, use environment variables to set the gzip compression factor to
    # level 9, eventually there will be new enough versions of tar everywhere
    # to use -I 'gzip -9', or even to switch over to .xz files.
    withenv("GZIP" => "-9") do
        cmd = gen_package_cmd(src_dir, tarball_path)
        try
            run(cmd, (devnull, devnull, devnull))
        catch e
            if isa(e, InterruptException)
                rethrow()
            end
            error("Could not package $(src_dir) into $(tarball_path)")
        end
    end
end

"""
    download_verify_unpack(
        url::AbstractString,
        hash::Union{AbstractString, Nothing},
        dest::AbstractString;
        tarball_path = nothing,
        ignore_existence::Bool = false,
        force::Bool = false,
        verbose::Bool = false,
        quiet_download::Bool = false,
    )

Helper method to download tarball located at `url`, verify it matches the
given `hash`, then unpack it into folder `dest`.  In general, the method
`install()` should be used to download and install tarballs into a `Prefix`;
this method should only be used if the extra functionality of `install()` is
undesired.

If `tarball_path` is specified, the given `url` will be downloaded to
`tarball_path`, and it will not be removed after downloading and verification
is complete.  If it is not specified, the tarball will be downloaded to a
temporary location, and removed after verification is complete.

If `force` is specified, a verification failure will cause `tarball_path` to be
deleted (if it exists), the `dest` folder to be removed (if it exists) and the
tarball to be redownloaded and reverified.  If the verification check is failed
a second time, an exception is raised.  If `force` is not specified, a
verification failure will result in an immediate raised exception.

If `ignore_existence` is set, the tarball is unpacked even if the destination
directory already exists.

Returns `true` if a tarball was actually unpacked, `false` if nothing was
changed in the destination prefix.
"""
function download_verify_unpack(
    url::AbstractString,
    hash::Union{AbstractString, Nothing},
    dest::AbstractString;
    tarball_path = nothing,
    ignore_existence::Bool = false,
    force::Bool = false,
    verbose::Bool = false,
    quiet_download::Bool = false,
)
    # First, determine whether we should keep this tarball around
    remove_tarball = false
    if tarball_path === nothing
        remove_tarball = true

        function url_ext(url)
            url = basename(url)

            # Chop off urlparams
            qidx = findfirst(isequal('?'), url)
            if qidx !== nothing
                url = url[1:qidx]
            end

            # Try to detect extension
            dot_idx = findlast(isequal('.'), url)
            if dot_idx === nothing
                return nothing
            end

            return url[dot_idx+1:end]
        end

        # If extension of url contains a recognized extension, use it, otherwise use ".gz"
        ext = url_ext(url)
        if !(ext in ["tar", "gz", "tgz", "bz2", "xz"])
            ext = "gz"
        end

        # Work around windows limitations regarding tempname()
        tarball_path = "$(tempname())-download.$(ext)"
        tries = 0
        while isfile(tarball_path) && tries < 100
            tarball_path = "$(tempname())-download.$(ext)"
            tries += 1
        end
        if tries >= 100
            error("Unable to generate unused tempname! Clean up your temporary folder $(dirname(tempname())) and try again.")
        end
    end

    # Download the tarball; if it already existed and we needed to remove it
    # then we should remove the unpacked path as well
    should_delete = !download_verify(url, hash, tarball_path;
                                     force=force, verbose=verbose, quiet_download=quiet_download)
    if should_delete
        if verbose
            @info("Removing dest directory $(dest) as source tarball changed")
        end
        Base.rm(dest; recursive=true, force=true)
    end

    # If the destination path already exists, don't bother to unpack
    if !ignore_existence && isdir(dest)
        if verbose
            @info("Destination directory $(dest) already exists, returning")
        end

        # Signify that we didn't do any unpacking
        return false
    end

    try
        if verbose
            @info("Unpacking $(tarball_path) into $(dest)...")
        end
        unpack(tarball_path, dest; verbose=verbose)
    finally
        if remove_tarball
            Base.rm(tarball_path)
            # Remove cached tarball hash, if it exists.
            Base.rm(string(tarball_path, ".sha256"); force=true)
        end
    end

    # Signify that we did some unpacking!
    return true
end


"""
    verify(path::AbstractString, hash::AbstractString;
           verbose::Bool = false, report_cache_status::Bool = false)

Given a file `path` and a `hash`, calculate the SHA256 of the file and compare
it to `hash`.  This method caches verification results in a `"\$(path).sha256"`
file to accelerate reverification of files that have been previously verified.
If no `".sha256"` file exists, a full verification will be done and the file
will be created, with the calculated hash being stored within the `".sha256"`
file.  If a `".sha256"` file does exist, its contents are checked to ensure
that the hash contained within matches the given `hash` parameter, and its
modification time shows that the file located at `path` has not been modified
since the last verification.

If `report_cache_status` is set to `true`, then the return value will be a
`Symbol` giving a granular status report on the state of the hash cache, in
addition to the `true`/`false` signifying whether verification completed
successfully.
"""
function verify(path::AbstractString, hash::AbstractString; verbose::Bool = false,
                report_cache_status::Bool = false, hash_path::AbstractString="$(path).sha256")

    # Check hash string format
    if !occursin(r"^[0-9a-f]{64}$"i, hash)
        msg = "Hash value must be 64 hexadecimal characters (256 bits), "
        if !isascii(hash)
            msg *= "given hash value is non-ASCII"
        elseif occursin(r"^[0-9a-f]*$"i, hash)
            msg *= "given hash value has the wrong length ($(length(hash)))"
        else
            msg *= "given hash value contains non-hexadecimal characters"
        end
        msg *= ": $(repr(hash))"
        error(msg)
    end
    hash = lowercase(hash)

    # Check to see if the hash cache is consistent
    status = :hash_consistent

    # First, it must exist
    if isfile(hash_path)
        # Next, it must contain the same hash as what we're verifying against
        if read(hash_path, String) == hash
            # Next, it must be no older than the actual path
            if stat(hash_path).mtime >= stat(path).mtime
                # If all of that is true, then we're good!
                if verbose
                    @info("Hash cache is consistent, returning true")
                end
                status = :hash_cache_consistent

                # If we're reporting our status, then report it!
                if report_cache_status
                    return true, status
                else
                    return true
                end
            else
                if verbose
                    @info("File has been modified, hash cache invalidated")
                end
                status = :file_modified
            end
        else
            if verbose
                @info("Verification hash mismatch, hash cache invalidated")
            end
            status = :hash_cache_mismatch
        end
    else
        if verbose
            @info("No hash cache found")
        end
        status = :hash_cache_missing
    end

    calc_hash = open(path) do file
        bytes2hex(sha256(file))
    end
    @assert occursin(r"^[0-9a-f]{64}$", calc_hash)

    if verbose
        @info("Calculated hash $calc_hash for file $path")
    end

    if calc_hash != hash
        msg  = "Hash Mismatch!\n"
        msg *= "  Expected sha256:   $hash\n"
        msg *= "  Calculated sha256: $calc_hash"
        @error(msg)
        if report_cache_status
            return false, :hash_mismatch
        else
            return false
        end
    end

    # Try to save a hash cache if everything worked out fine
    try
        open(hash_path, "w") do file
            write(file, hash)
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end

        if verbose
            @warn("Unable to create hash cache file $(hash_path)")
        end
    end

    if report_cache_status
        return true, status
    else
        return true
    end
end

end # module PlatformEngines
