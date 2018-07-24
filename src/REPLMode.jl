module REPLMode

using Markdown
using UUIDs

import REPL
import REPL: LineEdit, REPLCompletions

import ..devdir, ..print_first_command_header, ..Types.casesensitive_isdir
using ..Types, ..Display, ..Operations, ..API

#################
# Git revisions #
#################
struct Rev
    rev::String
end

###########
# Options #
###########
#TODO should this opt be removed: ("name", :cmd, :temp => false)
struct OptionSpec
    name::String
    short_name::Union{Nothing,String}
    api::Pair{Symbol, Any}
    is_switch::Bool
end

@enum(OptionClass, OPT_ARG, OPT_SWITCH)
const OptionDeclaration = Tuple{Union{String,Vector{String}}, # name + short_name?
                                OptionClass, # arg or switch
                                Pair{Symbol, Any} # api keywords
                                }

function OptionSpec(x::OptionDeclaration)::OptionSpec
    get_names(name::String) = (name, nothing)
    function get_names(names::Vector{String})
        @assert length(names) == 2
        return (names[1], names[2])
    end

    is_switch = x[2] == OPT_SWITCH
    api = x[3]
    (name, short_name) = get_names(x[1])
    #TODO assert matching lex regex
    if !is_switch
        @assert api.second === nothing || hasmethod(api.second, Tuple{String})
    end
    return OptionSpec(name, short_name, api, is_switch)
end

function OptionSpecs(decs::Vector{OptionDeclaration})::Dict{String, OptionSpec}
    specs = Dict()
    for x in decs
        opt_spec = OptionSpec(x)
        @assert get(specs, opt_spec.name, nothing) === nothing # don't overwrite
        specs[opt_spec.name] = opt_spec
        if opt_spec.short_name !== nothing
            @assert get(specs, opt_spec.short_name, nothing) === nothing # don't overwrite
            specs[opt_spec.short_name] = opt_spec
        end
    end
    return specs
end

struct Option
    val::String
    argument::Union{Nothing,String}
    Option(val::AbstractString) = new(val, nothing)
    Option(val::AbstractString, arg::Union{Nothing,String}) = new(val, arg)
end
Base.show(io::IO, opt::Option) = print(io, "--$(opt.val)", opt.argument == nothing ? "" : "=$(opt.argument)")

function parse_option(word::AbstractString)::Option
    m = match(r"^(?: -([a-z]) | --([a-z]{2,})(?:\s*=\s*(\S*))? )$"ix, word)
    m == nothing && cmderror("malformed option: ", repr(word))
    option_name = (m.captures[1] != nothing ? m.captures[1] : m.captures[2])
    option_arg = (m.captures[3] == nothing ? nothing : String(m.captures[3]))
    return Option(option_name, option_arg)
end

meta_option_declarations = OptionDeclaration[
    ("env", OPT_ARG, :env => arg->EnvCache(Base.parse_env(arg)))
]
meta_option_specs = OptionSpecs(meta_option_declarations)

################
# Command Spec #
################
@enum(ArgClass, ARG_RAW, ARG_PKG, ARG_VERSION, ARG_REV, ARG_ALL)
struct ArgSpec
    class::ArgClass
    count::Vector{Int}
end

const CommandDeclaration = Tuple{Vector{String}, # names
                                 Function, # handler
                                 Tuple{ArgClass, Vector{Int}}, # argument count
                                 Vector{OptionDeclaration} # options
                                 }
struct CommandSpec
    names::Vector{String}
    handler::Function
    argument_spec::ArgSpec # note: just use range operator for max/min
    option_specs::Dict{String, OptionSpec}
end
command_specs = Dict{String,CommandSpec}() # TODO remove this ?

# populate a dictionary: command_name -> command_spec
function init_command_spec(declarations::Vector{CommandDeclaration})::Dict{String,CommandSpec}
    specs = Dict()
    for dec in declarations
        names = dec[1]
        spec = CommandSpec(dec[1], dec[2], ArgSpec(dec[3]...), OptionSpecs(dec[end]))
        for name in names
            # TODO regex check name
            @assert get(specs, name, nothing) === nothing # don't overwrite
            specs[name] = spec
        end
    end
    return specs
end

###################
# Package parsing #
###################
let uuid = raw"(?i)[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}(?-i)",
    name = raw"(\w+)(?:\.jl)?"
    global const name_re = Regex("^$name\$")
    global const uuid_re = Regex("^$uuid\$")
    global const name_uuid_re = Regex("^$name\\s*=\\s*($uuid)\$")
end

# packages can be identified through: uuid, name, or name+uuid
# additionally valid for add/develop are: local path, url
function parse_package(word::AbstractString; add_or_develop=false)::PackageSpec
    word = replace(word, "~" => homedir())
    if add_or_develop && casesensitive_isdir(word)
        return PackageSpec(Types.GitRepo(abspath(word)))
    elseif occursin(uuid_re, word)
        return PackageSpec(UUID(word))
    elseif occursin(name_re, word)
        return PackageSpec(String(match(name_re, word).captures[1]))
    elseif occursin(name_uuid_re, word)
        m = match(name_uuid_re, word)
        return PackageSpec(String(m.captures[1]), UUID(m.captures[2]))
    elseif add_or_develop
        # Guess it is a url then
        return PackageSpec(Types.GitRepo(word))
    else
        cmderror("`$word` cannot be parsed as a package")
    end
end

################
# REPL parsing #
################
mutable struct Statement
    command::String
    options::Vector{String}
    arguments::Vector{String}
    meta_options::Vector{String}
    Statement() = new("", [], [], [])
end

struct QuotedWord
    word::String
    isquoted::Bool
end

function parse(cmd::String)::Vector{Statement}
    # replace new lines with ; to support multiline commands
    cmd = replace(replace(cmd, "\r\n" => "; "), "\n" => "; ")
    # tokenize accoring to whitespace / quotes
    qwords = parse_quotes(cmd)
    # tokenzie unquoted tokens according to pkg REPL syntax
    words::Vector{String} = collect(Iterators.flatten(map(qword2word, qwords)))
    # break up words according to ";"(doing this early makes subsequent processing easier)
    word_groups = group_words(words)
    # create statements
    statements = map(Statement, word_groups)
    return statements
end

# vector of words -> structured statement
# minimal checking is done in this phase
function Statement(words)
    is_option(word) = first(word) == '-'
    statement = Statement()
    word = popfirst!(words)

    # meta options
    while is_option(word)
        push!(statement.meta_options, word)
        isempty(words) && cmderror("no command specified")
        word = popfirst!(words)
    end
    # command name
    word in keys(command_specs) || cmderror("expected command. instead got [$word]")
    statement.command = word
    # command arguments
    for word in words
        push!((is_option(word) ? statement.options : statement.arguments), word)
    end
    return statement
end

function group_words(words)::Vector{Vector{String}}
    statements = Vector{String}[]
    x = String[]
    for word in words
        if word == ";"
            isempty(x) ? cmderror("empty statement") : push!(statements, x)
            x = String[]
        else
            push!(x, word)
        end
    end
    isempty(x) || push!(statements, x)
    return statements
end

const lex_re = r"^[\?\./\+\-](?!\-) | ((git|ssh|http(s)?)|(git@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)(/)? | [^@\#\s;]+\s*=\s*[^@\#\s;]+ | \#\s*[^@\#\s;]* | @\s*[^@\#\s;]* | [^@\#\s;]+|;"x

function qword2word(qword::QuotedWord)
    return qword.isquoted ? [qword.word] : map(m->m.match, eachmatch(lex_re, " $(qword.word)"))
    #                                                                         ^
    # note: space before `$word` is necessary to keep using current `lex_re`
end

function parse_quotes(cmd::String)::Vector{QuotedWord}
    in_doublequote = false
    in_singlequote = false
    qwords = QuotedWord[]
    token_in_progress = Char[]

    push_token!(is_quoted) = begin
        push!(qwords, QuotedWord(String(token_in_progress), is_quoted))
        empty!(token_in_progress)
    end

    for c in cmd
        if c == '"'
            if in_singlequote # raw char
                push!(token_in_progress, c)
            else # delimiter
                in_doublequote = !in_doublequote
                push_token!(true)
            end
        elseif c == '\''
            if in_doublequote # raw char
                push!(token_in_progress, c)
            else # delimiter
                in_singlequote = !in_singlequote
                push_token!(true)
            end
        elseif c == ' ' && !(in_doublequote || in_singlequote)
            push_token!(false)
        else
            push!(token_in_progress, c)
        end
    end
    if (in_doublequote || in_singlequote)
        ArgumentError("unterminated quote")
    else
        push_token!(false)
    end
    # to avoid complexity in the main loop, empty tokens are allowed above and
    # filtered out before returning
    return filter(x->!isempty(x.word), qwords)
end

##############
# PkgCommand #
##############
const Token = Union{String, VersionRange, Rev}
const PkgArguments = Union{Vector{String}, Vector{PackageSpec}}
struct PkgCommand
    meta_options::Vector{Option}
    name::String
    options::Vector{Option}
    arguments::PkgArguments
    PkgCommand() = new([], "", [], [])
    PkgCommand(meta_opts, cmd_name, opts, args) = new(meta_opts, cmd_name, opts, args)
end

get_api_opts(command::PkgCommand)::Vector{Pair{Symbol,Any}} =
    get_api_opts(command.options, command_specs[command.name].option_specs)

function get_api_opts(options::Vector{Option},
                      specs::Dict{String, OptionSpec},
                      )::Vector{Pair{Symbol,Any}}
    return map(options) do opt
        spec = specs[opt.val]
        return spec.api.first => begin
            # opt is switch
            spec.is_switch && return spec.api.second
            # no opt wrapper -> just use raw argument
            spec.api.second === nothing && return opt.argument
            # given opt wrapper
            return spec.api.second(opt.argument)
        end
    end
end

function enforce_argument_order(args::Vector{Token})
    prev_arg = nothing
    function check_prev_arg(valid_type::DataType, error_message::AbstractString)
        prev_arg isa valid_type || cmderror(error_message)
    end

    for arg in args
        if arg isa VersionRange
            check_prev_arg(String, "package name/uuid must precede version spec `@$arg`")
        elseif arg isa Rev
            check_prev_arg(String, "package name/uuid must precede rev spec `#$(arg.rev)`")
        end
        prev_arg = arg
    end
end

function word2token(word::AbstractString)::Token
    if first(word) == '@'
        return VersionRange(word[2:end])
    elseif first(word) == '#'
        return Rev(word[2:end])
    else
        return String(word)
    end
end

function enforce_arg_spec(raw_args::Vector{String}, class::ArgClass)
    # TODO is there a more idiomatic way to do this?
    function has_types(arguments::Vector{Token}, types::Vector{DataType})
        return !isempty(filter(x->typeof(x) in types, arguments))
    end

    class == ARG_RAW && return raw_args
    args::Vector{Token} = map(word2token, raw_args)
    class == ARG_ALL && return args

    if class == ARG_PKG && has_types(args, [VersionRange, Rev])
        cmderror("no versioned packages allowed")
    elseif class == ARG_REV && has_types(args, [VersionRange])
        cmderror("no versioned packages allowed")
    elseif class == ARG_VERSION && has_types(args, [Rev])
        cmderror("no reved packages allowed")
    end
    return args
end

function package_args(args::Vector{Token}, cmd::String)::Vector{PackageSpec}
    pkgs = PackageSpec[]
    for arg in args
        if arg isa String
            # TODO is there a way to avoid add_or_develop?
            opt = [:add_or_develop => (command_specs[cmd].handler == do_add_or_develop!)]
            push!(pkgs, parse_package(arg; opt...))
        elseif arg isa VersionRange
            pkgs[end].version = arg
        elseif arg isa Rev
            pkg = pkgs[end]
            if pkg.repo == nothing
                pkg.repo = Types.GitRepo("", arg.rev)
            else
                pkgs[end].repo.rev = arg.rev
            end
        else
            assert(false)
        end
    end
    return pkgs
end

function enforce_arg_count(count::Vector{Int}, args::PkgArguments)
    isempty(count) && return
    length(args) in count ||
        cmderror("Wrong number of arguments")
end

function enforce_args(raw_args::Vector{String}, spec::ArgSpec, cmd::String)::PkgArguments
    if spec.class == ARG_RAW
        enforce_arg_count(spec.count, raw_args)
        return raw_args
    end

    args = enforce_arg_spec(raw_args, spec.class)
    enforce_argument_order(args)
    pkgs = package_args(args, cmd)
    enforce_arg_count(spec.count, pkgs)
    return pkgs
end

function enforce_option(option::String, specs::Dict{String,OptionSpec})::Option
    opt = parse_option(option)
    spec = get(specs, opt.val, nothing)
    spec !== nothing ||
        cmderror("option '$(opt.val)' is not a valid option")
    if spec.is_switch
        opt.argument === nothing ||
            cmderror("option '$(opt.val)' does not take an argument, but '$(opt.argument)' given")
    else # option takes an argument
        opt.argument !== nothing ||
            cmderror("option '$(opt.val)' expects an argument, but no argument given")
    end
    return opt
end

function enforce_meta_options(options::Vector{String}, specs::Dict{String,OptionSpec})::Vector{Option}
    meta_opt_names = keys(specs)
    return map(options) do opt
        tok = enforce_option(opt, specs)
        tok.val in meta_opt_names ||
            cmderror("option '$opt' is not a valid meta option.")
            #TODO hint that maybe they intended to use it as a command option
        return tok
    end
end

function enforce_opts(options::Vector{String}, specs::Dict{String,OptionSpec}, cmd::String)::Vector{Option}
    unique_keys = Symbol[]
    get_key(opt::Option) = specs[opt.val].api.first

    # final parsing
    toks = map(x->enforce_option(x,specs), options)
    # checking
    for opt in toks
        # valid option
        opt.val in keys(specs) ||
            cmderror("option '$(opt.val)' is not supported by command '$cmd'")
        # conflicting options
        key = get_key(opt)
        if key in unique_keys
            conflicting = filter(opt->get_key(opt) == key, toks)
            cmderror("Conflicting options: $conflicting")
        else
            push!(unique_keys, key)
        end
    end
    return toks
end

# this the entry point for the majority of input checks
function PkgCommand(statement::Statement)
    meta_opts = enforce_meta_options(statement.meta_options,
                                     meta_option_specs)
    args = enforce_args(statement.arguments,
                        command_specs[statement.command].argument_spec,
                        statement.command)
    opts = enforce_opts(statement.options,
                        command_specs[statement.command].option_specs,
                        statement.command)
    return PkgCommand(meta_opts, statement.command, opts, args)
end

#############
# Execution #
#############
function do_cmd(repl::REPL.AbstractREPL, input::String; do_rethrow=false)
    try
        statements = parse(input)
        commands = map(PkgCommand, statements)
        for cmd in commands
            do_cmd!(cmd, repl)
        end
    catch err
        if do_rethrow
            rethrow(err)
        end
        if err isa CommandError || err isa ResolverError
            Base.display_error(repl.t.err_stream, ErrorException(sprint(showerror, err)), Ptr{Nothing}[])
        else
            Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
        end
    end
end

function do_cmd!(command::PkgCommand, repl)
    meta_opts = get_api_opts(command.meta_options, meta_option_specs)
    ctx = Context(meta_opts...)
    spec = command_specs[command.name]
    # TODO is invokelatest still needed?
    Base.invokelatest(spec.handler, ctx, command)

    #=
    if cmd.kind == CMD_PREVIEW
        ctx.preview = true
        isempty(tokens) && cmderror("expected a command to preview")
        cmd = popfirst!(tokens)
    end

    # Using invokelatest to hide the functions from inference.
    # Otherwise it would try to infer everything here.
    cmd.kind == CMD_INIT        ? Base.invokelatest(          do_init!, ctx, tokens) :
    cmd.kind == CMD_HELP        ? Base.invokelatest(          do_help!, ctx, tokens, repl) :
    cmd.kind == CMD_RM          ? Base.invokelatest(            do_rm!, ctx, tokens) :
    cmd.kind == CMD_ADD         ? Base.invokelatest(do_add_or_develop!, ctx, tokens, CMD_ADD) :
    cmd.kind == CMD_CHECKOUT    ? Base.invokelatest(do_add_or_develop!, ctx, tokens, CMD_DEVELOP) :
    cmd.kind == CMD_DEVELOP     ? Base.invokelatest(do_add_or_develop!, ctx, tokens, CMD_DEVELOP) :
    cmd.kind == CMD_UP          ? Base.invokelatest(            do_up!, ctx, tokens) :
    cmd.kind == CMD_STATUS      ? Base.invokelatest(        do_status!, ctx, tokens) :
    cmd.kind == CMD_TEST        ? Base.invokelatest(          do_test!, ctx, tokens) :
    cmd.kind == CMD_GC          ? Base.invokelatest(            do_gc!, ctx, tokens) :
    cmd.kind == CMD_BUILD       ? Base.invokelatest(         do_build!, ctx, tokens) :
    cmd.kind == CMD_PIN         ? Base.invokelatest(           do_pin!, ctx, tokens) :
    cmd.kind == CMD_FREE        ? Base.invokelatest(          do_free!, ctx, tokens) :
    cmd.kind == CMD_GENERATE    ? Base.invokelatest(      do_generate!, ctx, tokens) :
    cmd.kind == CMD_RESOLVE     ? Base.invokelatest(       do_resolve!, ctx, tokens) :
    cmd.kind == CMD_PRECOMPILE  ? Base.invokelatest(    do_precompile!, ctx, tokens) :
    cmd.kind == CMD_INSTANTIATE ? Base.invokelatest(   do_instantiate!, ctx, tokens) :
        cmderror("`$cmd` command not yet implemented")
    =#
end

function do_help!(
    ctk::Context,
    tokens::Vector{Token},
    repl::REPL.AbstractREPL,
)
    disp = REPL.REPLDisplay(repl)
    if isempty(tokens)
        Base.display(disp, help)
        return
    end
    help_md = md""
    for token in tokens
        if token isa Command
            if haskey(helps, token.kind)
                isempty(help_md.content) ||
                push!(help_md.content, md"---")
                push!(help_md.content, helps[token.kind].content)
            else
                cmderror("Sorry, I don't have any help for the `$(token.val)` command.")
            end
        else
            error("invalid usage of help command")
        end
    end
    Base.display(disp, help_md)
end

# TODO set default Display.status keyword: mode = PKGMODE_COMBINED
# - if not possible, do it manually here
function do_status!(ctx::Context, statement::Statement)
    Display.status(ctx, get_api_opts(statement)...)
end

# TODO , test recursive dependencies as on option.
function do_test!(ctx::Context, command::PkgCommand)
    foreach(arg -> arg.mode = PKGMODE_MANIFEST, command.arguments)
    API.test(ctx, command.arguments; get_api_opts(command)...)
end

do_precompile!(ctx::Context, command::PkgCommand) = API.precompile(ctx)

do_resolve!(ctx::Context, command::PkgCommand) = API.resolve(ctx)

do_gc!(ctx::Context, command::PkgCommand) =
    API.gc(ctx; get_api_opts(command)...)

do_instantiate!(ctx::Context, command::PkgCommand) =
    API.instantiate(ctx; get_api_opts(command)...)

do_generate!(ctx::Context, command::PkgCommand) =
    API.generate(ctx, command.arguments[1])

do_build!(ctx::Context, command::PkgCommand) =
    API.build(ctx, command.arguments, get_api_opts(command)...)

do_rm!(ctx::Context, command::PkgCommand) =
    API.rm(ctx, command.arguments; get_api_opts(statement)...)

do_free!(ctx::Context, command::PkgCommand) =
    API.free(ctx, command.arguments; get_api_opts(statement)...)

do_up!(ctx::Context, command::PkgCommand) =
    API.up(ctx, command.arguments; get_api_opts(command)...)

# TODO needs isapplicable?
function do_activate!(command::PkgCommand)
    if isempty(command.arguments)
        return API.activate()
    else
        return API.activate(abspath(command.arguments[1]))
    end
end

function do_pin!(ctx::Context, command::PkgCommand)
    for arg in command.arguments
        if arg.version.lower != arg.version.upper # TODO check for unspecified version
            cmderror("pinning a package requires a single version, not a versionrange")
        end
    end
    API.pin(ctx, command.arguments; get_api_opts(command)...)
end

function do_add_or_develop!(ctx::Context, command::PkgCommand)
    api_opts = get_api_opts(command)
    push!(api_opts, :mode => (command.name == "add" ? :add : :develop))
    return API.add_or_develop(ctx, command.arguments; api_opts...)
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
    MiniREPL(TextDisplay(stdout), REPL.Terminals.TTYTerminal(get(ENV, "TERM", Sys.iswindows() ? "" : "dumb"), stdin, stdout, stderr))
end
REPL.REPLDisplay(repl::MiniREPL) = repl.display


const minirepl = Ref{MiniREPL}()

#= __init__() = =# minirepl[] = MiniREPL()

macro pkg_str(str::String)
    :($(do_cmd)(minirepl[], $str; do_rethrow=true))
end

pkgstr(str::String) = do_cmd(minirepl[], str; do_rethrow=true)

# handle completions
all_commands_sorted = sort(collect(String,keys(command_specs)))
long_commands = filter(c -> length(c) > 2, all_commands_sorted)
# TODO all_options_sorted = [length(opt) > 1 ? "--$opt" : "-$opt" for opt in sort!(collect(keys(opts)))]
all_options_sorted = []
# TODO long_options = filter(c -> length(c) > 2, all_options_sorted)
long_options = []

struct PkgCompletionProvider <: LineEdit.CompletionProvider end

function LineEdit.complete_line(c::PkgCompletionProvider, s)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)
    ret, range, should_complete = completions(full, lastindex(partial))
    return ret, partial[range], should_complete
end

function complete_command(s, i1, i2)
    # only show short form commands when no input is given at all
    cmp = filter(cmd -> startswith(cmd, s), isempty(s) ? all_commands_sorted : long_commands)
    return cmp, i1:i2, !isempty(cmp)
end

function complete_option(s, i1, i2)
    # only show short form options if only a dash is given
    cmp = filter(cmd -> startswith(cmd, s), length(s) == 1 && first(s) == '-' ?
                                                all_options_sorted :
                                                long_options)
    return cmp, i1:i2, !isempty(cmp)
end

function complete_package(s, i1, i2, lastcommand, project_opt)
    if lastcommand in [CMD_STATUS, CMD_RM, CMD_UP, CMD_TEST, CMD_BUILD, CMD_FREE, CMD_PIN, CMD_CHECKOUT]
        return complete_installed_package(s, i1, i2, project_opt)
    elseif lastcommand in [CMD_ADD, CMD_DEVELOP]
        return complete_remote_package(s, i1, i2)
    end
    return String[], 0:-1, false
end

function complete_installed_package(s, i1, i2, project_opt)
    pkgs = project_opt ? API.installed(PKGMODE_PROJECT) : API.installed()
    pkgs = sort!(collect(keys(filter((p) -> p[2] != nothing, pkgs))))
    cmp = filter(cmd -> startswith(cmd, s), pkgs)
    return cmp, i1:i2, !isempty(cmp)
end

function complete_remote_package(s, i1, i2)
    cmp = filter(cmd -> startswith(cmd, s), collect_package_names())
    return cmp, i1:i2, !isempty(cmp)
end

function collect_package_names()
    r = r"name = \"(.*?)\""
    names = String[]
    for reg in Types.registries(;clone_default=false)
        regcontent = read(joinpath(reg, "Registry.toml"), String)
        append!(names, collect(match.captures[1] for match in eachmatch(r, regcontent)))
    end
    return sort!(names)
end

function completions(full, index)
    pre = full[1:index]

    pre_words = split(pre, ' ', keepempty=true)

    # first word should always be a command
    if isempty(pre_words)
        return complete_command("", 1:1)
    else
        to_complete = pre_words[end]
        offset = isempty(to_complete) ? index+1 : to_complete.offset+1

        if length(pre_words) == 1
            return complete_command(to_complete, offset, index)
        end

        # tokenize input, don't offer any completions for invalid commands
        tokens = try
            parse(join(pre_words[1:end-1], ' '))[end]
        catch
            return String[], 0:-1, false
        end

        tokens = reverse!(tokens)

        lastcommand = nothing
        project_opt = true
        for t in tokens
            if t isa Command
                lastcommand = t.kind
                break
            end
        end
        for t in tokens
            if t isa Option && t.kind in [OPT_PROJECT, OPT_MANIFEST]
                project_opt = t.kind == OPT_PROJECT
                break
            end
        end

        if lastcommand in [CMD_HELP, CMD_PREVIEW]
            return complete_command(to_complete, offset, index)
        elseif !isempty(to_complete) && first(to_complete) == '-'
            return complete_option(to_complete, offset, index)
        else
            return complete_package(to_complete, offset, index, lastcommand, project_opt)
        end
    end
end

prev_project_file = nothing
prev_project_timestamp = nothing
prev_prefix = ""

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
            project = try
                Types.read_project(project_file)
            catch
                nothing
            end
            if project !== nothing
                proj_dir = ispath(project_file) ? realpath(project_file) : project_file
                proj_dir = dirname(proj_dir)
                projname = get(project, "name", nothing)
                if startswith(pwd(), proj_dir) && projname !== nothing
                    name = projname
                else
                    name = basename(proj_dir)
                end
                prefix = string("(", name, ") ")
                prev_prefix = prefix
                prev_project_timestamp = mtime(project_file)
                prev_project_file = project_file
            end
        end
    end
    return prefix * "pkg> "
end

# Set up the repl Pkg REPLMode
function create_mode(repl, main)
    pkg_mode = LineEdit.Prompt(promptf;
        prompt_prefix = Base.text_colors[:blue],
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
    if shell_mode != nothing
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

    b = Dict{Any,Any}[
        skeymap, repl_keymap, mk, prefix_keymap, LineEdit.history_keymap,
        LineEdit.default_keymap, LineEdit.escape_defaults
    ]
    pkg_mode.keymap_dict = LineEdit.keymap(b)
    return pkg_mode
end

function repl_init(repl)
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

# TODO handle `preview` -> probably with a wrapper
# TODO concrete difference between API and REPL commands?
# note: it seems like most String args are meant to be package specs
# note: precompile, generate, gc : can be embeded directly
# TODO should warn on zero args?

# nothing means don't count
command_declarations = CommandDeclaration[
    (   ["test"],
        do_test!,
        (ARG_PKG, []),
        [
            ("coverage", OPT_SWITCH, :coverage => true),
        ],
    ),( ["help", "?"],
        do_help!,
        (ARG_RAW, []),
        [],
    ),( ["instantiate"],
        do_instantiate!,
        (ARG_RAW, [0]),
        [
            (["project", "p"], OPT_SWITCH, :manifest => false),
            (["manifest", "m"], OPT_SWITCH, :manifest => true),
        ],
    ),( ["remove", "rm"],
        do_rm!,
        (ARG_PKG, []),
        [
            (["project", "p"], OPT_SWITCH, :mode => PKGMODE_PROJECT),
            (["manifest", "m"], OPT_SWITCH, :mode => PKGMODE_MANIFEST),
        ],
    ),( ["add"],
        do_add_or_develop!,
        (ARG_ALL, []),
        [],
    ),( ["develop", "dev"],
        do_add_or_develop!,
        (ARG_ALL, []),
        [],
    ),( ["free"],
        do_free!,
        (ARG_PKG, []),
        [],
    ),( ["pin"],
        do_pin!,
        (ARG_VERSION, []),
        [],
    ),( ["build"],
        do_build!,
        (ARG_PKG, []),
        [],
    ),( ["resolve"],
        do_resolve!,
        (ARG_RAW, [0]),
        [],
    ),( ["activate"],
        API.activate,
        (ARG_RAW, [0,1]),
        [],
    ),( ["update", "up"],
        do_up!,
        (ARG_VERSION, []),
        [
            (["project", "p"], OPT_SWITCH, :mode => PKGMODE_PROJECT),
            (["manifest", "m"], OPT_SWITCH, :mode => PKGMODE_MANIFEST),
            ("major", OPT_SWITCH, :level => UPLEVEL_MAJOR),
            ("minor", OPT_SWITCH, :level => UPLEVEL_MINOR),
            ("patch", OPT_SWITCH, :level => UPLEVEL_PATCH),
            ("fixed", OPT_SWITCH, :level => UPLEVEL_FIXED),
        ],
    ),( ["generate"],
        do_generate!,
        (ARG_RAW, [1]),
        [],
    ),( ["precompile"],
        do_precompile!,
        (ARG_RAW, [0]),
        [],
    ),( ["status", "st"],
        Display.status,
        (ARG_RAW, [0]),
        [
            (["project", "p"], OPT_SWITCH, :mode => PKGMODE_PROJECT),
            (["manifest", "m"], OPT_SWITCH, :mode => PKGMODE_MANIFEST),
        ],
    ),( ["gc"],
        do_gc!,
        (ARG_RAW, [0]),
        [],
    ),
]

command_specs = init_command_spec(command_declarations) # TODO should this go here ?

const help = md"""

**Welcome to the Pkg REPL-mode**. To return to the `julia>` prompt, either press
backspace when the input line is empty or press Ctrl+C.


**Synopsis**

    pkg> [--env=...] cmd [opts] [args]

Multiple commands can be given on the same line by interleaving a `;` between the commands.

**Environment**

The `--env` meta option determines which project environment to manipulate. By
default, this looks for a git repo in the parents directories of the current
working directory, and if it finds one, it uses that as an environment. Otherwise,
it uses a named environment (typically found in `~/.julia/environments`) looking
for environments named `v$(VERSION.major).$(VERSION.minor).$(VERSION.patch)`,
`v$(VERSION.major).$(VERSION.minor)`,  `v$(VERSION.major)` or `default` in order.

**Commands**

What action you want the package manager to take:

`help`: show this message

`status`: summarize contents of and changes to environment

`add`: add packages to project

`develop`: clone the full package repo locally for development

`rm`: remove packages from project or manifest

`up`: update packages in manifest

`test`: run tests for packages

`build`: run the build script for packages

`pin`: pins the version of packages

`free`: undoes a `pin`, `develop`, or stops tracking a repo.

`instantiate`: downloads all the dependencies for the project

`resolve`: resolves to update the manifest from changes in dependencies of
developed packages

`generate`: generate files for a new project

`preview`: previews a subsequent command without affecting the current state

`precompile`: precompile all the project dependencies

`gc`: garbage collect packages not used for a significant time

`activate`: set the primary environment the package manager manipulates
"""

# TODO should help just be an array parallel to PackageSpec ?
#=
const helps = Dict(
    CMD_HELP => md"""

        help

    Display this message.

        help cmd ...

    Display usage information for commands listed.

    Available commands: `help`, `status`, `add`, `rm`, `up`, `preview`, `gc`, `test`, `build`, `free`, `pin`, `develop`.
    """, CMD_STATUS => md"""

        status
        status [-p|--project]
        status [-m|--manifest]

    Show the status of the current environment. By default, the full contents of
    the project file is summarized, showing what version each package is on and
    how it has changed since the last git commit (if in a git repo), as well as
    any changes to manifest packages not already listed. In `--project` mode, the
    status of the project file is summarized. In `--project` mode, the status of
    the project file is summarized.
    """, CMD_GENERATE => md"""

        generate pkgname

    Create a project called `pkgname` in the current folder.
    """,
    CMD_ADD => md"""

        add pkg[=uuid] [@version] [#rev] ...

    Add package `pkg` to the current project file. If `pkg` could refer to
    multiple different packages, specifying `uuid` allows you to disambiguate.
    `@version` optionally allows specifying which versions of packages. Versions
    may be specified by `@1`, `@1.2`, `@1.2.3`, allowing any version with a prefix
    that matches, or ranges thereof, such as `@1.2-3.4.5`. A git-revision can be
    specified by `#branch` or `#commit`.

    If a local path is used as an argument to `add`, the path needs to be a git repository.
    The project will then track that git repository just like if it is was tracking a remote repository online.

    **Examples**
    ```
    pkg> add Example
    pkg> add Example@0.5
    pkg> add Example#master
    pkg> add Example#c37b675
    pkg> add https://github.com/JuliaLang/Example.jl#master
    pkg> add git@github.com:JuliaLang/Example.jl.git
    pkg> add Example=7876af07-990d-54b4-ab0e-23690620f79a
    ```
    """, CMD_RM => md"""

        rm [-p|--project] pkg[=uuid] ...

    Remove package `pkg` from the project file. Since the name `pkg` can only
    refer to one package in a project this is unambiguous, but you can specify
    a `uuid` anyway, and the command is ignored, with a warning if package name
    and UUID do not mactch. When a package is removed from the project file, it
    may still remain in the manifest if it is required by some other package in
    the project. Project mode operation is the default, so passing `-p` or
    `--project` is optional unless it is preceded by the `-m` or `--manifest`
    options at some earlier point.

        rm [-m|--manifest] pkg[=uuid] ...

    Remove package `pkg` from the manifest file. If the name `pkg` refers to
    multiple packages in the manifest, `uuid` disambiguates it. Removing a package
    from the manifest forces the removal of all packages that depend on it, as well
    as any no-longer-necessary manifest packages due to project package removals.
    """, CMD_UP => md"""

        up [-p|project]  [opts] pkg[=uuid] [@version] ...
        up [-m|manifest] [opts] pkg[=uuid] [@version] ...

        opts: --major | --minor | --patch | --fixed

    Update the indicated package within the constraints of the indicated version
    specifications. Versions may be specified by `@1`, `@1.2`, `@1.2.3`, allowing
    any version with a prefix that matches, or ranges thereof, such as `@1.2-3.4.5`.
    In `--project` mode, package specifications only match project packages, while
    in `manifest` mode they match any manifest package. Bound level options force
    the following packages to be upgraded only within the current major, minor,
    patch version; if the `--fixed` upgrade level is given, then the following
    packages will not be upgraded at all.
    """, CMD_PREVIEW => md"""

        preview cmd

    Runs the command `cmd` in preview mode. This is defined such that no side effects
    will take place i.e. no packages are downloaded and neither the project nor manifest
    is modified.
    """, CMD_TEST => md"""

        test [opts] pkg[=uuid] ...

        opts: --coverage

    Run the tests for package `pkg`. This is done by running the file `test/runtests.jl`
    in the package directory. The option `--coverage` can be used to run the tests with
    coverage enabled. The `startup.jl` file is disabled during testing unless
    julia is started with `--startup-file=yes`.
    """, CMD_GC => md"""

    Deletes packages that cannot be reached from any existing environment.
    """, CMD_BUILD =>md"""

        build pkg[=uuid] ...

    Run the build script in `deps/build.jl` for each package in `pkg` and all of their dependencies in depth-first recursive order.
    If no packages are given, runs the build scripts for all packages in the manifest.
    The `startup.jl` file is disabled during building unless julia is started with `--startup-file=yes`.
    """, CMD_PIN => md"""

        pin pkg[=uuid] ...

    Pin packages to given versions, or the current version if no version is specified. A pinned package has its version fixed and will not be upgraded or downgraded.
    A pinned package has the symbol `⚲` next to its version in the status list.
    """, CMD_FREE => md"""
        free pkg[=uuid] ...

    Free a pinned package `pkg`, which allows it to be upgraded or downgraded again. If the package is checked out (see `help develop`) then this command
    makes the package no longer being checked out.
    """, CMD_DEVELOP => md"""
        develop pkg[=uuid] [#rev] ...

    Make a package available for development. If `pkg` is an existing local path that path will be recorded in
    the manifest and used. Otherwise, a full git clone of `pkg` at rev `rev` is made. The clone is stored in `devdir`,
    which defaults to `~/.julia/dev` and is set by the environment variable `JULIA_PKG_DEVDIR`.
    This operation is undone by `free`.

    *Example*
    ```jl
    pkg> develop Example
    pkg> develop Example#master
    pkg> develop Example#c37b675
    pkg> develop https://github.com/JuliaLang/Example.jl#master
    ```
    """, CMD_PRECOMPILE => md"""
        precompile

    Precompile all the dependencies of the project by running `import` on all of them in a new process.
    The `startup.jl` file is disabled during precompilation unless julia is started with `--startup-file=yes`.
    """, CMD_INSTANTIATE => md"""
        instantiate
        instantiate [-m|--manifest]
        instantiate [-p|--project]

    Download all the dependencies for the current project at the version given by the project's manifest.
    If no manifest exists or the `--project` option is given, resolve and download the dependencies compatible with the project.
    """, CMD_RESOLVE => md"""
        resolve

    Resolve the project i.e. run package resolution and update the Manifest. This is useful in case the dependencies of developed
    packages have changed causing the current Manifest to_indices be out of sync.
    """
)
=#

end #module
