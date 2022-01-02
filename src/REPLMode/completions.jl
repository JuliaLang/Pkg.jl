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
    oldi2 = i2
    if !isempty(s) && s[1] == '~'
        expanded_user = true
        s = expanduser(s)
        i2 += textwidth(homedir()) - 1
    end
    return complete_expanded_local_dir(s, i1, i2, expanded_user, oldi2)  # easiest way to avoid #15276 from boxing `s`
end

function complete_expanded_local_dir(s, i1, i2, expanded_user, oldi2)
    cmp = REPL.REPLCompletions.complete_path(s, i2)
    cmp2 = cmp[2]
    completions = [REPL.REPLCompletions.completion_text(p) for p in cmp[1]]
    completions = filter!(x -> isdir(s[1:prevind(s, first(cmp2)-i1+1)]*x), completions)
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


const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
function complete_remote_package(partial)
    isempty(partial) && return String[]
    cmp = Set{String}()
    for reg in Registry.reachable_registries()
        for (uuid, regpkg) in reg
            name = regpkg.name
            name in cmp && continue
            if startswith(regpkg.name, partial)
                pkg = Registry.registry_info(regpkg)
                compat_info = Registry.compat_info(pkg)
                # Filter versions
                for (v, uncompressed_compat) in compat_info
                    Registry.isyanked(pkg, v) && continue
                    # TODO: Filter based on offline mode
                    is_julia_compat = nothing
                    for (pkg_uuid, vspec) in uncompressed_compat
                        if pkg_uuid == JULIA_UUID
                            found_julia_compat = true
                            is_julia_compat = VERSION in vspec
                            is_julia_compat && continue
                        end
                    end
                    # Found a compatible version or compat on julia at all => compatible
                    if is_julia_compat === nothing || is_julia_compat
                        push!(cmp, name)
                        break
                    end
                end
            end
        end
    end
    return sort!(collect(cmp))
end

function complete_help(options, partial)
    names = String[]
    for cmds in values(SPECS)
         append!(names, [spec.canonical_name for spec in values(cmds)])
    end
    return sort!(unique!(append!(names, collect(keys(SPECS)))))
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

function complete_installed_packages_and_compat(options, partial)
    env = try EnvCache()
    catch err
        err isa PkgError || rethrow()
        return String[]
    end
    return map(vcat(collect(keys(env.project.deps)), "julia")) do d
        compat_str = Operations.get_compat_str(env.project, d)
        isnothing(compat_str) ? d : string(d, " ", compat_str)
    end
end

function complete_add_dev(options, partial, i1, i2)
    comps, idx, _ = complete_local_dir(partial, i1, i2)
    if occursin(Base.Filesystem.path_separator_re, partial)
        return comps, idx, !isempty(comps)
    end
    comps = vcat(comps, sort(complete_remote_package(partial)))
    if !isempty(partial)
        append!(comps, filter!(startswith(partial), first.(values(Types.stdlibs()))))
    end
    return comps, idx, !isempty(comps)
end

########################
# COMPLETION INTERFACE #
########################
function default_commands()
    names = collect(keys(SPECS))
    append!(names, map(x -> getproperty(x, :canonical_name), values(SPECS["package"])))
    return sort(unique(names))
end

function complete_command(statement::Statement, final::Bool, on_sub::Bool)
    if statement.super !== nothing
        if (!on_sub && final) || (on_sub && !final)
            # last thing determined was the super -> complete canonical names of subcommands
            specs = SPECS[statement.super]
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
    offset_adjust = 0
    if length(pre) >= 2 && pre[1] == '?' && pre[2] != ' '
        # supports completion on things like `pkg> ?act` with no space
        pre = string(pre[1], " ", pre[2:end])
        offset_adjust = -1
    end
    last = split(pre, ' ', keepempty=true)[end]
    offset = isempty(last) ? index+1+offset_adjust : last.offset+1+offset_adjust
    final  = isempty(last) # is the cursor still attached to the final token?
    return _completions(pre, final, offset, index)
end
