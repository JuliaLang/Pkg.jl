import Downloads

# Pkg.__diagnostics__()
function __diagnostics__(io::IO)
    indent = "  "

    println(io, "Packages:")
    status(; io, mode = PKGMODE_PROJECT)
    status(; io, mode = PKGMODE_MANIFEST)

    println(io, "Outdated packages:")
    status(; io, mode = PKGMODE_PROJECT,  outdated = true)
    status(; io, mode = PKGMODE_MANIFEST, outdated = true)

    println(io, "Registries:")
    Registry.status(io)

    println(io, "Pkg Servers:")
    server = pkg_server()
    if server === nothing
        pkg_server_description = "[nothing]"
    else
        pkg_server_description = server
    end
    println(io, indent, "pkg_server(): ", pkg_server_description)
    if server !== nothing
        pkg_server_url = convert(String, strip(server))::String
        if !isempty(pkg_server_url)
            debug = (type, message) -> begin
                lines = split(message, '\n')
                for line in strip.(lines)
                    if !isempty(line)
                        println(io, indent, line)
                    end
                end
            end
            Downloads.request(
                pkg_server_url;
                debug,
                throw = false,
            )
        end
    end

    return nothing
end
