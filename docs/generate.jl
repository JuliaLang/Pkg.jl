# This file is a part of Julia. License is MIT: https://julialang.org/license

## generate repl-docs ##

function generate(io, command)
    cmd_nospace = replace(command, " " => "-")
    println(io, """
    ```@raw html
    <article class="docstring">
        <header>
            <a class="docstring-binding" id="repl-$(cmd_nospace)" href="#repl-$(cmd_nospace)">
                <code>$(command)</code>
            </a>
            —
            <span class="docstring-category">REPL command</span>
        </header>
        <section>
    ```
    ```@eval
    using Pkg
    Dict(Pkg.REPLMode.canonical_names())["$(command)"].help
    ```
    ```@raw html
        </section>
    </article>
    ```
    """)
end
function generate()
    io = IOBuffer()
    println(io, """
        # [**11.** REPL Mode Reference](@id REPL-Mode-Reference)

        This section describes available commands in the Pkg REPL.
        The Pkg REPL mode is mostly meant for interactive use,
        and for non-interactive use it is recommended to use the
        functional API, see [API Reference](@ref API-Reference).
        """)
    # list commands
    println(io, "## `package` commands")
    foreach(command -> generate(io, command), ["add", "build", "compat", "develop", "free", "generate", "pin", "remove", "test", "update"])
    println(io, "## `registry` commands")
    foreach(command -> generate(io, command), ["registry add", "registry remove", "registry status", "registry update"])
    println(io, "## Other commands")
    foreach(command -> generate(io, command), ["activate", "gc", "help", "instantiate", "precompile", "resolve", "status"])
    # write to file
    write(joinpath(@__DIR__, "src", "repl.md"), seekstart(io))
    return
end

generate()
