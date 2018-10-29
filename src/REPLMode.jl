# This file is a part of Julia. License is MIT: https://julialang.org/license

module REPLMode

using Markdown
using UUIDs

import REPL
import REPL: LineEdit, REPLCompletions

import ..devdir, ..Types.casesensitive_isdir, ..TOML
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
struct OptionSpec
    name::String
    short_name::Union{Nothing,String}
    api::Pair{Symbol, Any}
    takes_arg::Bool
end

@enum(OptionClass, OPT_ARG, OPT_SWITCH)
function OptionSpec(;name::String,
                    short_name::Union{Nothing,String}=nothing,
                    takes_arg::Bool=false,
                    api::Pair{Symbol,<:Any})::OptionSpec
    #TODO assert names matching lex regex

    # assert now so that you don't fail at user time
    # see function `REPLMode.APIOptions`
    if takes_arg
        @assert hasmethod(api.second, Tuple{String})
    end
    return OptionSpec(name, short_name, api, takes_arg)
end

const OptionDeclaration = Vector{Pair{Symbol,Any}}
function OptionSpecs(decs::Vector{OptionDeclaration})::Dict{String, OptionSpec}
    specs = Dict()
    for x in decs
        opt_spec = OptionSpec(;x...)
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
    m == nothing && pkgerror("malformed option: ", repr(word))
    option_name = (m.captures[1] != nothing ? m.captures[1] : m.captures[2])
    option_arg = (m.captures[3] == nothing ? nothing : String(m.captures[3]))
    return Option(option_name, option_arg)
end

################
# Command Spec #
################
@enum(CommandKind, CMD_HELP, CMD_RM, CMD_ADD, CMD_DEVELOP, CMD_UP,
                   CMD_STATUS, CMD_TEST, CMD_GC, CMD_BUILD, CMD_PIN,
                   CMD_FREE, CMD_GENERATE, CMD_RESOLVE, CMD_PRECOMPILE,
                   CMD_INSTANTIATE, CMD_ACTIVATE, CMD_PREVIEW,
                   CMD_REGISTRY_ADD,
                   )
@enum(ArgClass, ARG_RAW, ARG_PKG, ARG_VERSION, ARG_REV, ARG_ALL)
struct ArgSpec
    count::Pair
    parser::Function
end

const CommandDeclaration = Vector{Pair{Symbol,Any}}
struct CommandSpec
    kind::CommandKind
    canonical_name::String
    short_name::Union{Nothing,String}
    handler::Union{Nothing,Function}
    argument_spec::ArgSpec
    option_specs::Dict{String, OptionSpec}
    description::String
    help::Union{Nothing, Markdown.MD}
end
command_specs = Dict{String,CommandSpec}() # TODO remove this ?

function SuperSpecs(compound_commands)::Dict{String,Dict{String,CommandSpec}}
    super_specs = Dict()
    for x in compound_commands
        sub_specs = CommandSpecs(x.second)
        name = x.first
        @assert get(super_specs, name, nothing) === nothing # don't overwrite commands
        super_specs[name] = sub_specs
    end
    return super_specs
end

function CommandSpec(;kind::Union{Nothing,CommandKind}=nothing,
                     name::String="",
                     short_name::Union{String,Nothing}=nothing,
                     handler::Union{Nothing,Function}=nothing,
                     option_spec::Vector{OptionDeclaration}=OptionDeclaration[],
                     help::Union{Nothing, Markdown.MD}=nothing,
                     description::String="",
                     arg_count::Pair=(0=>0),
                     arg_parser::Function=identity,
                     )::CommandSpec
    @assert kind !== nothing "Register and specify a `CommandKind`"
    @assert !isempty(name) "Supply a canonical name"
    @assert !isempty(description) "Supply a description"
    return CommandSpec(kind, name, short_name, handler, ArgSpec(arg_count, arg_parser),
                       OptionSpecs(option_spec), description, help)
end

# populate a dictionary: command_name -> command_spec
function CommandSpecs(declarations::Vector{CommandDeclaration})::Dict{String,CommandSpec}
    specs = Dict()
    for dec in declarations
        spec = CommandSpec(;dec...)
        specs[spec.canonical_name] = spec
        if spec.short_name !== nothing
            specs[spec.short_name] = spec
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
    if add_or_develop && casesensitive_isdir(expanduser(word))
        if !occursin(Base.Filesystem.path_separator_re, word)
            @info "resolving package specifier `$word` as a directory at `$(Base.contractuser(abspath(word)))`."
        end
        return PackageSpec(Types.GitRepo(expanduser(word)))
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
        pkgerror("`$word` cannot be parsed as a package")
    end
end

################
# REPL parsing #
################
mutable struct Statement
    command::Union{Nothing,CommandSpec}
    options::Vector{Option}
    arguments::Vector{String}
    preview::Bool
    Statement() = new(nothing, [], [], false)
end

struct QuotedWord
    word::String
    isquoted::Bool
end

function unwrap_option(option::String)
    if startswith(option, "--")
        return length(option) == 2 ? "" : option[3:end]
    elseif length(option) == 2
        return option[end]
    end
end

wrap_option(option::String) =
    length(option) == 1 ? "-$option" : "--$option"

function _statement(words)
    is_option(word) = first(word) == '-'

    # command
    if isempty(words)
        return :cmd, "", nothing, true
    end
    word = popfirst!(words)
    if word == "preview"
        if isempty(words)
            return :cmd, "", nothing, true
        end
        word = popfirst!(words)
    end
    if word in keys(super_specs) # have a super command
        super_name = word
        super = super_specs[word]
        if isempty(words)
            return :sub, "", super_name, true
        end
        word = popfirst!(words)
        command = get(super, word, nothing)
        if command === nothing
            if isempty(words)
                return :sub, word, super_name, true
            else
                return nothing
            end
        end
    elseif get(super_specs["package"], word, nothing) !== nothing # given a "package" command
        command = get(super_specs["package"], word, nothing)
    elseif isempty(words) # try to complete the super command
        return :cmd, word, nothing, true
    else
        return nothing
    end
    if isempty(words)
        return :arg, "", command, true
    end
    word = words[end]
    manifest = any(x->x in ["--manifest", "-m"], filter(is_option, words))
    return is_option(word) ?
        (:opt, word, command, true) :
        (:arg, word, command, !manifest)
end

function parse(cmd::String; for_completions=false)
    # replace new lines with ; to support multiline commands
    cmd = replace(replace(cmd, "\r\n" => "; "), "\n" => "; ")
    # tokenize accoring to whitespace / quotes
    qwords = parse_quotes(cmd)
    # tokenzie unquoted tokens according to pkg REPL syntax
    words = lex(qwords)
    # break up words according to ";"(doing this early makes subsequent processing easier)
    word_groups = group_words(words)
    # create statements
    if for_completions
        return _statement(word_groups[end])
    end
    return map(Statement, word_groups)
end

# vector of words -> structured statement
# minimal checking is done in this phase
function Statement(words)::Statement
    is_option(word) = first(word) == '-'
    statement = Statement()

    isempty(words) && pkgerror("no command specified")
    word = popfirst!(words)

    # command
    # special handling for `preview`
    if word == "preview"
        statement.preview = true
        isempty(words) && pkgerror("preview requires a command")
        word = popfirst!(words)
    end
    if word in keys(super_specs)
        super = super_specs[word]
        isempty(words) && pkgerror("no subcommand specified")
        word = popfirst!(words)
    else
        super = super_specs["package"]
    end
    command = get(super, word, nothing)
    command !== nothing || pkgerror("expected command. instead got [$word]")
    statement.command = command
    # command arguments
    for word in words
        if is_option(word)
            push!(statement.options, parse_option(word))
        else # is argument
            push!(statement.arguments, word)
        end
    end
    return statement
end

# break up words according to `;`(doing this early makes subsequent processing easier)
# the final group does not require a trailing `;`
function group_words(words)::Vector{Vector{String}}
    statements = Vector{String}[]
    x = String[]
    for word in words
        if word == ";"
            isempty(x) ? pkgerror("empty statement") : push!(statements, x)
            x = String[]
        else
            push!(x, word)
        end
    end
    isempty(x) || push!(statements, x)
    return statements
end

const lex_re = r"^[\?\./\+\-](?!\-) | ((git|ssh|http(s)?)|(git@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)(/)? | [^@\#\s;]+\s*=\s*[^@\#\s;]+ | \#\s*[^@\#\s;]* | @\s*[^@\#\s;]* | [^@\#\s;]+|;"x

function lex(qwords::Vector{QuotedWord})::Vector{String}
    words = String[]
    for qword in qwords
        if qword.isquoted
            push!(words, qword.word)
        else
            append!(words, map(m->m.match, eachmatch(lex_re, qword.word)))
        end
    end
    return words
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
        else
            push!(token_in_progress, c)
        end
    end
    if (in_doublequote || in_singlequote)
        pkgerror("unterminated quote")
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
const PackageIdentifier = String
const PackageToken = Union{PackageIdentifier, VersionRange, Rev}
const PkgArguments = Union{Vector{String}, Vector{PackageSpec}}
const APIOptions = Dict{Symbol, Any}
struct PkgCommand
    spec::CommandSpec
    options::APIOptions
    arguments::PkgArguments
    preview::Bool
    PkgCommand() = new([], "", [], [], false)
    PkgCommand(cmd_name, opts, args, preview) = new(cmd_name, opts, args, preview)
end

function APIOptions(options::Vector{Option},
                    specs::Dict{String, OptionSpec},
                    )::APIOptions
    api_options = Dict{Symbol, Any}()
    for option in options
        spec = specs[option.val]
        api_options[spec.api.first] = spec.takes_arg ?
            spec.api.second(option.argument) :
            spec.api.second
    end
    return api_options
end

# Only for PkgSpec
function package_args(args::Vector{PackageToken}; add_or_dev=false)::Vector{PackageSpec}
    # check for and apply PackageSpec modifier (e.g. `#foo` or `@v1.0.2`)
    function apply_modifier!(pkg::PackageSpec, args::Vector{PackageToken})
        if !isempty(args) && !(args[1] isa PackageIdentifier)
            modifier = popfirst!(args)
            if modifier isa VersionRange
                pkg.version = VersionSpec(modifier)
            else # modifier isa Rev
                if pkg.repo === nothing
                    pkg.repo = Types.GitRepo("", modifier.rev)
                else
                    pkg.repo.rev = modifier.rev
                end
            end
        end
    end

    pkgs = PackageSpec[]
    while !isempty(args)
        arg = popfirst!(args)
        if arg isa PackageIdentifier
            pkg = parse_package(arg; add_or_develop=add_or_dev)
            apply_modifier!(pkg, args)
            push!(pkgs, pkg)
        # Modifiers without a corresponding package identifier -- this is a user error
        elseif arg isa VersionRange
            pkgerror("package name/uuid must precede version spec `@$arg`")
        else
            pkgerror("package name/uuid must precede rev spec `#$(arg.rev)`")
        end
    end
    return pkgs
end

# Only for PkgSpec
function word2token(word::AbstractString)::PackageToken
    if first(word) == '@'
        return VersionRange(word[2:end])
    elseif first(word) == '#'
        return Rev(word[2:end])
    else
        return String(word) # PackageIdentifier
    end
end

"""
Parser for PackageSpec objects.
"""
function parse_pkg(raw_args::Vector{String}; valid=[], add_or_dev=false)::Vector{PackageSpec}
    # conver to tokens
    args::Vector{PackageToken} = map(word2token, raw_args)
    # allow only valid tokens
    push!(valid, String) # always want at least PkgSpec identifiers
    if !all(x->typeof(x) in valid, args)
        pkgerror("invalid token")
    end
    # map tokens to PackageSpec objects
    return package_args(args; add_or_dev=add_or_dev)
end

function enforce_option(option::Option, specs::Dict{String,OptionSpec})
    spec = get(specs, option.val, nothing)
    spec !== nothing ||
        pkgerror("option '$(option.val)' is not a valid option")
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
function PkgCommand(statement::Statement)::PkgCommand
    arg_spec = statement.command.argument_spec
    opt_spec = statement.command.option_specs
    # arguments
    arguments = arg_spec.parser(statement.arguments)
    if !(arg_spec.count.first <= length(arguments) <= arg_spec.count.second)
        pkgerror("Wrong number of arguments")
    end
    # options
    enforce_option(statement.options, opt_spec)
    options = APIOptions(statement.options, opt_spec)
    return PkgCommand(statement.command, options, arguments, statement.preview)
end

Context!(ctx::APIOptions)::Context = Types.Context!(collect(ctx))

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
        if err isa PkgError || err isa ResolverError
            Base.display_error(repl.t.err_stream, ErrorException(sprint(showerror, err)), Ptr{Nothing}[])
        else
            Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
        end
    end
end

function do_cmd!(command::PkgCommand, repl)
    context = Dict{Symbol,Any}(:preview => command.preview)

    # REPL specific commands
    if command.spec.kind == CMD_HELP
        return Base.invokelatest(do_help!, command, repl)
    end

    # API commands
    # TODO is invokelatest still needed?
    if applicable(command.spec.handler, context, command.arguments, command.options)
        Base.invokelatest(command.spec.handler, context, command.arguments, command.options)
    else
        Base.invokelatest(command.spec.handler, command.arguments, command.options)
    end
end

function CommandSpec(command_name::String)::Union{Nothing,CommandSpec}
    # maybe a "package" command
    spec = get(super_specs["package"], command_name, nothing)
    if spec !== nothing
        return spec
    end
    # maybe a "compound command"
    m = match(r"(\w+)-(\w+)", command_name)
    m !== nothing || (return nothing)
    super = get(super_specs, m.captures[1], nothing)
    super !== nothing || (return nothing)
    return get(super, m.captures[2], nothing)
end

function do_help!(command::PkgCommand, repl::REPL.AbstractREPL)
    disp = REPL.REPLDisplay(repl)
    if isempty(command.arguments)
        Base.display(disp, help)
        return
    end
    help_md = md""
    for arg in command.arguments
        spec = CommandSpec(arg)
        if spec === nothing
            pkgerror("'$arg' does not name a command")
        end
        spec.help === nothing &&
            pkgerror("Sorry, I don't have any help for the `$arg` command.")
        isempty(help_md.content) ||
            push!(help_md.content, md"---")
        push!(help_md.content, spec.help)
    end
    Base.display(disp, help_md)
end

# TODO set default Display.status keyword: mode = PKGMODE_COMBINED
do_status!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    Display.status(Context!(ctx), get(api_opts, :mode, PKGMODE_COMBINED))

# TODO , test recursive dependencies as on option.
function do_test!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions)
    foreach(arg -> arg.mode = PKGMODE_MANIFEST, args)
    API.test(Context!(ctx), args; collect(api_opts)...)
end

function do_registry_add!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions)
    println("This is a dummy function for now")
    println("My args are:")
    for arg in args
        println("- $arg")
    end
end

do_precompile!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.precompile(Context!(ctx))

do_resolve!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.resolve(Context!(ctx))

do_gc!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.gc(Context!(ctx); collect(api_opts)...)

do_instantiate!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.instantiate(Context!(ctx); collect(api_opts)...)

do_generate!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.generate(Context!(ctx), args[1])

do_build!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.build(Context!(ctx), args; collect(api_opts)...)

do_rm!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.rm(Context!(ctx), args; collect(api_opts)...)

do_free!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.free(Context!(ctx), args; collect(api_opts)...)

do_up!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions) =
    API.up(Context!(ctx), args; collect(api_opts)...)

function do_activate!(args::PkgArguments, api_opts::APIOptions)
    if isempty(args)
        return API.activate()
    else
        return API.activate(expanduser(args[1]); collect(api_opts)...)
    end
end

function do_pin!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions)
    for arg in args
        # TODO not sure this is correct
        if arg.version.ranges[1].lower != arg.version.ranges[1].upper
            pkgerror("pinning a package requires a single version, not a versionrange")
        end
    end
    API.pin(Context!(ctx), args; collect(api_opts)...)
end

function do_add!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions)
    api_opts[:mode] = :add
    API.add_or_develop(Context!(ctx), args; collect(api_opts)...)
end

function do_develop!(ctx::APIOptions, args::PkgArguments, api_opts::APIOptions)
    api_opts[:mode] = :develop
    API.add_or_develop(Context!(ctx), args; collect(api_opts)...)
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

__init__() = minirepl[] = MiniREPL()

macro pkg_str(str::String)
    :($(do_cmd)(minirepl[], $str; do_rethrow=true))
end

pkgstr(str::String) = do_cmd(minirepl[], str; do_rethrow=true)

# handle completions
mutable struct CompletionCache
    commands::Vector{String}
    canonical_names::Vector{String}
    options::Dict{CommandKind, Vector{String}}
    subcommands::Dict{String, Vector{String}}
    CompletionCache() = new([],[],Dict(),Dict())
end

completion_cache = CompletionCache()

struct PkgCompletionProvider <: LineEdit.CompletionProvider end

function LineEdit.complete_line(c::PkgCompletionProvider, s)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)
    ret, range, should_complete = completions(full, lastindex(partial))
    return ret, partial[range], should_complete
end

function complete_local_path(s, i1, i2)
    cmp = REPL.REPLCompletions.complete_path(s, i2)
    completions = [REPL.REPLCompletions.completion_text(p) for p in cmp[1]]
    completions = filter!(x -> isdir(s[1:prevind(s, first(cmp[2])-i1+1)]*x), completions)
    return completions, cmp[2], !isempty(completions)
end

function complete_installed_package(s, i1, i2, project_opt)
    pkgs = project_opt ? API.__installed(PKGMODE_PROJECT) : API.__installed()
    pkgs = sort!(collect(keys(filter(p->p[1] in stdlib_names() || p[2] !== nothing, pkgs))))
    cmp = filter(cmd -> startswith(cmd, s), pkgs)
    return cmp, i1:i2, !isempty(cmp)
end

function complete_remote_package(s, i1, i2)
    cmp = String[]
    julia_version = VERSION
    for reg in Types.registries(;clone_default=false)
        data = Types.read_registry(joinpath(reg, "Registry.toml"))
        for (uuid, pkginfo) in data["packages"]
            name = pkginfo["name"]
            if startswith(name, s)
                compat_data = Operations.load_package_data_raw(
                    VersionSpec, joinpath(reg, pkginfo["path"], "Compat.toml"))
                supported_julia_versions = VersionSpec(VersionRange[])
                for (ver_range, compats) in compat_data
                    for (compat, v) in compats
                        if compat == "julia"
                            union!(supported_julia_versions, VersionSpec(v))
                        end
                    end
                end
                if VERSION in supported_julia_versions
                    push!(cmp, name)
                end
            end
        end
    end
    return cmp, i1:i2, !isempty(cmp)
end

const STDLIB_NAMES = Ref{Vector{String}}()
function stdlib_names()
    if !isassigned(STDLIB_NAMES)
        STDLIB_NAMES[] = filter!(x->isdir(joinpath(Types.stdlib_dir(), x)),
                                 readdir(Types.stdlib_dir()))
    end
    return STDLIB_NAMES[]
end

function complete_argument(to_complete, i1, i2, lastcommand, project_opt
                           )::Tuple{Vector{String},UnitRange{Int},Bool}
    if lastcommand == CMD_HELP
        completions = filter(x->startswith(x,to_complete), completion_cache.canonical_names)
        return completions, i1:i2, !isempty(completions)
    elseif lastcommand in [CMD_STATUS, CMD_RM, CMD_UP, CMD_TEST, CMD_BUILD, CMD_FREE, CMD_PIN]
        return complete_installed_package(to_complete, i1, i2, project_opt)
    elseif lastcommand in [CMD_ADD, CMD_DEVELOP]
        if occursin(Base.Filesystem.path_separator_re, to_complete)
            return complete_local_path(to_complete, i1, i2)
        else
            completions = vcat(complete_remote_package(to_complete, i1, i2)[1],
                               complete_local_path(to_complete, i1, i2)[1])
            completions = vcat(completions,
                               filter(x->startswith(x,to_complete) && !(x in completions),
                                      stdlib_names()))
            return completions, i1:i2, !isempty(completions)
        end
    end
    return String[], 0:-1, false
end

function completions(full, index)::Tuple{Vector{String},UnitRange{Int},Bool}
    pre = full[1:index]
    if isempty(pre)
        return completion_cache.commands, 0:-1, false
    end
    x = parse(pre; for_completions=true)
    if x === nothing # failed parse (invalid command name)
        return String[], 0:-1, false
    end
    (key::Symbol, to_complete::String, spec, proj::Bool) = x
    last = split(pre, ' ', keepempty=true)[end]
    offset = isempty(last) ? index+1 : last.offset+1
    if last != to_complete # require a space before completing next field
        return String[], 0:-1, false
    end
    if key == :arg
        return complete_argument(to_complete, offset, index, spec.kind, proj)
    end
    possible::Vector{String} =
        key == :cmd ? completion_cache.commands :
        key == :sub ? completion_cache.subcommands[spec] :
        key == :opt ? completion_cache.options[spec.kind] :
        String[]
    completions = filter(x->startswith(x,to_complete), possible)
    return completions, offset:index, !isempty(completions)
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
                projname = project.name
                if projname !== nothing
                    name = projname
                else
                    name = basename(dirname(project_file))
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
command_declarations = [
#=
"registry" => CommandDeclaration[
[
    :kind => CMD_REGISTRY_ADD,
    :name => "add",
    :handler => do_registry_add!,
    :arg_count => 1 => Inf,
    :description => "Currently just a placeholder for a future command",
],
], #registry
=#
"package" => CommandDeclaration[
[   :kind => CMD_TEST,
    :name => "test",
    :handler => do_test!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_pkg,
    :option_spec => OptionDeclaration[
        [:name => "coverage", :api => :coverage => true],
    ],
    :description => "run tests for packages",
    :help => md"""

    test [opts] pkg[=uuid] ...

    opts: --coverage

Run the tests for package `pkg`. This is done by running the file `test/runtests.jl`
in the package directory. The option `--coverage` can be used to run the tests with
coverage enabled. The `startup.jl` file is disabled during testing unless
julia is started with `--startup-file=yes`.
    """,
],[ :kind => CMD_HELP,
    :name => "help",
    :short_name => "?",
    :arg_count => 0 => Inf,
    :description => "show this message",
    :help => md"""

    help

Display this message.

    help cmd ...

Display usage information for commands listed.

Available commands: `help`, `status`, `add`, `rm`, `up`, `preview`, `gc`, `test`, `build`, `free`, `pin`, `develop`.
    """,
],[ :kind => CMD_INSTANTIATE,
    :name => "instantiate",
    :handler => do_instantiate!,
    :option_spec => OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :manifest => false],
        [:name => "manifest", :short_name => "m", :api => :manifest => true],
    ],
    :description => "downloads all the dependencies for the project",
    :help => md"""
    instantiate
    instantiate [-m|--manifest]
    instantiate [-p|--project]

Download all the dependencies for the current project at the version given by the project's manifest.
If no manifest exists or the `--project` option is given, resolve and download the dependencies compatible with the project.
    """,
],[ :kind => CMD_RM,
    :name => "remove",
    :short_name => "rm",
    :handler => do_rm!,
    :arg_count => 1 => Inf,
    :arg_parser => parse_pkg,
    :option_spec => OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
    ],
    :description => "remove packages from project or manifest",
    :help => md"""

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
    """,
],[ :kind => CMD_ADD,
    :name => "add",
    :handler => do_add!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_pkg(x; add_or_dev=true, valid=[VersionRange, Rev])),
    :description => "add packages to project",
    :help => md"""

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
    """,
],[ :kind => CMD_DEVELOP,
    :name => "develop",
    :short_name => "dev",
    :handler => do_develop!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_pkg(x; add_or_dev=true, valid=[VersionRange])),
    :option_spec => OptionDeclaration[
        [:name => "local", :api => :shared => false],
        [:name => "shared", :api => :shared => true],
    ],
    :description => "clone the full package repo locally for development",
    :help => md"""
    develop [--shared|--local] pkg[=uuid] ...

Make a package available for development. If `pkg` is an existing local path that path will be recorded in
the manifest and used. Otherwise, a full git clone of `pkg` at rev `rev` is made. The location of the clone is
controlled by the `--shared` (default) and `--local` arguments. The `--shared` location defaults to
`~/.julia/dev`, but can be controlled with the `JULIA_PKG_DEVDIR` environment variable. When `--local` is given,
the clone is placed in a `dev` folder in the current project.
This operation is undone by `free`.

*Example*
```jl
pkg> develop Example
pkg> develop https://github.com/JuliaLang/Example.jl
pkg> develop ~/mypackages/Example
pkg> develop --local Example
```
    """,
],[ :kind => CMD_FREE,
    :name => "free",
    :handler => do_free!,
    :arg_count => 1 => Inf,
    :arg_parser => parse_pkg,
    :description => "undoes a `pin`, `develop`, or stops tracking a repo",
    :help => md"""
    free pkg[=uuid] ...

Free a pinned package `pkg`, which allows it to be upgraded or downgraded again. If the package is checked out (see `help develop`) then this command
makes the package no longer being checked out.
    """,
],[ :kind => CMD_PIN,
    :name => "pin",
    :handler => do_pin!,
    :arg_count => 1 => Inf,
    :arg_parser => (x -> parse_pkg(x; valid=[VersionRange])),
    :description => "pins the version of packages",
    :help => md"""

    pin pkg[=uuid] ...

Pin packages to given versions, or the current version if no version is specified. A pinned package has its version fixed and will not be upgraded or downgraded.
A pinned package has the symbol `⚲` next to its version in the status list.
    """,
],[ :kind => CMD_BUILD,
    :name => "build",
    :handler => do_build!,
    :arg_count => 0 => Inf,
    :arg_parser => parse_pkg,
    :option_spec => OptionDeclaration[
        [:name => "verbose", :short_name => "v", :api => :verbose => true],
    ],
    :description => "run the build script for packages",
    :help => md"""
>>>>>>> Refactor command declarations

    build [-v|verbose] pkg[=uuid] ...

Run the build script in `deps/build.jl` for each package in `pkg` and all of their dependencies in depth-first recursive order.
If no packages are given, runs the build scripts for all packages in the manifest.
The `-v`/`--verbose` option redirects build output to `stdout`/`stderr` instead of the `build.log` file.
The `startup.jl` file is disabled during building unless julia is started with `--startup-file=yes`.
    """,
],[ :kind => CMD_RESOLVE,
    :name => "resolve",
    :handler => do_resolve!,
    :description => "resolves to update the manifest from changes in dependencies of developed packages",
    :help => md"""
    resolve

Resolve the project i.e. run package resolution and update the Manifest. This is useful in case the dependencies of developed
packages have changed causing the current Manifest to be out of sync.
    """,
],[ :kind => CMD_ACTIVATE,
    :name => "activate",
    :handler => do_activate!,
    :arg_count => 0 => 1,
    :option_spec => OptionDeclaration[
        [:name => "shared", :api => :shared => true],
    ],
    :description => "set the primary environment the package manager manipulates",
    :help => md"""
    activate
    activate [--shared] path

Activate the environment at the given `path`, or the home project environment if no `path` is specified.
The active environment is the environment that is modified by executing package commands.
When the option `--shared` is given, `path` will be assumed to be a directory name and searched for in the
`environments` folders of the depots in the depot stack. In case no such environment exists in any of the depots,
it will be placed in the first depot of the stack.
    """ ,
],[ :kind => CMD_UP,
    :name => "update",
    :short_name => "up",
    :handler => do_up!,
    :arg_count => 0 => Inf,
    :arg_parser => (x -> parse_pkg(x; valid=[VersionRange])),
    :option_spec => OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
        [:name => "major", :api => :level => UPLEVEL_MAJOR],
        [:name => "minor", :api => :level => UPLEVEL_MINOR],
        [:name => "patch", :api => :level => UPLEVEL_PATCH],
        [:name => "fixed", :api => :level => UPLEVEL_FIXED],
    ],
    :description => "update packages in manifest",
    :help => md"""

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
    """,
],[ :kind => CMD_GENERATE,
    :name => "generate",
    :handler => do_generate!,
    :arg_count => 1 => 1,
    :description => "generate files for a new project",
    :help => md"""

    generate pkgname

Create a project called `pkgname` in the current folder.
    """,
],[ :kind => CMD_PRECOMPILE,
    :name => "precompile",
    :handler => do_precompile!,
    :description => "precompile all the project dependencies",
    :help => md"""
    precompile

Precompile all the dependencies of the project by running `import` on all of them in a new process.
The `startup.jl` file is disabled during precompilation unless julia is started with `--startup-file=yes`.
    """,
],[ :kind => CMD_STATUS,
    :name => "status",
    :short_name => "st",
    :handler => do_status!,
    :option_spec => OptionDeclaration[
        [:name => "project", :short_name => "p", :api => :mode => PKGMODE_PROJECT],
        [:name => "manifest", :short_name => "m", :api => :mode => PKGMODE_MANIFEST],
    ],
    :description => "summarize contents of and changes to environment",
    :help => md"""

    status
    status [-p|--project]
    status [-m|--manifest]

Show the status of the current environment. By default, the full contents of
the project file is summarized, showing what version each package is on and
how it has changed since the last git commit (if in a git repo), as well as
any changes to manifest packages not already listed. In `--project` mode, the
status of the project file is summarized. In `--manifest` mode the output also
includes the dependencies of explicitly added packages.
    """,
],[ :kind => CMD_GC,
    :name => "gc",
    :handler => do_gc!,
    :description => "garbage collect packages not used for a significant time",
    :help => md"""

Deletes packages that cannot be reached from any existing environment.
    """,
],[ # preview is not a regular command.
    # this is here so that preview appears as a registered command to users
    :kind => CMD_PREVIEW,
    :name => "preview",
    :description => "previews a subsequent command without affecting the current state",
    :help => md"""

    preview cmd

Runs the command `cmd` in preview mode. This is defined such that no side effects
will take place i.e. no packages are downloaded and neither the project nor manifest
is modified.
    """,
],
], #package
] #command_declarations

super_specs = SuperSpecs(command_declarations)
# cache things you need for completions
completion_cache.commands = sort(append!(collect(keys(super_specs)),
                                         collect(keys(super_specs["package"]))))
let names = String[]
    for (super, specs) in pairs(super_specs)
        super == "package" && continue # skip "package"
        for spec in unique(values(specs))
            push!(names, join([super, spec.canonical_name], "-"))
        end
    end
    for spec in unique(values(super_specs["package"]))
        push!(names, spec.canonical_name)
    end
    completion_cache.canonical_names = names
    sort!(completion_cache.canonical_names)
end
for (k, v) in pairs(super_specs)
    completion_cache.subcommands[k] = sort(collect(keys(v)))
    for spec in values(v)
        completion_cache.options[spec.kind] =
            sort(map(wrap_option, collect(keys(spec.option_specs))))
    end
end
# TODO remove this
command_specs = super_specs["package"]

const help = md"""

**Welcome to the Pkg REPL-mode**. To return to the `julia>` prompt, either press
backspace when the input line is empty or press Ctrl+C.


**Synopsis**

    pkg> cmd [opts] [args]

Multiple commands can be given on the same line by interleaving a `;` between the commands.

**Commands**
"""

for command in completion_cache.canonical_names
    spec = CommandSpec(command)
    push!(help.content, Markdown.parse("`$command`: $(spec.description)"))
end

end #module
