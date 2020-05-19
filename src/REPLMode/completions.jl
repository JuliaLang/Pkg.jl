########################
# Completion Functions #
########################
function _shared_envs()
    possible = String[]
    for depot in Base.DEPOT_PATH
        envdir = joinpath(depot, "environments")
        isdir(envdir) || continue
        append!(possible, readdir(envdir))
    end
    return possible
end

function complete_activate(options, partial, i1, i2)
    shared = get(options, :shared, false)
    if shared
        return _shared_envs()
    elseif !isempty(partial) && first(partial) == '@'
        return "@" .* _shared_envs()
    else
        return complete_local_dir(partial, i1, i2)
    end
end

function complete_local_dir(s, i1, i2)
    expanded_user = false
    if !isempty(s) && s[1] == '~'
        expanded_user = true
        s = expanduser(s)
        oldi2 = i2
        i2 += textwidth(homedir()) - 1
    end

    cmp = REPL.REPLCompletions.complete_path(s, i2)
    completions = [REPL.REPLCompletions.completion_text(p) for p in cmp[1]]
    completions = filter!(x -> isdir(s[1:prevind(s, first(cmp[2])-i1+1)]*x), completions)
    if expanded_user
        if length(completions) == 1 && endswith(joinpath(homedir(), ""), first(completions))
            completions = [joinpath(s, "")]
        else
            completions = [joinpath(dirname(s), x) for x in completions]
        end
        return completions, i1:oldi2, true
    end

    return completions, cmp[2], !isempty(completions)
end

function complete_remote_package(partial)
    cmp = String[]
    julia_version = VERSION
    ctx = Context()
    for reg in Types.collect_registries()
        data = Types.read_registry(joinpath(reg.path, "Registry.toml"))
        for (uuid, pkginfo) in data["packages"]
            name = pkginfo["name"]
            if startswith(name, partial)
                path = pkginfo["path"]
                version_info = Operations.load_versions(ctx, path; include_yanked=false)
                versions = sort!(collect(keys(version_info)))
                compat_data = Operations.load_package_data(
                    VersionSpec, joinpath(reg.path, path, "Compat.toml"), versions)
                supported_julia_versions = VersionSpec()
                found_julia_compat = false
                for (ver_range, compats) in compat_data
                    for (compat, v) in compats
                        if compat == "julia"
                            found_julia_compat = true
                            union!(supported_julia_versions, VersionSpec(v))
                        end
                    end
                end
                if VERSION in supported_julia_versions || !found_julia_compat
                    push!(cmp, name)
                end
            end
        end
    end
    return cmp
end

function complete_help(options, partial)
    names = String[]
    for cmds in values(SPECS[])
         append!(names, [spec.canonical_name for spec in values(cmds)])
    end
    return sort!(unique!(append!(names, collect(keys(SPECS[])))))
end

function complete_installed_packages(options, partial)
    env = try EnvCache()
    catch err
        err isa PkgError || rethrow()
        return String[]
    end
    mode = get(options, :mode, PKGMODE_PROJECT)
    return mode == PKGMODE_PROJECT ?
        collect(keys(env.project.deps)) :
        unique!([entry.name for (uuid, entry) in env.manifest])
end

function complete_add_dev(options, partial, i1, i2)
    comps, idx, _ = complete_local_dir(partial, i1, i2)
    if occursin(Base.Filesystem.path_separator_re, partial)
        return comps, idx, !isempty(comps)
    end
    comps = vcat(comps, complete_remote_package(partial))
    comps = vcat(comps, filter(x->startswith(x,partial) && !(x in comps),
                               collect(values(Types.stdlibs()))))
    return comps, idx, !isempty(comps)
end

########################
# COMPLETION INTERFACE #
########################
function default_commands()
    names = collect(keys(SPECS[]))
    append!(names, map(x -> getproperty(x, :canonical_name), values(SPECS[]["package"])))
    return sort(unique(names))
end

function complete_command(statement::Statement, final::Bool, on_sub::Bool)
    if statement.super !== nothing
        if (!on_sub && final) || (on_sub && !final)
            # last thing determined was the super -> complete canonical names of subcommands
            specs = SPECS[][statement.super]
            names = map(x -> getproperty(x, :canonical_name), values(specs))
            return sort(unique(names))
        end
    end
    # complete default names
    return default_commands()
end

complete_opt(opt_specs) =
    unique(sort(map(wrap_option,
                    map(x -> getproperty(x, :name),
                        collect(values(opt_specs))))))

function complete_argument(spec::CommandSpec, options::Vector{String},
                           partial::AbstractString, offset::Int,
                           index::Int)
    spec.completions === nothing && return String[]
    # finish parsing opts
    local opts
    try
        opts = APIOptions(map(parse_option, options), spec.option_specs)
    catch e
        e isa PkgError && return String[]
        rethrow()
    end
    return applicable(spec.completions, opts, partial, offset, index) ?
        spec.completions(opts, partial, offset, index) :
        spec.completions(opts, partial)
end

function _completions(input, final, offset, index)
    statement, word_count, partial = nothing, nothing, nothing
    try
        words = tokenize(input)[end]
        word_count = length(words)
        statement, partial = core_parse(words)
        if final
            partial = "" # last token is finalized -> no partial
        end
    catch
        return String[], 0:-1, false
    end
    # number of tokens which specify the command
    command_size = count([statement.super !== nothing, true])
    command_is_focused() = !((word_count == command_size && final) || word_count > command_size)

    if statement.spec === nothing # spec not determined -> complete command
        !command_is_focused() && return String[], 0:-1, false
        x = complete_command(statement, final, word_count == 2)
    else
        command_is_focused() && return String[], 0:-1, false

        if final # complete arg by default
            x = complete_argument(statement.spec, statement.options, partial, offset, index)
        else # complete arg or opt depending on last token
            x = is_opt(partial) ?
                complete_opt(statement.spec.option_specs) :
                complete_argument(statement.spec, statement.options, partial, offset, index)
        end
    end

    # In the case where the completion function wants to deal with indices, it will return a fully
    # computed completion tuple, just return it
    # Else, the completions function will just deal with strings and will return a Vector{String}
    if isa(x, Tuple)
        return x
    else
        possible = filter(possible -> startswith(possible, partial), x)
        return possible, offset:index, !isempty(possible)
    end
end

function completions(full, index)::Tuple{Vector{String},UnitRange{Int},Bool}
    pre = full[1:index]
    isempty(pre) && return default_commands(), 0:-1, false # empty input -> complete commands
    last   = split(pre, ' ', keepempty=true)[end]
    offset = isempty(last) ? index+1 : last.offset+1
    final  = isempty(last) # is the cursor still attached to the final token?
    return _completions(pre, final, offset, index)
end
