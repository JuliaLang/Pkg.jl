# This file is a part of Julia. License is MIT: https://julialang.org/license

module REPLMode

@eval Base.Experimental.@compiler_options optimize = 1

using Markdown, UUIDs, Dates

import ..casesensitive_isdir, ..OFFLINE_MODE, ..linewrap, ..pathrepr, ..IN_REPL_MODE
using ..Types, ..Operations, ..API, ..Registry, ..Resolve, ..Apps
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
# see function `REPLMode.api_options`
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
mutable struct CommandSpec
    const canonical_name::String
    const short_name::Union{Nothing,String}
    const api::Function
    const should_splat::Bool
    const argument_spec::ArgSpec
    const option_specs::Dict{String,OptionSpec}
    completions::Union{Nothing,Symbol,Function} # Symbol is used as a marker for REPLExt to assign the function of that name
    const description::String
    const help::Union{Nothing,Markdown.MD}
end

default_parser(xs, options) = unwrap(xs)
function CommandSpec(;name::Union{Nothing,String}           = nothing,
                     short_name::Union{Nothing,String}      = nothing,
                     api::Union{Nothing,Function}           = nothing,
                     should_splat::Bool                     = true,
                     option_spec::Vector{OptionDeclaration} = OptionDeclaration[],
                     help::Union{Nothing,Markdown.MD}       = nothing,
                     description::Union{Nothing,String}     = nothing,
                     completions::Union{Nothing,Symbol,Function}   = nothing,
                     arg_count::Pair                        = (0=>0),
                     arg_parser::Function                   = default_parser,
                     )::CommandSpec
    name === nothing        && error("Supply a canonical name")
    description === nothing && error("Supply a description")
    api === nothing         && error("Supply API dispatch function for `$(name)`")
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
    option_name = m.captures[1] !== nothing ? something(m.captures[1]) : something(m.captures[2])
    option_arg  = m.captures[3] === nothing ? nothing : String(something(m.captures[3]))
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
    replace_comma = (nothing!=match(r"^(add|dev|develop|rm|remove|status|precompile)+\s", cmd))
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

function tokenize(cmd::AbstractString)
    cmd = replace(replace(cmd, "\r\n" => "; "), "\n" => "; ") # for multiline commands
    if startswith(cmd, ']')
        @warn "Removing leading `]`, which should only be used once to switch to pkg> mode"
        cmd = string(lstrip(cmd, ']'))
    end
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
    map(Base.Iterators.filter(!isempty, tokenize(strip(input)))) do words
        statement, input_word = core_parse(words)
        statement.spec === nothing && pkgerror("`$input_word` is not a recognized command. Type ? for help with available commands")
        statement.options = map(parse_option, statement.options)
        statement
    end

#------------#
# APIOptions #
#------------#

# Do NOT introduce a constructor for APIOptions
# as long as it's an alias for Dict
const APIOptions = Dict{Symbol, Any}
function api_options(options::Vector{Option},
                     specs::Dict{String, OptionSpec})
    api_opts = APIOptions()
    enforce_option(options, specs)
    for option in options
        spec = specs[option.val]
        api_opts[spec.api.first] = spec.takes_arg ?
            spec.api.second(option.argument) :
            spec.api.second
    end
    return api_opts
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
    options = api_options(statement.options, statement.spec.option_specs)
    # arguments
    arg_spec = statement.spec.argument_spec
    arguments = arg_spec.parser(statement.arguments, options)
    if !((arg_spec.count.first <= length(arguments) <= arg_spec.count.second)::Bool)
        pkgerror("Wrong number of arguments")
    end
    return Command(statement.spec, options, arguments)
end

#############
# Execution #
#############
function prepare_cmd(input)
    statements = parse(input)
    commands = map(Command, statements)
    return commands
end

do_cmds(input::String, io=stdout_f()) = do_cmds(prepare_cmd(input), io)


function do_cmds(commands::Vector{Command}, io)
    if !isinteractive() && !TEST_MODE[] && !PRINTED_REPL_WARNING[]
        @warn "The Pkg REPL mode is intended for interactive use only, and should not be used from scripts. It is recommended to use the functional API instead."
        PRINTED_REPL_WARNING[] = true
    end
    xs = []
    for command in commands
        push!(xs, do_cmd(command, io))
    end
    return TEST_MODE[] ? xs : nothing
end

function do_cmd(command::Command, io)
    # Set the scoped value to indicate we're in REPL mode
    Base.ScopedValues.@with IN_REPL_MODE => true begin
        # REPL specific commands
        command.spec === SPECS["package"]["help"] && return Base.invokelatest(do_help!, command, io)
        # API commands
        if command.spec.should_splat
            TEST_MODE[] && return command.spec.api, command.arguments..., command.options
            command.spec.api(command.arguments...; collect(command.options)...) # TODO is invokelatest still needed?
        else
            TEST_MODE[] && return command.spec.api, command.arguments, command.options
            command.spec.api(command.arguments; collect(command.options)...)
        end
    end
end

function parse_command(words::Vector{QString})
    statement, word = core_parse(words; only_cmd=true)
    if statement.super === nothing && statement.spec === nothing
        pkgerror("invalid input: `$word` is not a command")
    end
    return statement.spec === nothing ?  statement.super : statement.spec
end

function do_help!(command::Command, io)
    if isempty(command.arguments)
        show(io, MIME("text/plain"), help)
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
    show(io, MIME("text/plain"), help_md)
end

# Provide a string macro pkg"cmd" that can be used in the same way
# as the REPLMode `pkg> cmd`. Useful for testing and in environments
# where we do not have a REPL, e.g. IJulia.
macro pkg_str(str::String)
    :(pkgstr($str))
end

function pkgstr(str::String)
    return do_cmds(str)
end

########
# SPEC #
########
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
        short_name = spec.short_name === nothing ? "" : ", `" * spec.short_name::String * '`'
        push!(help.content, Markdown.parse("`$command`$short_name: $(spec.description)"))
    end
    return help
end

const help = gen_help()

end #module
