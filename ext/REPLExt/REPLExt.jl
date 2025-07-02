module REPLExt

if Base.get_bool_env("JULIA_PKG_DISALLOW_PKG_PRECOMPILATION", false) == true
    error("Precompililing Pkg extension REPLExt is disallowed. JULIA_PKG_DISALLOW_PKG_PRECOMPILATION=$(ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"])")
end

using Dates: Dates
using Markdown: Markdown
using UUIDs: UUIDs, UUID

import REPL
import .REPL: LineEdit, TerminalMenus

import Pkg
import .Pkg: linewrap, pathrepr, compat, can_fancyprint, printpkgstyle, PKGMODE_PROJECT
using .Pkg: Types, Operations, API, Registry, Resolve, REPLMode, safe_realpath

using .REPLMode: Statement, CommandSpec, Command, prepare_cmd, tokenize, core_parse, SPECS, api_options, parse_option, api_options, is_opt, wrap_option

using .Types: Context, PkgError, pkgerror, EnvCache


include("completions.jl")
include("compat.jl")

######################
# REPL mode creation #
######################

struct PkgCompletionProvider <: LineEdit.CompletionProvider end

function LineEdit.complete_line(c::PkgCompletionProvider, s; hint::Bool = false)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)
    ret, range, should_complete = completions(full, lastindex(partial); hint)
    return ret, partial[range], should_complete
end

prev_project_file = nothing
prev_project_timestamp = nothing
prev_prefix = ""

function projname(project_file::String)
    project = try
        Types.read_project(project_file)
    catch
        nothing
    end
    if project === nothing || project.name === nothing
        name = basename(dirname(project_file))
    else
        name = project.name::String
    end
    for depot in Base.DEPOT_PATH
        envdir = joinpath(depot, "environments")
        if startswith(safe_realpath(project_file), safe_realpath(envdir))
            return "@" * name
        end
    end
    return name
end

function promptf()
    global prev_project_timestamp, prev_prefix, prev_project_file
    project_file = try
        Types.find_project_file()
    catch
        nothing
    end
    prefix = ""
    if project_file !== nothing
        if prev_project_file == project_file && prev_project_timestamp == mtime(project_file)
            prefix = prev_prefix
        else
            project_name = projname(project_file)
            if project_name !== nothing
                root = Types.find_root_base_project(project_file)
                rootname = projname(root)
                if root !== project_file
                    path_prefix = "/" * dirname(Types.relative_project_path(root, project_file))
                else
                    path_prefix = ""
                end
                if textwidth(rootname) > 30
                    rootname = first(rootname, 27) * "..."
                end
                prefix = "($(rootname)$(path_prefix)) "
                prev_prefix = prefix
                prev_project_timestamp = mtime(project_file)
                prev_project_file = project_file
            end
        end
    end
    if Pkg.OFFLINE_MODE[]
        prefix = "$(prefix)[offline] "
    end
    return "$(prefix)pkg> "
end

function do_cmds(repl::REPL.AbstractREPL, commands::Union{String, Vector{Command}})
    try
        if commands isa String
            commands = prepare_cmd(commands)
        end
        return REPLMode.do_cmds(commands, repl.t.out_stream)
    catch err
        if err isa PkgError || err isa Resolve.ResolverError
            Base.display_error(repl.t.err_stream, ErrorException(sprint(showerror, err)), Ptr{Nothing}[])
        else
            Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
        end
    end
end

function on_done(s, buf, ok, repl)
    ok || return REPL.transition(s, :abort)
    input = String(take!(buf))
    REPL.reset(repl)
    do_cmds(repl, input)
    REPL.prepare_next(repl)
    REPL.reset_state(s)
    return s.current_mode.sticky || REPL.transition(s, main)
end

# Set up the repl Pkg REPLMode
function create_mode(repl::REPL.AbstractREPL, main::LineEdit.Prompt)
    pkg_mode = LineEdit.Prompt(
        promptf;
        prompt_prefix = repl.options.hascolor ? Base.text_colors[:blue] : "",
        prompt_suffix = "",
        complete = PkgCompletionProvider(),
        sticky = true
    )

    pkg_mode.repl = repl
    hp = main.hist
    hp.mode_mapping[:pkg] = pkg_mode
    pkg_mode.hist = hp

    search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
    prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(hp, pkg_mode)

    pkg_mode.on_done = (s, buf, ok) -> Base.@invokelatest(on_done(s, buf, ok, repl))

    mk = REPL.mode_keymap(main)

    shell_mode = nothing
    for mode in repl.interface.modes
        if mode isa LineEdit.Prompt
            mode.prompt == "shell> " && (shell_mode = mode)
        end
    end

    repl_keymap = Dict()
    if shell_mode !== nothing
        let shell_mode = shell_mode
            repl_keymap[';'] = function (s, o...)
                if isempty(s) || position(LineEdit.buffer(s)) == 0
                    buf = copy(LineEdit.buffer(s))
                    LineEdit.transition(s, shell_mode) do
                        LineEdit.state(s, shell_mode).input_buffer = buf
                    end
                else
                    LineEdit.edit_insert(s, ';')
                    LineEdit.check_show_hint(s)
                end
                return
            end
        end
    end

    b = Dict{Any, Any}[
        skeymap, repl_keymap, mk, prefix_keymap, LineEdit.history_keymap,
        LineEdit.default_keymap, LineEdit.escape_defaults,
    ]
    pkg_mode.keymap_dict = LineEdit.keymap(b)
    return pkg_mode
end

function repl_init(repl::REPL.LineEditREPL)
    main_mode = repl.interface.modes[1]
    pkg_mode = create_mode(repl, main_mode)
    push!(repl.interface.modes, pkg_mode)
    keymap = Dict{Any, Any}(
        ']' => function (s, args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, pkg_mode) do
                    LineEdit.state(s, pkg_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, ']')
                LineEdit.check_show_hint(s)
            end
            return
        end
    )
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)
    return
end

const REG_WARNED = Ref{Bool}(false)

function try_prompt_pkg_add(pkgs::Vector{Symbol})
    ctx = try
        Context()
    catch
        # Context() will error if there isn't an active project.
        # If we can't even do that, exit early.
        return false
    end
    if isempty(ctx.registries)
        if !REG_WARNED[]
            printstyled(ctx.io, " │ "; color = :green)
            printstyled(ctx.io, "Attempted to find missing packages in package registries but no registries are installed.\n")
            printstyled(ctx.io, " └ "; color = :green)
            printstyled(ctx.io, "Use package mode to install a registry. `pkg> registry add` will install the default registries.\n\n")
            REG_WARNED[] = true
        end
        return false
    end
    available_uuids = [Types.registered_uuids(ctx.registries, String(pkg)) for pkg in pkgs] # vector of vectors
    filter!(u -> all(!isequal(Operations.JULIA_UUID), u), available_uuids) # "julia" is in General but not installable
    isempty(available_uuids) && return false
    available_pkgs = pkgs[isempty.(available_uuids) .== false]
    isempty(available_pkgs) && return false
    resp = try
        plural1 = length(pkgs) == 1 ? "" : "s"
        plural2 = length(available_pkgs) == 1 ? "a package" : "packages"
        plural3 = length(available_pkgs) == 1 ? "is" : "are"
        plural4 = length(available_pkgs) == 1 ? "" : "s"
        missing_pkg_list = length(pkgs) == 1 ? String(pkgs[1]) : "[$(join(pkgs, ", "))]"
        available_pkg_list = length(available_pkgs) == 1 ? String(available_pkgs[1]) : "[$(join(available_pkgs, ", "))]"
        msg1 = "Package$(plural1) $(missing_pkg_list) not found, but $(plural2) named $(available_pkg_list) $(plural3) available from a registry."
        for line in linewrap(msg1, io = ctx.io, padding = length(" │ "))
            printstyled(ctx.io, " │ "; color = :green)
            println(ctx.io, line)
        end
        printstyled(ctx.io, " │ "; color = :green)
        println(ctx.io, "Install package$(plural4)?")
        msg2 = string("add ", join(available_pkgs, ' '))
        for (i, line) in pairs(linewrap(msg2; io = ctx.io, padding = length(string(" |   ", promptf()))))
            printstyled(ctx.io, " │   "; color = :green)
            if i == 1
                printstyled(ctx.io, promptf(); color = :blue)
            else
                print(ctx.io, " "^length(promptf()))
            end
            println(ctx.io, line)
        end
        printstyled(ctx.io, " └ "; color = :green)
        Base.prompt(stdin, ctx.io, "(y/n/o)", default = "y")
    catch err
        if err isa InterruptException # if ^C is entered
            println(ctx.io)
            return false
        end
        rethrow()
    end
    if isnothing(resp) # if ^D is entered
        println(ctx.io)
        return false
    end
    resp = strip(resp)
    lower_resp = lowercase(resp)
    if lower_resp in ["y", "yes"]
        API.add(string.(available_pkgs); allow_autoprecomp = false)
    elseif lower_resp in ["o"]
        editable_envs = filter(v -> v != "@stdlib", LOAD_PATH)
        option_list = String[]
        keybindings = Char[]
        shown_envs = String[]
        # We use digits 1-9 as keybindings in the env selection menu
        # That's why we can display at most 9 items in the menu
        for i in 1:min(length(editable_envs), 9)
            env = editable_envs[i]
            expanded_env = Base.load_path_expand(env)

            isnothing(expanded_env) && continue

            n = length(option_list) + 1
            push!(option_list, "$(n): $(pathrepr(expanded_env)) ($(env))")
            push!(keybindings, only("$n"))
            push!(shown_envs, expanded_env)
        end
        menu = TerminalMenus.RadioMenu(option_list, keybindings = keybindings, pagesize = length(option_list))
        default = something(
            # select the first non-default env by default, if possible
            findfirst(!=(Base.active_project()), shown_envs),
            1
        )
        print(ctx.io, "\e[1A\e[1G\e[0J") # go up one line, to the start, and clear it
        printstyled(ctx.io, " └ "; color = :green)
        choice = try
            TerminalMenus.request("Select environment:", menu, cursor = default)
        catch err
            if err isa InterruptException # if ^C is entered
                println(ctx.io)
                return false
            end
            rethrow()
        end
        choice == -1 && return false
        API.activate(shown_envs[choice]) do
            API.add(string.(available_pkgs); allow_autoprecomp = false)
        end
    elseif (lower_resp in ["n"])
        return false
    else
        println(ctx.io, "Selection not recognized")
        return false
    end
    if length(available_pkgs) < length(pkgs)
        return false # declare that some pkgs couldn't be installed
    else
        return true
    end
end


function __init__()
    if isdefined(Base, :active_repl)
        if Base.active_repl isa REPL.LineEditREPL
            repl_init(Base.active_repl)
        else
            # TODO: not sure what to do here..
            # LineEditREPL Is the only type of REPL that has the `interface` field that
            # init_repl accesses.
        end
    else
        atreplinit() do repl
            if isinteractive() && repl isa REPL.LineEditREPL
                isdefined(repl, :interface) || (repl.interface = REPL.setup_interface(repl))
                repl_init(repl)
            end
        end
    end
    if !in(try_prompt_pkg_add, REPL.install_packages_hooks)
        push!(REPL.install_packages_hooks, try_prompt_pkg_add)
    end
    return
end

include("precompile.jl")

end
