# This file is a part of Julia. License is MIT: https://julialang.org/license

module REPLMode

using Markdown, UUIDs, Dates

import REPL
import REPL: LineEdit, REPLCompletions
import REPL: TerminalMenus

import ..casesensitive_isdir, ..OFFLINE_MODE, ..linewrap, ..pathrepr
using ..Types, ..Operations, ..API, ..Registry, ..Resolve
import ..stdout_f, ..stderr_f

const TEST_MODE = Ref{Bool}(false)
const PRINTED_REPL_WARNING = Ref{Bool}(false)

#########################
# Specification Structs #
#########################

#---------#
# Options #
#---------#
const OptionDeclaration = Vector{Pair{Symbol,Any}}
struct OptionSpec
    name::String
    short_name::Union{Nothing,String}
    api::Pair{Symbol, Any}
    takes_arg::Bool
end

# TODO assert names matching lex regex
# assert now so that you don't fail at user time
# see function `REPLMode.APIOptions`
function OptionSpec(;name::String,
                    short_name::Union{Nothing,String}=nothing,
                    takes_arg::Bool=false,
                    api::Pair{Symbol,<:Any})::OptionSpec
    takes_arg && @assert hasmethod(api.second, Tuple{String})
    return OptionSpec(name, short_name, api, takes_arg)
end

function OptionSpecs(decs::Vector{OptionDeclaration})
    specs = Dict{String, OptionSpec}()
    for x in decs
        opt_spec = OptionSpec(;x...)
        @assert !haskey(specs, opt_spec.name) # don't overwrite
        specs[opt_spec.name] = opt_spec
        if opt_spec.short_name !== nothing
            @assert !haskey(specs, opt_spec.short_name::String) # don't overwrite
            specs[opt_spec.short_name::String] = opt_spec
        end
    end
    return specs
end

#-----------#
# Arguments #
#-----------#
struct ArgSpec
    count::Pair
    parser::Function
end

#----------#
# Commands #
#----------#
const CommandDeclaration = Vector{Pair{Symbol,Any}}
struct CommandSpec
    canonical_name::String
    short_name::Union{Nothing,String}
    api::Function
    should_splat::Bool
    argument_spec::ArgSpec
    option_specs::Dict{String,OptionSpec}
    completions::Union{Nothing,Function}
    description::String
    help::Union{Nothing,Markdown.MD}
end

default_parser(xs, options) = unwrap(xs)
function CommandSpec(;name::Union{Nothing,String}           = nothing,
                     short_name::Union{Nothing,String}      = nothing,
                     api::Union{Nothing,Function}           = nothing,
                     should_splat::Bool                     = true,
                     option_spec::Vector{OptionDeclaration} = OptionDeclaration[],
                     help::Union{Nothing,Markdown.MD}       = nothing,
                     description::Union{Nothing,String}     = nothing,
                     completions::Union{Nothing,Function}   = nothing,
                     arg_count::Pair                        = (0=>0),
                     arg_parser::Function                   = default_parser,
                     )::CommandSpec
    @assert name !== nothing "Supply a canonical name"
    @assert description !== nothing "Supply a description"
    @assert api !== nothing "Supply API dispatch function for `$(name)`"
    # TODO assert isapplicable completions dict, string
    return CommandSpec(name, short_name, api, should_splat, ArgSpec(arg_count, arg_parser),
                       OptionSpecs(option_spec), completions, description, help)
end

function CommandSpecs(declarations::Vector{CommandDeclaration})
    specs = Dict{String,CommandSpec}()
    for dec in declarations
        spec = CommandSpec(;dec...)
        @assert !haskey(specs, spec.canonical_name) "duplicate spec entry"
        specs[spec.canonical_name] = spec
        if spec.short_name !== nothing
            @assert !haskey(specs, spec.short_name::String) "duplicate spec entry"
            specs[spec.short_name::String] = spec
        end
    end
    return specs
end

function CompoundSpecs(compound_declarations)
    compound_specs = Dict{String,Dict{String,CommandSpec}}()
    for (name, command_declarations) in compound_declarations
        specs = CommandSpecs(command_declarations)
        @assert !haskey(compound_specs, name) "duplicate super spec entry"
        compound_specs[name] = specs
    end
    return compound_specs
end

###########
# Parsing #
###########

# QString: helper struct for retaining quote information
struct QString
    raw::String
    isquoted::Bool
end
unwrap(xs::Vector{QString}) = map(x -> x.raw, xs)

#---------#
# Options #
#---------#
struct Option
    val::String
    argument::Union{Nothing,String}
    Option(val::AbstractString) = new(val, nothing)
    Option(val::AbstractString, arg::Union{Nothing,String}) = new(val, arg)
end
Base.show(io::IO, opt::Option) = print(io, "--$(opt.val)", opt.argument === nothing ? "" : "=$(opt.argument)")
wrap_option(option::String)  = length(option) == 1 ? "-$option" : "--$option"
is_opt(word::AbstractString) = first(word) == '-' && word != "-"

function parse_option(word::AbstractString)::Option
    m = match(r"^(?: -([a-z]) | --((?:[a-z]{1,}-?)*)(?:\s*=\s*(\S*))? )$"ix, word)
    m === nothing && pkgerror("malformed option: ", repr(word))
    option_name = m.captures[1] !== nothing ? m.captures[1] : m.captures[2]
    option_arg  = m.captures[3] === nothing ? nothing : String(m.captures[3])
    return Option(option_name, option_arg)
end

#-----------#
# Statement #
#-----------#
# Statement: text-based representation of a command
Base.@kwdef mutable struct Statement
    super::Union{Nothing,String}                  = nothing
    spec::Union{Nothing,CommandSpec}              = nothing
    options::Union{Vector{Option},Vector{String}} = String[]
    arguments::Vector{QString}                    = QString[]
end

function lex(cmd::String)::Vector{QString}
    replace_comma = (nothing!=match(r"^(add|rm|remove|status)+\s", cmd))
    in_doublequote = false
    in_singlequote = false
    qstrings = QString[]
    token_in_progress = Char[]

    push_token!(is_quoted) = begin
        push!(qstrings, QString(String(token_in_progress), is_quoted))
        empty!(token_in_progress)
    end

    for c in cmd
        if c == '"'
            if in_singlequote # raw char
                push!(token_in_progress, c)
            else # delimiter
                in_doublequote ? push_token!(true) : push_token!(false)
                in_doublequote = !in_doublequote
            end
        elseif c == '\''
            if in_doublequote # raw char
                push!(token_in_progress, c)
            else # delimiter
                in_singlequote ? push_token!(true) : push_token!(false)
                in_singlequote = !in_singlequote
            end
        elseif c == ' '
            if in_doublequote || in_singlequote # raw char
                push!(token_in_progress, c)
            else # delimiter
                push_token!(false)
            end
        elseif c == ';'
            if in_doublequote || in_singlequote # raw char
                push!(token_in_progress, c)
            else # special delimiter
                push_token!(false)
                push!(qstrings, QString(";", false))
            end
        elseif c == ','
            if in_doublequote || in_singlequote || !replace_comma # raw char
                # don't replace ',' in quotes
                push!(token_in_progress, c)
            else
                push_token!(false)
                push!(qstrings, QString("", false))
            end
        else
            push!(token_in_progress, c)
        end
    end
    (in_doublequote || in_singlequote) ? pkgerror("unterminated quote") : push_token!(false)
    # to avoid complexity in the main loop, empty tokens are allowed above and
    # filtered out before returning
    return filter(x->!isempty(x.raw), qstrings)
end

function tokenize(cmd::String)
    cmd = replace(replace(cmd, "\r\n" => "; "), "\n" => "; ") # for multiline commands
    qstrings = lex(cmd)
    statements = foldl(qstrings; init=[QString[]]) do collection, next
        (next.raw == ";" && !next.isquoted) ?
            push!(collection, QString[]) :
            push!(collection[end], next)
        return collection
    end
    return statements
end

function core_parse(words::Vector{QString}; only_cmd=false)
    statement = Statement()
    word::Union{Nothing,QString} = nothing
    function next_word!()
        isempty(words) && return false
        word = popfirst!(words)
        return true
    end

    # begin parsing
    next_word!() || return statement, ((word === nothing) ? nothing : word.raw)
    # handle `?` alias for help
    # It is special in that it requires no space between command and args
    if word.raw[1]=='?' && !word.isquoted
        length(word.raw) > 1 && pushfirst!(words, QString(word.raw[2:end],false))
        word = QString("?", false)
    end
    # determine command
    super = get(SPECS, word.raw, nothing)
    if super !== nothing # explicit
        statement.super = word.raw
        next_word!() || return statement, word.raw
        command = get(super, word.raw, nothing)
        command !== nothing || return statement, word.raw
    else # try implicit package
        super = SPECS["package"]
        command = get(super, word.raw, nothing)
        command !== nothing || return statement, word.raw
    end
    statement.spec = command

    only_cmd && return statement, word.raw # hack to hook in `help` command

    next_word!() || return statement, word.raw

    # full option parsing is delayed so that the completions parser can use the raw string
    while is_opt(word.raw)
        push!(statement.options, word.raw)
        next_word!() || return statement, word.raw
    end

    pushfirst!(words, word)
    statement.arguments = words
    return statement, words[end].raw
end

parse(input::String) =
    map(Base.Iterators.filter(!isempty, tokenize(input))) do words
        statement, input_word = core_parse(words)
        statement.spec === nothing && pkgerror("`$input_word` is not a recognized command. Type ? for help with available commands")
        statement.options = map(parse_option, statement.options)
        statement
    end

#------------#
# APIOptions #
#------------#
const APIOptions = Dict{Symbol, Any}
function APIOptions(options::Vector{Option},
                    specs::Dict{String, OptionSpec},
                    )::APIOptions
    api_options = Dict{Symbol, Any}()
    enforce_option(options, specs)
    for option in options
        spec = specs[option.val]
        api_options[spec.api.first] = spec.takes_arg ?
            spec.api.second(option.argument) :
            spec.api.second
    end
    return api_options
end
Context!(ctx::APIOptions)::Context = Types.Context!(collect(ctx))

#---------#
# Command #
#---------#
Base.@kwdef struct Command
    spec::Union{Nothing,CommandSpec} = nothing
    options::APIOptions              = APIOptions()
    arguments::Vector                = []
end

function enforce_option(option::Option, specs::Dict{String,OptionSpec})
    spec = get(specs, option.val, nothing)
    spec !== nothing || pkgerror("option '$(option.val)' is not a valid option")
    if spec.takes_arg
        option.argument !== nothing ||
            pkgerror("option '$(option.val)' expects an argument, but no argument given")
    else # option is a switch
        option.argument === nothing ||
            pkgerror("option '$(option.val)' does not take an argument, but '$(option.argument)' given")
    end
end

"""
checks:
- options are understood by the given command
- options do not conflict (e.g. `rm --project --manifest`)
- options which take an argument are given arguments
- options which do not take arguments are not given arguments
"""
function enforce_option(options::Vector{Option}, specs::Dict{String,OptionSpec})
    unique_keys = Symbol[]
    get_key(opt::Option) = specs[opt.val].api.first

    # per option checking
    foreach(x->enforce_option(x,specs), options)
    # checking for compatible options
    for opt in options
        key = get_key(opt)
        if key in unique_keys
            conflicting = filter(opt->get_key(opt) == key, options)
            pkgerror("Conflicting options: $conflicting")
        else
            push!(unique_keys, key)
        end
    end
end

"""
Final parsing (and checking) step.
This step is distinct from `parse` in that it relies on the command specifications.
"""
function Command(statement::Statement)::Command
    # options
    options = APIOptions(statement.options, statement.spec.option_specs)
    # arguments
    arg_spec = statement.spec.argument_spec
    arguments = arg_spec.parser(statement.arguments, options)
    if !(arg_spec.count.first <= length(arguments) <= arg_spec.count.second)
        pkgerror("Wrong number of arguments")
    end
    return Command(statement.spec, options, arguments)
end

#############
# Execution #
#############
function do_cmd(repl::REPL.AbstractREPL, input::String; do_rethrow=false)
    if !isinteractive() && !TEST_MODE[] && !PRINTED_REPL_WARNING[]
        @warn "The Pkg REPL mode is intended for interactive use only, and should not be used from scripts. It is recommended to use the functional API instead."
        PRINTED_REPL_WARNING[] = true
    end
    try
        statements = parse(input)
        commands   = map(Command, statements)
        xs = []
        for command in commands
            push!(xs, do_cmd!(command, repl))
        end
        return TEST_MODE[] ? xs : nothing
    catch err
        do_rethrow && rethrow()
        if err isa PkgError || err isa Resolve.ResolverError
            Base.display_error(repl.t.err_stream, ErrorException(sprint(showerror, err)), Ptr{Nothing}[])
        else
            Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
        end
    end
end

function do_cmd!(command::Command, repl)
    # REPL specific commands
    command.spec === SPECS["package"]["help"] && return Base.invokelatest(do_help!, command, repl)
    # API commands
    if command.spec.should_splat
        TEST_MODE[] && return command.spec.api, command.arguments..., command.options
        command.spec.api(command.arguments...; collect(command.options)...) # TODO is invokelatest still needed?
    else
        TEST_MODE[] && return command.spec.api, command.arguments, command.options
        command.spec.api(command.arguments; collect(command.options)...)
    end
end

function parse_command(words::Vector{QString})
    statement, word = core_parse(words; only_cmd=true)
    if statement.super === nothing && statement.spec === nothing
        pkgerror("invalid input: `$word` is not a command")
    end
    return statement.spec === nothing ?  statement.super : statement.spec
end

function do_help!(command::Command, repl::REPL.AbstractREPL)
    disp = REPL.REPLDisplay(repl)
    if isempty(command.arguments)
        Base.display(disp, help)
        return
    end
    help_md = md""

    cmd = parse_command(command.arguments)
    if cmd isa String
        # gather all helps for super spec `cmd`
        all_specs = sort!(unique(values(SPECS[cmd]));
                          by=(spec->spec.canonical_name))
        for spec in all_specs
            isempty(help_md.content) || push!(help_md.content, md"---")
            push!(help_md.content, spec.help)
        end
    elseif cmd isa CommandSpec
        push!(help_md.content, cmd.help)
    end
    !isempty(command.arguments) && @warn "More than one command specified, only rendering help for first"
    Base.display(disp, help_md)
end

######################
# REPL mode creation #
######################

# Provide a string macro pkg"cmd" that can be used in the same way
# as the REPLMode `pkg> cmd`. Useful for testing and in environments
# where we do not have a REPL, e.g. IJulia.
struct MiniREPL <: REPL.AbstractREPL
    display::TextDisplay
    t::REPL.Terminals.TTYTerminal
end
function MiniREPL()
    MiniREPL(TextDisplay(stdout_f()), REPL.Terminals.TTYTerminal(get(ENV, "TERM", Sys.iswindows() ? "" : "dumb"), stdin, stdout_f(), stderr_f()))
end
REPL.REPLDisplay(repl::MiniREPL) = repl.display

const minirepl = Ref{MiniREPL}()

__init__() = minirepl[] = MiniREPL()

macro pkg_str(str::String)
    :($(do_cmd)(minirepl[], $str; do_rethrow=true))
end

pkgstr(str::String) = do_cmd(minirepl[], str; do_rethrow=true)

struct PkgCompletionProvider <: LineEdit.CompletionProvider end

function LineEdit.complete_line(c::PkgCompletionProvider, s)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)
    ret, range, should_complete = completions(full, lastindex(partial))
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
        name = project.name
    end
    for depot in Base.DEPOT_PATH
        envdir = joinpath(depot, "environments")
        if startswith(abspath(project_file), abspath(envdir))
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
                prefix = "($(project_name)) "
                prev_prefix = prefix
                prev_project_timestamp = mtime(project_file)
                prev_project_file = project_file
            end
        end
    end
    if OFFLINE_MODE[]
        prefix = "$(prefix)[offline] "
    end
    return "$(prefix)pkg> "
end

# Set up the repl Pkg REPLMode
function create_mode(repl::REPL.AbstractREPL, main::LineEdit.Prompt)
    pkg_mode = LineEdit.Prompt(promptf;
        prompt_prefix = repl.options.hascolor ? Base.text_colors[:blue] : "",
        prompt_suffix = "",
        complete = PkgCompletionProvider(),
        sticky = true)

    pkg_mode.repl = repl
    hp = main.hist
    hp.mode_mapping[:pkg] = pkg_mode
    pkg_mode.hist = hp

    search_prompt, skeymap = LineEdit.setup_search_keymap(hp)
    prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(hp, pkg_mode)

    pkg_mode.on_done = (s, buf, ok) -> begin
        ok || return REPL.transition(s, :abort)
        input = String(take!(buf))
        REPL.reset(repl)
        do_cmd(repl, input)
        REPL.prepare_next(repl)
        REPL.reset_state(s)
        s.current_mode.sticky || REPL.transition(s, main)
    end

    mk = REPL.mode_keymap(main)

    shell_mode = nothing
    for mode in Base.active_repl.interface.modes
        if mode isa LineEdit.Prompt
            mode.prompt == "shell> " && (shell_mode = mode)
        end
    end

    repl_keymap = Dict()
    if shell_mode !== nothing
        let shell_mode=shell_mode
            repl_keymap[';'] = function (s,o...)
                if isempty(s) || position(LineEdit.buffer(s)) == 0
                    buf = copy(LineEdit.buffer(s))
                    LineEdit.transition(s, shell_mode) do
                        LineEdit.state(s, shell_mode).input_buffer = buf
                    end
                else
                    LineEdit.edit_insert(s, ';')
                end
            end
        end
    end

    b = Dict{Any,Any}[
        skeymap, repl_keymap, mk, prefix_keymap, LineEdit.history_keymap,
        LineEdit.default_keymap, LineEdit.escape_defaults
    ]
    pkg_mode.keymap_dict = LineEdit.keymap(b)
    return pkg_mode
end

function repl_init(repl::REPL.AbstractREPL)
    main_mode = repl.interface.modes[1]
    pkg_mode = create_mode(repl, main_mode)
    push!(repl.interface.modes, pkg_mode)
    keymap = Dict{Any,Any}(
        ']' => function (s,args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, pkg_mode) do
                    LineEdit.state(s, pkg_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, ']')
            end
        end
    )
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)
    return
end

########
# SPEC #
########
include("completions.jl")
include("argument_parsers.jl")
include("command_declarations.jl")
const SPECS = CompoundSpecs(compound_declarations)

########
# HELP #
########
function canonical_names()
    # add "package" commands
    xs = [(spec.canonical_name => spec) for spec in unique(values(SPECS["package"]))]
    sort!(xs, by=first)
    # add other super commands, e.g. "registry"
    for (super, specs) in SPECS
        super != "package" || continue # skip "package"
        temp = [(join([super, spec.canonical_name], " ") => spec) for spec in unique(values(specs))]
        append!(xs, sort!(temp, by=first))
    end
    return xs
end

function gen_help()
    help = md"""
**Welcome to the Pkg REPL-mode**. To return to the `julia>` prompt, either press
backspace when the input line is empty or press Ctrl+C.

Full documentation available at https://pkgdocs.julialang.org/

**Synopsis**

    pkg> cmd [opts] [args]

Multiple commands can be given on the same line by interleaving a `;` between the commands.
Some commands have an alias, indicated below.

**Commands**
"""
    for (command, spec) in canonical_names()
        short_name = spec.short_name === nothing ? "" : ", `" * spec.short_name * '`'
        push!(help.content, Markdown.parse("`$command`$short_name: $(spec.description)"))
    end
    return help
end

const help = gen_help()
const REG_WARNED = Ref{Bool}(false)

function try_prompt_pkg_add(pkgs::Vector{Symbol})
    ctx = Context()
    if isempty(ctx.registries)
        if !REG_WARNED[]
            printstyled(ctx.io, " │ "; color=:green)
            printstyled(ctx.io, "Attempted to find missing packages in package registries but no registries are installed.\n")
            printstyled(ctx.io, " └ "; color=:green)
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
            printstyled(ctx.io, " │ "; color=:green)
            println(ctx.io, line)
        end
        printstyled(ctx.io, " │ "; color=:green)
        println(ctx.io, "Install package$(plural4)?")
        msg2 = string("add ", join(available_pkgs, ' '))
        for (i, line) in pairs(linewrap(msg2; io = ctx.io, padding = length(string(" |   ", REPLMode.promptf()))))
            printstyled(ctx.io, " │   "; color=:green)
            if i == 1
                printstyled(ctx.io, REPLMode.promptf(); color=:blue)
            else
                print(ctx.io, " "^length(REPLMode.promptf()))
            end
            println(ctx.io, line)
        end
        printstyled(ctx.io, " └ "; color=:green)
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
        API.add(string.(available_pkgs))
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
        menu = TerminalMenus.RadioMenu(option_list, keybindings=keybindings, pagesize=length(option_list))
        print(ctx.io, "\e[1A\e[1G\e[0J") # go up one line, to the start, and clear it
        printstyled(ctx.io, " └ "; color=:green)
        choice = try
            TerminalMenus.request("Select environment:", menu)
        catch err
            if err isa InterruptException # if ^C is entered
                println(ctx.io)
                return false
            end
            rethrow()
        end
        choice == -1 && return false
        API.activate(shown_envs[choice]) do
            API.add(string.(available_pkgs))
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

end #module
