using ..Pkg: logdir

function collect_manifests()
    manifest_usage = joinpath(logdir(), "manifest_usage.toml")
    files = [file for (file, info) in TOML.parse(read(manifest_usage, String))]
    unique!(sort!(filter!(isfile, files)))
    return files
end

function do_env_list!(args::PkgArguments, api_opts::APIOptions)
    manifests = collect_manifests()
    printpkgstyle(Context(), :Active, "manifests:")
    for (i, manifest) in enumerate(manifests)
        println("      [", i, "] ", pathrepr(manifest))
    end
end

function do_env_rm!(args::PkgArguments, api_opts::APIOptions)
    manifests = collect_manifests()
    selected = nothing
    if isinteractive()
        # prompt for which UUID was intended:
        menu = REPL.TerminalMenus.MultiSelectMenu(manifests)
        choice = REPL.TerminalMenus.request("foobar", menu)
        choice == -1 && return UUID(zero(UInt128))
        env.paths[choices_cache[choice][1]] = [choices_cache[choice][2]]
        selected = choices_cache[choice][1]
        printpkgstyle(Context(), :Active, "manifests:")
    else
        error()
    end
    println("Removeing: ", selected)
end
