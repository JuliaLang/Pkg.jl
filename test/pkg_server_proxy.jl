# This file is a part of Julia. License is MIT: https://julialang.org/license

# A local caching proxy in front of the pkg server, shared by every test
# process: the pkg-server protocol's content-addressed resources (registry,
# package and artifact tarballs) are immutable, so each one is fetched from
# the upstream server at most once per cache lifetime and served locally
# afterwards. This keeps network traffic low even though the tests install
# packages into many fresh depots, from many parallel workers. The
# `/registries` index is snapshotted once, which also pins one consistent
# registry state for the whole test run.
module PkgServerProxy

using Sockets
import Downloads

# the immutable content-addressed pkg-server resources
const RESOURCE_RE = r"^/(?:registry/[0-9a-f-]{36}|package/[0-9a-f-]{36}|artifact)/[0-9a-f]{40}$"

function handle_connection(sock, upstream::String, cache_dir::String, registries::Vector{UInt8})
    try
        request = readline(sock)
        while !isempty(readline(sock)) # drain headers
        end
        parts = split(request)
        method = isempty(parts) ? "" : parts[1]
        target = length(parts) >= 2 ? String(parts[2]) : ""
        body = nothing
        if target == "/registries"
            body = registries
        elseif occursin(RESOURCE_RE, target)
            file = joinpath(cache_dir, split(target, '/'; keepempty = false)...)
            if !isfile(file)
                mkpath(dirname(file))
                tmp = tempname(dirname(file)) # same filesystem, for an atomic move
                try
                    Downloads.download(upstream * target, tmp)
                    mv(tmp, file; force = true) # concurrent misses overwrite with identical content
                catch
                    rm(tmp; force = true) # upstream 404 etc: serve 404 below
                end
            end
            isfile(file) && (body = read(file))
        end
        if body === nothing
            write(sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else
            write(sock, "HTTP/1.1 200 OK\r\nContent-Length: $(length(body))\r\nConnection: close\r\n\r\n")
            method == "HEAD" || write(sock, body)
        end
    catch
        # broken pipe etc. — client went away, nothing to do
    finally
        close(sock)
    end
    return
end

"""
    start!(; upstream, cache_dir) -> url or nothing

Start the caching proxy and point `JULIA_PKG_SERVER` at it, for this process
and everything it spawns (test workers, subprocesses started by tests).
Returns `nothing` (leaving the environment untouched) when no pkg server is
in use or the upstream one is unreachable.
"""
function start!(; upstream::Union{AbstractString, Nothing}, cache_dir::String)
    upstream === nothing && return nothing
    upstream = String(rstrip(upstream, '/'))
    registries = try
        buf = IOBuffer()
        Downloads.download(upstream * "/registries", buf)
        take!(buf)
    catch err
        @warn "Could not fetch registry index, tests will download directly" upstream err
        return nothing
    end
    mkpath(cache_dir)
    port, server = Sockets.listenany(Sockets.localhost, 40000)
    @async while isopen(server)
        sock = try
            accept(server)
        catch
            break
        end
        @async handle_connection(sock, upstream, cache_dir, registries)
    end
    atexit(() -> close(server))
    url = "http://127.0.0.1:$(Int(port))"
    ENV["JULIA_PKG_SERVER"] = url
    return url
end

end # module
