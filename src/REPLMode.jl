module REPLMode

import ..Pkg3
import ..Pkg3: default_dev_path
using ..Pkg3: Types, Display, Operations

import Base: LineEdit, REPL, REPLCompletions
import Base.Random: UUID
using Base.Markdown

const cmds = Dict(
    "help"      => :help,
    "?"         => :help,
    "status"    => :status,
    "st"        => :status,
    "."         => :status,
    "search"    => :search,
    "find"      => :search,
    "/"         => :search,
    "add"       => :add,
    "install"   => :add,
    "+"         => :add,
    "rm"        => :rm,
    "remove"    => :rm,
    "uninstall" => :rm,
    "-"         => :rm,
    "up"        => :up,
    "update"    => :up,
    "upgrade"   => :up,
    "test"      => :test,
    "gc"        => :gc,
    "fsck"      => :fsck,
    "preview"   => :preview,
    "init"      => :init,
    "build"     => :build,
    "clone"     => :clone,
    "free"      => :free,
)

const opts = Dict(
    "env"      => :env,
    "project"  => :project,
    "p"        => :project,
    "manifest" => :manifest,
    "m"        => :manifest,
    "major"    => :major,
    "minor"    => :minor,
    "patch"    => :patch,
    "fixed"    => :fixed,
    "coverage" => :coverage,
    "path"     => :path,
    "name"     => :name,
)

function parse_option(word::AbstractString)
    m = match(r"^(?: -([a-z]) | --([a-z]{2,})(?:\s*=\s*(\S*))? )$"ix, word)
    m == nothing && cmderror("invalid option: ", repr(word))
    k = m.captures[1] != nothing ? m.captures[1] : m.captures[2]
    haskey(opts, k) || cmderror("invalid option: ", repr(word))
    m.captures[3] == nothing ?
        (:opt, opts[k]) : (:opt, opts[k], String(m.captures[3]))
end

function parse_string(word::AbstractString)
    if !endswith(word, "\"")
        cmderror("invalid string syntax, expected ending `\"`")
    end
    str = word[chr2ind(word, 2):chr2ind(word, length(word)-1)]
    return (:string, str)
end

let uuid = raw"(?i)[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}(?-i)",
    name = raw"(\w+)(?:\.jl)?"
    global const name_re = Regex("^$name\$")
    global const uuid_re = Regex("^$uuid\$")
    global const name_uuid_re = Regex("^$name\\s*=\\s*($uuid)\$")
end

const lex_re = r"^[\?\./\+\-](?!\-) | [^@\s]+\s*=\s*[^@\s]+ | @\s*[^@\s]* | [^@\s]+"x

function tokenize(cmd::String)::Vector{Tuple{Symbol,Vararg{Any}}}
    tokens = Tuple{Symbol,Vararg{Any}}[]
    words = map(m->m.match, eachmatch(lex_re, cmd))
    help_mode = false
    while !isempty(words)
        word = shift!(words)
        if word[1] == '-' && length(word) > 1
            push!(tokens, parse_option(word))
        else
            word in keys(cmds) || cmderror("invalid command: ", repr(word))
            push!(tokens, (:cmd, cmds[word]))
            help_mode || cmds[word] != :help && break
            help_mode = true
        end
    end
    if isempty(tokens) || tokens[end][1] != :cmd
        cmderror("no package command given")
    end
    while !isempty(words)
        word = shift!(words)
        if word[1] == '"'
            push!(tokens, parse_string(word))
        elseif word[1] == '-'
            push!(tokens, parse_option(word))
        elseif word[1] == '@'
            push!(tokens, (:ver, VersionRange(strip(word[2:end]))))
        elseif ismatch(uuid_re, word)
            push!(tokens, (:pkg, UUID(word)))
        elseif ismatch(name_re, word)
            push!(tokens, (:pkg, String(match(name_re, word).captures[1])))
        elseif ismatch(name_uuid_re, word)
            m = match(name_uuid_re, word)
            push!(tokens, (:pkg, String(m.captures[1]), UUID(m.captures[2])))
        else
            cmderror("invalid argument: ", repr(word))
        end
    end
    return tokens
end

function do_cmd(repl::Base.REPL.AbstractREPL, input::String)
    try
        tokens = tokenize(input)
        do_cmd!(tokens, repl)
    catch err
        if err isa CommandError
            Base.display_error(repl.t.err_stream, ErrorException(err.msg), Ptr{Void}[])
        else
            Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
        end
    end
end

function do_cmd!(tokens, repl; preview = false)
    local cmd::Symbol
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :cmd
            cmd = token[2]
            break
        elseif token[1] == :opt
            if token[2] == :env
                length(token) == 3 ||
                    cmderror("the `--env` option requires a value")
                env_opt = token[3]
            else
                cmderror("unrecognized option: `--$(token[2])`")
            end
        else
            cmderror("misplaced token: ", token)
        end
    end
    cmd == :init && return do_init!(tokens)
    cmd == :preview && return do_preview!(tokens, repl)
    local env_opt::Union{String,Void} = get(ENV, "JULIA_ENV", nothing)
    env = EnvCache(env_opt)
    preview && (env.preview[] = true)
    cmd == :help    ?    do_help!(env, tokens, repl) :
    cmd == :rm      ?      do_rm!(env, tokens) :
    cmd == :add     ?     do_add!(env, tokens) :
    cmd == :up      ?      do_up!(env, tokens) :
    cmd == :status  ?  do_status!(env, tokens) :
    cmd == :test    ?    do_test!(env, tokens) :
    cmd == :gc      ?      do_gc!(env, tokens) :
    cmd == :build   ?   do_build!(env, tokens) :
    cmd == :clone   ?   do_clone!(env, tokens) :
    cmd == :free    ?    do_free!(env, tokens) :
        cmderror("`$cmd` command not yet implemented")
end

function do_preview!(tokens, repl)
    isempty(tokens) && cmderror("`preview` needs a command")
    word = tokens[1][2]
    word in keys(cmds) || cmderror("invalid command: ", repr(word))
    cmds[word] == :init && cmderror("cannot run `init` in preview mode")
    tokens[1] = (:cmd, cmds[word])
    do_cmd!(tokens, repl, preview = true)
end

const help = Base.Markdown.parse("""
    **Synopsis**

        pkg> [--env=...] cmd [opts] [args]

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

    `rm`: remove packages from project or manifest

    `up`: update packages in manifest

    `preview`: previews a subsequent command without affecting the current state

    `test`: run tests for packages

    `gc`: garbage collect packages not used for a significant time

    `init`: initializes an environment in the current, or git base, directory

    `build`: run the build script for packages

    `clone`: clones a package from an url to a local directory

    `free`: start using the registered version of a package instead of the cloned one
    """)

const helps = Dict(
    :help => md"""

        help

    Display this message.

        help cmd ...

    Display usage information for commands listed.

    Available commands: `help`, `status`, `add`, `rm`, `up`
    """, :status => md"""

        status
        status [-p|--project]
        status [-m|--manifest]

    Show the status of the current environment. By default, the full contents of
    the project file is summarized, showing what version each package is on and
    how it has changed since the last git commit (if in a git repo), as well as
    any changes to manifest packages not already listed. In `--project` mode, the
    status of the project file is summarized. In `--project` mode, the status of
    the project file is summarized.
    """, :add => md"""

        add pkg[=uuid] [@version] ...

    Add package `pkg` to the current project file. If `pkg` could refer to
    multiple different packages, specifying `uuid` allows you to disambiguate.
    `@version` optionally allows specifying which versions of packages. Versions
    may be specified by `@1`, `@1.2`, `@1.2.3`, allowing any version with a prefix
    that matches, or ranges thereof, such as `@1.2-3.4.5`.
    """, :rm => md"""

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
    """, :up => md"""

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
    """, :preview => md"""

        preview cmd

    Runs the command `cmd` in preview mode. This is defined such that no side effects
    will take place i.e. no packages are downloaded and neither the project nor manifest
    is modified.
    """, :test => md"""

        test [opts] pkg[=uuid] ...

        opts: --coverage

    Run the tests for package `pkg`. This is done by running the file `test/runtests.jl`
    in the package directory. The option `--coverage` can be used to run the tests with
    coverage enabled.
    """, :gc => md"""

    Deletes packages that are not reached from any environment used within the last 6 weeks.
    """, :init => md"""

        init

    Creates an environment in the current directory, or the git base directory if the current directory
    is in a git repository.
    """, :build =>md"""

        build pkg[=uuid] ...

    Run the build script in deps/build.jl for each package in pkgs and all of their dependencies in depth-first recursive order.
    If no packages are given, runs the build scripts for all packages in the manifest.
    """, :clone => md"""

        clone url [--path localpath]

    Clones the package from the git repo at `url` to the path `localpath`, defaulting to `.julia/dev/`
    in the home directory. A cloned package have its dependencies read from the packages local dependency file
    instead of the registry. It is never be upgraded, removed, or changed in any way by
    the package manager. If the package `localpath` exist, no cloning is done and the existing
    package at that path is used. To `free` a package, i.e., go back to using the the versioned
    package, use `free`.
    """, :free => md"""

        free pkg[=uuid]

    Undo the clone command on `pkg`, i.e., instead of using the path where `pkg`
    was cloned to when loading it, use the standard versioned path.
    This allows the package to again be upgraded.
    The directory where the package was originally cloned at is left untouched.
    """
)

function do_help!(
    env::EnvCache,
    tokens::Vector{Tuple{Symbol,Vararg{Any}}},
    repl::Base.REPL.AbstractREPL,
)
    disp = Base.REPL.REPLDisplay(repl)
    if isempty(tokens)
        Base.display(disp, help)
        return
    end
    help_md = md""
    for token in tokens
        if token[1] == :cmd
            if haskey(helps, token[2])
                isempty(help_md.content) ||
                push!(help_md.content, md"---")
                push!(help_md.content, helps[token[2]].content)
            else
                cmderror("Sorry, I don't have any help for the `$(token[2])` command.")
            end
        else
            error("This should not happen")
        end
    end
    Base.display(disp, help_md)
end

function do_rm!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    # tokens: package names and/or uuids
    mode = :project
    pkgs = PackageSpec[]
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :pkg
            push!(pkgs, PackageSpec(token[2:end]...))
            pkgs[end].mode = mode
        elseif token[1] == :ver
            cmderror("`rm` does not take version specs")
        elseif token[1] == :opt
            if token[2] in (:project, :manifest)
                length(token) == 2 ||
                    cmderror("the --$(token[2]) option does not take an argument")
                mode = token[2]
            else
                cmderror("invalid option for `rm`: --$(token[2])")
            end
        elseif token[1] == :string
            cmderror("unexpected string encountered: $(token[2])")
        end
    end
    isempty(pkgs) &&
        cmderror("`rm` – list packages to remove")
    Pkg3.API.rm(env, pkgs)
end

function do_add!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    # tokens: package names and/or uuids, optionally followed by version specs
    isempty(tokens) &&
        cmderror("`add` – list packages to add")
    tokens[1][1] == :ver &&
        cmderror("package name/uuid must precede version spec `@$(tokens[1][2])`")
    pkgs = PackageSpec[]
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :pkg
            push!(pkgs, PackageSpec(token[2:end]...))
        elseif token[1] == :ver
            pkgs[end].version = VersionSpec(token[2])
            isempty(tokens) || tokens[1][1] == :pkg ||
                cmderror("package name/uuid must precede version spec `@$(tokens[1][2])`")
        elseif token[1] == :opt
            cmderror("`add` doesn't take options: --$(join(token[2:end], '='))")
        elseif token[1] == :string
            cmderror("unexpected string encountered: $(token[2])")
        end
    end
    Pkg3.API.add(env, pkgs)
end

function do_up!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    # tokens:
    #  - upgrade levels as options: --[fixed|patch|minor|major]
    #  - package names and/or uuids, optionally followed by version specs
    mode = :project
    pkgs = PackageSpec[]
    level = UpgradeLevel(:major)
    last_token_type = :cmd
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :pkg
            push!(pkgs, PackageSpec(token[2:end]..., level))
            pkgs[end].mode = mode
        elseif token[1] == :ver
            pkgs[end].version = VersionSpec(token[2])
            last_token_type == :pkg ||
                cmderror("package name/uuid must precede version spec `@$(token[2])`")
        elseif token[1] == :opt
            if token[2] in (:project, :manifest)
                length(token) == 2 ||
                    cmderror("the --$(token[2]) option does not take an argument")
                mode = token[2]
            elseif token[2] in (:major, :minor, :patch, :fixed)
                length(token) == 2 ||
                    cmderror("the --$(token[2]) option does not take an argument")
                level = UpgradeLevel(token[2])
            else
                cmderror("invalid option for `up`: --$(token[2])")
            end
        elseif token[1] == :string
            cmderror("unexpected string encountered: $(token[2])")
        end
        last_token_type = token[1]
    end
    Pkg3.API.up(env, pkgs; level=level, mode=mode)
end

function do_status!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    mode = :combined
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :opt
            if token[2] in (:project, :manifest)
                length(token) == 2 ||
                    cmderror("the --$(token[2]) option does not take an argument")
                mode = token[2]
            else
                cmderror("invalid option for `status`: --$(token[2])")
            end
        else
            cmderror("`status` does not take arguments")
        end
    end
    Pkg3.Display.status(env, mode)
end

# TODO , test recursive dependencies as on option.
function do_test!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    pkgs = PackageSpec[]
    coverage = false
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :pkg
            if length(token) == 2
                pkg = PackageSpec(token[2])
                pkg.mode = :manifest
                push!(pkgs, pkg)
            else
                cmderror("`test` only takes a set of packages to test")
            end
        elseif token[1] == :opt
            if token[2] == :coverage
                coverage = true
            else
                cmderror("invalid option for `test`: --$(token[2])")
            end
        else
            # TODO: Better error message
            cmderror("invalid usage for `test`")
        end
    end
    isempty(pkgs) && cmderror("`test` takes a set of packages")
    Pkg3.API.test(env, pkgs; coverage = coverage)
end

function do_gc!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    !isempty(tokens) && cmderror("`gc` does not take any arguments")
    Pkg3.API.gc(env)
end

function do_build!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    pkgs = PackageSpec[]
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :pkg
            push!(pkgs, PackageSpec(token[2:end]...))
        else
            cmderror("`build` only takes a list of packages")
        end
    end
    Pkg3.API.build(env, pkgs)
end

function do_init!(tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    if !isempty(tokens)
        cmderror("`init` does currently not take any arguments")
    end
    Pkg3.API.init(pwd())
end

function do_clone!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    isempty(tokens) && cmderror("`clone` take an url to a package to clone")
    local url
    basepath = get(ENV, "JULIA_DEVDIR", default_dev_path())
    token = shift!(tokens)
    if token[1] != :string
        cmderror("expected a url given as a string")
    end
    url = token[2]
    if !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :opt
            if token[2] == :path
                if isempty(tokens)
                    cmderror("expected an argument to the `--path` option")
                else
                    token = shift!(tokens)
                    if token[1] != :string
                        cmderror("expecetd a string argument to the `--path` option")
                    else
                        basepath = token[2]
                    end
                end
            else
                cmderror("`clone` only support the `--path` option")
            end
        end
    end
    Pkg3.API.clone(env, url, basepath = basepath)
end

function do_free!(env::EnvCache, tokens::Vector{Tuple{Symbol,Vararg{Any}}})
    pkgs = PackageSpec[]
    while !isempty(tokens)
        token = shift!(tokens)
        if token[1] == :pkg
            push!(pkgs, PackageSpec(token[2:end]...))
        else
            cmderror("free only takes a list of packages")
        end
    end
    Pkg3.API.free(env, pkgs)
end


function create_mode(repl, main)
    pkg_mode = LineEdit.Prompt("pkg> ";
        prompt_prefix = Base.text_colors[:blue],
        prompt_suffix = "",
        sticky = true)

    if VERSION >= v"0.7.0-DEV.1747"
        pkg_mode.repl = repl
    end

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

    b = Dict{Any,Any}[
        skeymap, mk, prefix_keymap, LineEdit.history_keymap,
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

end
