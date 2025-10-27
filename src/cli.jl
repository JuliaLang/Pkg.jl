# This file is a part of Julia. License is MIT: https://julialang.org/license

# Command-line interface: `julia -m Pkg [opts] cmd [args]`, also installable as the app `pkg`.

function cli_help(io::IO)
    println(io, "pkg - command-line interface to the Julia package manager\n")
    println(io, "Full documentation available at https://pkgdocs.julialang.org/\n")

    printstyled(io, "SYNOPSIS:\n"; bold = true)
    println(io, "  pkg [opts] cmd [args]\n")
    println(io, "The commands are those of the Pkg REPL mode, `pkg help cmd` describes one of them.")
    println(io, "Several commands can be run by giving a `;` argument between them.\n")

    printstyled(io, "OPTIONS:\n"; bold = true)
    println(io, "  --project[=<path>]  Environment to operate on. Defaults to the project in the current")
    println(io, "                      directory or a parent of it, else the default environment")
    println(io, "  --offline           Work in offline mode")
    println(io, "  -h, --help          Show this message")
    println(io, "  -v, --version       Show the version of Pkg and Julia\n")

    printstyled(io, "COMMANDS:\n"; bold = true)
    commands = map(REPLMode.canonical_names()) do (name, spec)
        # include the super command in the alias, e.g. `registry up`
        super = chopsuffix(name, spec.canonical_name)
        label = spec.short_name === nothing ? name : string(name, ", ", super, spec.short_name)
        label => spec.description
    end
    width = maximum(textwidth ∘ first, commands)
    for (label, description) in commands
        print(io, "  ")
        printstyled(io, rpad(label, width); color = :cyan)
        println(io, "  ", description)
    end
    return
end

function cli_set_project(project::Union{String, Nothing})
    # An app shim pins the load path to the environment of the app
    "@" in LOAD_PATH || copy!(LOAD_PATH, Base.DEFAULT_LOAD_PATH)
    if project === nothing
        # set by `julia --project` or `JULIA_PROJECT`
        Base.ACTIVE_PROJECT[] === nothing || return
        project = "@."
    end
    path = startswith(project, "@") ? Base.load_path_expand(project) : abspath(expanduser(project))
    Base.set_active_project(path)
    return
end

function cli_commands(words::Vector{String})
    statements = [REPLMode.QString[]]
    for word in words
        if word == ";"
            push!(statements, REPLMode.QString[])
        elseif !isempty(word)
            # shell arguments are used as they are, without the lexing of the REPL mode
            push!(statements[end], REPLMode.QString(word, false))
        end
    end
    return map(filter!(!isempty, statements)) do statement
        REPLMode.Command(REPLMode.parse_statement(statement; hint = "See `pkg help` for the available commands"))
    end
end

function cli(args)
    io = stdout_f()
    project = nothing
    offline_mode = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--project"
            project = "@."
        elseif startswith(arg, "--project=")
            project = String(chopprefix(arg, "--project="))
            isempty(project) && (project = nothing)
        elseif arg == "--offline"
            offline_mode = true
        elseif arg in ("-h", "--help")
            cli_help(io)
            return 0
        elseif arg in ("-v", "--version")
            println(io, "pkg ", pkgversion(Pkg), " (julia ", VERSION, ")")
            return 0
        elseif startswith(arg, "-")
            Types.pkgerror("unknown option `$arg`, see `pkg --help`")
        else
            break
        end
        i += 1
    end
    words = String[args[j] for j in i:length(args)]
    if isempty(words) || words == ["help"] || words == ["?"]
        cli_help(io)
        return 0
    end

    cli_set_project(project)
    offline_mode && offline(true)
    for command in cli_commands(words)
        REPLMode.do_cmd(command, io)
    end
    return 0
end

function (@main)(args)
    try
        return cli(args)
    catch err
        err isa InterruptException && return 130
        # the reader of our output went away, e.g. `pkg status | head`
        err isa Base.IOError && err.code == Base.UV_EPIPE && return 141
        if err isa Types.PkgError || err isa Resolve.ResolverError
            Base.display_error(stderr_f(), ErrorException(sprint(showerror, err)), Ptr{Nothing}[])
        else
            Base.display_error(stderr_f(), err, catch_backtrace())
        end
        return 1
    end
end
