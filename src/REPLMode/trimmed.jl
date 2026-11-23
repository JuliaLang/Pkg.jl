# A trimmed binary can not call the `Function`s stored in the command tables (`spec.api`,
# the argument parsers, the option parsers) nor splat the options `Dict` as keywords.
# Here the built-in commands are run with calls that are known statically instead.

function trimmed_command_key(spec::CommandSpec)
    for (super, specs) in SPECS
        for (_, s) in specs
            s === spec && return super, spec.canonical_name
        end
    end
    pkgerror("unknown command `$(spec.canonical_name)`")
end

opt(options::APIOptions, key::Symbol, default::T) where {T} = get(options, key, default)::T

function trimmed_option_value(spec::OptionSpec, option::Option)
    spec.takes_arg || return spec.api.second
    spec.api.first === :preserve && return do_preserve(option.argument::String)
    pkgerror("option `$(spec.name)` is not supported by this build of `pkg`")
end

function trimmed_parse_arguments(spec::CommandSpec, args::Vector{QString}, options::APIOptions)
    super, name = trimmed_command_key(spec)
    if super == "package"
        name == "add" && return parse_add(args, options)
        name == "develop" && return parse_package(args, options; add_or_dev = true)
        name == "activate" && return String[x isa QString ? x.raw : x::String for x in parse_activate(args, options)]
        name == "generate" && return map(expanduser, unwrap(args))
        name in ("help", "precompile", "compat", "instantiate", "resolve", "gc", "undo", "redo") && return unwrap(args)
        return parse_package(args, options)
    elseif super == "registry"
        name == "add" && return parse_registry(args, options; add = true)
        name == "status" && return unwrap(args)
        return parse_registry(args, options)
    end
    pkgerror("`$super $name` is not available in this build of `pkg`")
end

function trimmed_do_cmd(command::Command, io::IO)
    spec = command.spec::CommandSpec
    super, name = trimmed_command_key(spec)
    o = command.options
    args = command.arguments
    if super == "registry"
        name == "add" && return Registry.add(args::Vector{RegistrySpec})
        name == "remove" && return Registry.rm(args::Vector{RegistrySpec})
        name == "update" && return Registry.update(args::Vector{RegistrySpec})
        name == "status" && return Registry.status()
    elseif super == "package"
        if name == "help"
            # the help texts are `Markdown`, which can not be rendered in a trimmed binary
            println(io, spec.description)
            return
        end
        pkgs = args isa Vector{PackageSpec} ? args : PackageSpec[]
        strs = args isa Vector{String} ? args : String[]
        if name == "status"
            return API.status(
                pkgs; mode = opt(o, :mode, PKGMODE_PROJECT), diff = opt(o, :diff, false),
                workspace = opt(o, :workspace, false), outdated = opt(o, :outdated, false),
                deprecated = opt(o, :deprecated, false), compat = opt(o, :compat, false),
                extensions = opt(o, :extensions, false)
            )
        elseif name == "add"
            preserve = opt(o, :preserve, Operations.default_preserve())
            target = opt(o, :target, :deps)
            lazy = opt(o, :lazy, false)
            from = get(o, :from, nothing)
            from isa Vector{String} && return API.add(pkgs; preserve, target, lazy, from)
            return API.add(pkgs; preserve, target, lazy)
        elseif name == "develop"
            return API.develop(
                pkgs; preserve = opt(o, :preserve, Operations.default_preserve()),
                shared = opt(o, :shared, true), strict = opt(o, :strict, false)
            )
        elseif name == "remove"
            return API.rm(pkgs; mode = opt(o, :mode, PKGMODE_PROJECT), all_pkgs = opt(o, :all_pkgs, false))
        elseif name == "update"
            level = opt(o, :level, UPLEVEL_MAJOR)
            mode = opt(o, :mode, PKGMODE_PROJECT)
            workspace = opt(o, :workspace, false)
            lazy = opt(o, :lazy, false)
            haskey(o, :preserve) &&
                return API.up(pkgs; level, mode, workspace, lazy, preserve = o[:preserve]::PreserveLevel)
            return API.up(pkgs; level, mode, workspace, lazy)
        elseif name == "resolve"
            return API.resolve(; lazy = opt(o, :lazy, false))
        elseif name == "instantiate"
            kw = (;
                verbose = opt(o, :verbose, false), workspace = opt(o, :workspace, false),
                julia_version_strict = opt(o, :julia_version_strict, false),
                update_on_mismatch = opt(o, :update_on_mismatch, false),
            )
            haskey(o, :manifest) && return API.instantiate(; manifest = o[:manifest]::Bool, kw...)
            return API.instantiate(; kw...)
        elseif name == "pin"
            return API.pin(pkgs; all_pkgs = opt(o, :all_pkgs, false), workspace = opt(o, :workspace, false))
        elseif name == "free"
            return API.free(pkgs; all_pkgs = opt(o, :all_pkgs, false), workspace = opt(o, :workspace, false))
        elseif name == "why"
            return API.why(pkgs; workspace = opt(o, :workspace, false), forward = opt(o, :forward, false))
        elseif name == "gc"
            return API.gc(; verbose = opt(o, :verbose, false))
        elseif name == "generate"
            return API.generate(only(strs))
        elseif name == "activate"
            shared = opt(o, :shared, false)
            isempty(strs) && return API.activate(; temp = opt(o, :temp, false), shared, prev = opt(o, :prev, false))
            return API.activate(only(strs); shared, temp = opt(o, :temp, false))
        end
    end
    pkgerror("`$(super == "package" ? "" : super * " ")$name` is not available in this build of `pkg`")
end
