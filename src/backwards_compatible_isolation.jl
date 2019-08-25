function _update_manifest(ctx::Context, pkg::PackageSpec, hash::Union{SHA1, Nothing})
    env = ctx.env
    uuid, name, version, path, special_action, repo = pkg.uuid, pkg.name, pkg.version, pkg.path, pkg.special_action, pkg.repo
    hash === nothing && @assert (path != nothing || pkg.uuid in keys(ctx.stdlibs) || pkg.repo.url != nothing)
    # TODO I think ^ assertion is wrong, add-repo should have a hash
    entry = get!(env.manifest, uuid, Types.PackageEntry())
    entry.name = name
    is_stdlib = uuid in keys(ctx.stdlibs)
    if !is_stdlib
        entry.version = version
        entry.tree_hash = hash
        entry.path = path
        if special_action == PKGSPEC_DEVELOPED
            entry.pinned = false
            entry.repo.url = nothing
            entry.repo.rev = nothing
        elseif special_action == PKGSPEC_FREED
            if entry.pinned
                entry.pinned = false
            else
                entry.repo.url = nothing
                entry.repo.rev = nothing
            end
        elseif special_action == PKGSPEC_PINNED
            entry.pinned = true
        elseif special_action == PKGSPEC_REPO_ADDED
            entry.repo.url = repo.url
            entry.repo.rev = repo.rev
            path = find_installed(name, uuid, hash)
        end
        if entry.repo.url !== nothing
            path = find_installed(name, uuid, hash)
        end
    end

    empty!(entry.deps)
    if path !== nothing || is_stdlib
        if is_stdlib
            path = Types.stdlib_path(name)
        else
            path = joinpath(dirname(ctx.env.project_file), path)
        end

        deps = Dict{String,UUID}()

        # Check for deps in project file
        project_file = projectfile_path(path; strict=true)
        if nothing !== project_file
            project = read_project(project_file)
            deps = project.deps
        else
            # Check in REQUIRE file
            # Remove when packages uses Project files properly
            dep_pkgs = PackageSpec[]
            stdlib_deps = find_stdlib_deps(ctx, path)
            for (uuid, name) in stdlib_deps
                push!(dep_pkgs, PackageSpec(name, uuid))
            end
            reqfile = joinpath(path, "REQUIRE")
            if isfile(reqfile)
                for r in Pkg2.Reqs.read(reqfile)
                    r isa Pkg2.Reqs.Requirement || continue
                    push!(dep_pkgs, PackageSpec(name=r.package))
                end
                registry_resolve!(ctx, dep_pkgs)
                project_deps_resolve!(ctx, dep_pkgs)
                ensure_resolved(ctx, dep_pkgs; registry=true)
            end
            for dep_pkg in dep_pkgs
                dep_pkg.name == "julia" && continue
                deps[dep_pkg.name] = dep_pkg.uuid
            end
        end
        entry.deps = deps
    else
        for path in registered_paths(ctx, uuid)
            data = load_package_data(UUID, joinpath(path, "Deps.toml"), version)
            if data !== nothing
                entry.deps = data
                break
            end
        end
    end
    return
end

# Resolve a set of versions given package version specs
function _resolve_versions!(
    ctx::Context,
    pkgs::Vector{PackageSpec},
    target::Union{Nothing, String} = nothing,
)::Dict{UUID,VersionNumber}
    printpkgstyle(ctx, :Resolving, "package versions...")
    # anything not mentioned is fixed
    uuids = UUID[pkg.uuid for pkg in pkgs]
    uuid_to_name = Dict{UUID, String}(uuid => stdlib for (uuid, stdlib) in ctx.stdlibs)
    uuid_to_name[uuid_julia] = "julia"

    for (name::String, uuid::UUID) in get_deps(ctx, target)
        uuid_to_name[uuid] = name

        uuid_idx = findfirst(isequal(uuid), uuids)
        entry = manifest_info(ctx, uuid)
        if entry !== nothing && entry.version !== nothing # stdlibs might not have a version
            ver = VersionSpec(entry.version)
        else
            ver = VersionSpec()
        end
        if uuid_idx != nothing
            pkg = pkgs[uuid_idx]
            if entry !== nothing && pkg.special_action != PKGSPEC_FREED && entry.pinned
                # This is a pinned package, fix its version
                pkg.version = ver
            end
        else
            push!(pkgs, PackageSpec(name, uuid, ver))
        end
    end

    # construct data structures for resolver and call it
    # this also sets pkg.version for fixed packages
    fixed = _collect_fixed!(ctx, pkgs, uuid_to_name)

    # compatibility
    proj_compat = Types.project_compatibility(ctx, "julia")
    v = intersect(VERSION, proj_compat)
    if isempty(v)
        @warn "julia version requirement for project not satisfied" _module=nothing _file=nothing
    end

    for pkg in pkgs
        proj_compat = Types.project_compatibility(ctx, pkg.name)
        v = intersect(pkg.version, proj_compat)
        if isempty(v)
            pkgerror(string("empty intersection between $(pkg.name)@$(pkg.version) and project ",
                            "compatibility $(proj_compat)"))
        end
        # Work around not clobbering 0.x.y+ for checked out old type of packages
        if !(pkg.version isa VersionNumber)
            pkg.version = v
        end
    end

    reqs = Requires(pkg.uuid => VersionSpec(pkg.version) for pkg in pkgs if pkg.uuid ≠ uuid_julia)
    fixed[uuid_julia] = Fixed(VERSION)
    graph = deps_graph(ctx, uuid_to_name, reqs, fixed)

    simplify_graph!(graph)
    vers = resolve(graph)
    find_registered!(ctx, collect(keys(vers)))
    # update vector of package versions
    for pkg in pkgs
        # Fixed packages are not returned by resolve (they already have their version set)
        haskey(vers, pkg.uuid) && (pkg.version = vers[pkg.uuid])
    end
    uuids = UUID[pkg.uuid for pkg in pkgs]
    for (uuid, ver) in vers
        uuid in uuids && continue
        name = (uuid in keys(ctx.stdlibs)) ? ctx.stdlibs[uuid] : registered_name(ctx, uuid)
        push!(pkgs, PackageSpec(;name=name, uuid=uuid, version=ver))
    end
    return vers
end
# This also sets the .path field for fixed packages in `pkgs`
function _collect_fixed!(ctx::Context, pkgs::Vector{PackageSpec}, uuid_to_name::Dict{UUID, String})
    fixed_pkgs = PackageSpec[]
    fix_deps_map = Dict{UUID,Vector{PackageSpec}}()
    uuid_to_pkg = Dict{UUID,PackageSpec}()
    for pkg in pkgs
        local path
        entry = manifest_info(ctx, pkg.uuid)
        if pkg.special_action == PKGSPEC_FREED && !entry.pinned
            continue
        elseif pkg.special_action == PKGSPEC_DEVELOPED
            @assert pkg.path !== nothing
            path = pkg.path
        elseif pkg.special_action == PKGSPEC_REPO_ADDED
            @assert pkg.tree_hash !== nothing
            path = find_installed(pkg.name, pkg.uuid, pkg.tree_hash)
        elseif entry !== nothing && entry.path !== nothing
            path = pkg.path = entry.path
        elseif entry !== nothing && entry.repo.url !== nothing
            path = find_installed(pkg.name, pkg.uuid, entry.tree_hash)
            pkg.repo = entry.repo
            pkg.tree_hash = entry.tree_hash
        else
            continue
        end

        path = project_rel_path(ctx, path)
        if !isdir(path)
            pkgerror("path $(path) for package $(pkg.name) no longer exists. Remove the package or `develop` it at a new path")
        end

        uuid_to_pkg[pkg.uuid] = pkg
        uuid_to_name[pkg.uuid] = pkg.name
        found_project = collect_project!(ctx, pkg, path, fix_deps_map)
        if !found_project
            collect_require!(ctx, pkg, path, fix_deps_map)
        end
    end

    fixed = Dict{UUID,Fixed}()
    # Collect the dependencies for the fixed packages
    for (uuid, fixed_pkgs) in fix_deps_map
        fix_pkg = uuid_to_pkg[uuid]
        v = Dict{VersionNumber,Dict{UUID,VersionSpec}}()
        q = Dict{UUID, VersionSpec}()
        for deppkg in fixed_pkgs
            uuid_to_name[deppkg.uuid] = deppkg.name
            q[deppkg.uuid] = deppkg.version
        end
        fixed[uuid] = Fixed(fix_pkg.version, q)
    end
    return fixed
end

# install & update manifest
function apply_versions(ctx::Context, pkgs::Vector{PackageSpec}; mode=:add, update=true)::Vector{UUID}
    hashes, urls = _version_data!(ctx, pkgs)
    apply_versions(ctx, pkgs, hashes, urls; mode=mode, update=update)
end

function apply_versions(ctx::Context, pkgs::Vector{PackageSpec}, hashes::Dict{UUID,SHA1}, urls::Dict{UUID,Vector{String}}; mode=:add, update=true)
    probe_platform_engines!()
    new_versions = UUID[]

    pkgs_to_install = Tuple{PackageSpec, String}[]
    for pkg in pkgs
        !is_stdlib(ctx, pkg.uuid) || continue
        pkg.path === nothing || continue
        pkg.repo.url === nothing || continue
        path = find_installed(pkg.name, pkg.uuid, hashes[pkg.uuid])
        if !ispath(path)
            push!(pkgs_to_install, (pkg, path))
            push!(new_versions, pkg.uuid)
        end
    end

    widths = [textwidth(pkg.name) for (pkg, _) in pkgs_to_install]
    max_name = length(widths) == 0 ? 0 : maximum(widths)

    ########################################
    # Install from archives asynchronously #
    ########################################
    jobs = Channel(ctx.num_concurrent_downloads);
    results = Channel(ctx.num_concurrent_downloads);
    @async begin
        for pkg in pkgs_to_install
            put!(jobs, pkg)
        end
    end

    for i in 1:ctx.num_concurrent_downloads
        @async begin
            for (pkg, path) in jobs
                if ctx.preview
                    put!(results, (pkg, true, path))
                    continue
                end
                if ctx.use_libgit2_for_all_downloads
                    put!(results, (pkg, false, path))
                    continue
                end
                try
                    success = install_archive(urls[pkg.uuid], hashes[pkg.uuid], path)
                    if success && mode == :add
                        set_readonly(path) # In add mode, files should be read-only
                    end
                    if ctx.use_only_tarballs_for_downloads && !success
                        pkgerror("failed to get tarball from $(urls[pkg.uuid])")
                    end
                    put!(results, (pkg, success, path))
                catch err
                    put!(results, (pkg, err, catch_backtrace()))
                end
            end
        end
    end

    missed_packages = Tuple{PackageSpec, String}[]
    for i in 1:length(pkgs_to_install)
        pkg, exc_or_success, bt_or_path = take!(results)
        exc_or_success isa Exception && pkgerror("Error when installing package $(pkg.name):\n",
                                                 sprint(Base.showerror, exc_or_success, bt_or_path))
        success, path = exc_or_success, bt_or_path
        if success
            vstr = pkg.version != nothing ? "v$(pkg.version)" : "[$h]"
            printpkgstyle(ctx, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
        else
            push!(missed_packages, (pkg, path))
        end
    end

    ##################################################
    # Use LibGit2 to download any remaining packages #
    ##################################################
    for (pkg, path) in missed_packages
        uuid = pkg.uuid
        if !ctx.preview
            install_git(ctx, pkg.uuid, pkg.name, hashes[uuid], urls[uuid], pkg.version::VersionNumber, path)
            if mode == :add
                set_readonly(path)
            end
        end
        vstr = pkg.version != nothing ? "v$(pkg.version)" : "[$h]"
        printpkgstyle(ctx, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
    end

    ##########################################
    # Installation done, update the manifest #
    ##########################################
    if update
        for pkg in pkgs
            uuid = pkg.uuid
            if pkg.path !== nothing || uuid in keys(ctx.stdlibs)
                hash = nothing
            elseif pkg.repo.url !== nothing
                hash = pkg.tree_hash
            else
                hash = hashes[uuid]
            end
            _update_manifest(ctx, pkg, hash)
        end
    end

    prune_manifest(ctx)
    return new_versions
end

function _add_or_develop(ctx::Context, pkgs::Vector{PackageSpec}; new_git = UUID[], mode=:add)
    # copy added name/UUIDs into project
    for pkg in pkgs
        ctx.env.project.deps[pkg.name] = pkg.uuid
    end
    # if a package is in the project file and
    # the manifest version in the specified version set
    # then leave the package as is at the installed version
    for (name::String, uuid::UUID) in ctx.env.project.deps
        entry = manifest_info(ctx, uuid)
        entry !== nothing && entry.version !== nothing || continue
        for pkg in pkgs
            pkg.uuid == uuid && entry.version ∈ pkg.version || continue
            pkg.version = entry.version
        end
    end
    # resolve & apply package versions
    _resolve_versions!(ctx, pkgs)
    new_apply = apply_versions(ctx, pkgs; mode=mode)
    write_env(ctx) # write env before building
    build_versions(ctx, union(new_apply, new_git))
end
# Find repos and hashes for each package UUID & version
function _version_data!(ctx::Context, pkgs::Vector{PackageSpec})
    hashes = Dict{UUID,SHA1}()
    clones = Dict{UUID,Vector{String}}()
    for pkg in pkgs
        !is_stdlib(pkg.uuid) || continue
        pkg.repo.url === nothing || continue
        pkg.path === nothing || continue
        uuid = pkg.uuid
        ver = pkg.version::VersionNumber
        clones[uuid] = String[]
        for path in registered_paths(ctx, uuid)
            info = parse_toml(path, "Package.toml")
            repo = info["repo"]
            repo in clones[uuid] || push!(clones[uuid], repo)
            vers = load_versions(path; include_yanked = true)
            hash = get(vers, ver, nothing)
            hash !== nothing || continue
            if haskey(hashes, uuid)
                hash == hashes[uuid] || @warn "$uuid: hash mismatch for version $ver!"
            else
                hashes[uuid] = hash
            end
        end
        @assert haskey(hashes, uuid)
    end
    foreach(sort!, values(clones))
    return hashes, clones
end

function collect_target_deps!(
    ctx::Context,
    pkgs::Vector{PackageSpec},
    pkg::PackageSpec,
    target::String,
)
    # Find the path to the package
    if pkg.uuid in keys(ctx.stdlibs)
        path = Types.stdlib_path(pkg.name)
    elseif Types.is_project_uuid(ctx, pkg.uuid)
        path = dirname(ctx.env.project_file)
    else
        entry = manifest_info(ctx, pkg.uuid)
        path = (entry.path !== nothing) ?
            project_rel_path(ctx, entry.path) :
            find_installed(pkg.name, pkg.uuid, entry.tree_hash)
    end

    project_path = nothing
    for project_name in Base.project_names
        project_path_cand = joinpath(path, project_name)
        if isfile(project_path_cand)
            project_path = project_path_cand
            break
        end
    end
    project = nothing
    if project_path !== nothing
        project = read_package(project_path)
    end

    # Pkg2 compatibiity with test/REQUIRE
    has_project_test_target = false
    if project !== nothing && !isempty(project.targets)
        has_project_test_target = true
    end
    if target == "test" && !has_project_test_target
        pkg2_test_target_compatibility!(ctx, path, pkgs)
        return
    end

    # Collect target deps from Project
    if project !== nothing
        targets = project.targets
        haskey(targets, target) || return
        for pkg in targets[target]
            uuid = project.extras[pkg]
            push!(pkgs, PackageSpec(pkg, uuid))
        end
    end
    return
end

# When testing or building a dependency, we want that dependency to be able to load its own dependencies
# at top level. Therefore we would like to execute the build or testing of a dependency using its own Project file as
# the current environment. Being backwards compatible with REQUIRE file complicates the story a bit since these packages
# do not have any Project files.
function with_dependencies_loadable_at_toplevel(f, mainctx::Context, pkg::PackageSpec; might_need_to_resolve=false)
    # localctx is the context for the temporary environment we run the testing / building in
    localctx = deepcopy(mainctx)
    localctx.currently_running_target = true
    # If pkg or its dependencies are checked out, we will need to resolve
    # unless we already have resolved for the current environment, which the calleer indicates
    # with `might_need_to_resolve`
    need_to_resolve = false
    is_project = Types.is_project(localctx, pkg)

    target = nothing
    if pkg.special_action == PKGSPEC_TESTED
        target = "test"
    end

    # In order to fix dependencies at their current versions we need to
    # add them as explicit dependencies to the project, but we need to
    # remove them after the resolve to make them not-loadable.
    # See issue https://github.com/JuliaLang/Pkg.jl/issues/1144
    should_be_in_project = Set{UUID}()
    should_be_in_manifest = Set{UUID}()

    # Only put `pkg` and its deps + target deps (recursively) in the temp project
    collect_deps!(seen, pkg; depth) = begin
        # See issue https://github.com/JuliaLang/Pkg.jl/issues/1144
        # depth = 0 - the package itself (should be in project)
        # depth = 1 - direct dependencies/and or target dependencies (should be in project)
        # depth > 1 - indirect dependencies that should only be in the manifest in the end
        if depth <= 1
            push!(should_be_in_project, pkg.uuid)
        else
            push!(should_be_in_manifest, pkg.uuid)
        end
        pkg.uuid in seen && return
        push!(seen, pkg.uuid)
        entry = manifest_info(localctx, pkg.uuid)
        entry === nothing && return
        need_to_resolve |= (entry.path !== nothing)
        localctx.env.project.deps[pkg.name] = pkg.uuid
        for (name, uuid) in entry.deps
            collect_deps!(seen, PackageSpec(name, uuid); depth=depth+1)
        end
    end

    if is_project # testing the project itself
        # the project might have changes made to it so need to resolve
        need_to_resolve = true
        # Since we will create a temp environment in another place we need to extract the project
        # and put it in the Project as a normal `deps` entry and in the Manifest with a path.
        foreach(k->setfield!(localctx.env.project, k, nothing), (:name, :uuid, :version))
        localctx.env.pkg = nothing
        localctx.env.project.deps[pkg.name] = pkg.uuid
        localctx.env.manifest[pkg.uuid] = Types.PackageEntry(
            name=pkg.name,
            deps=get_deps(mainctx, target),
            path=dirname(localctx.env.project_file),
            version=pkg.version,
        )
    else
        # Only put `pkg` and its deps (recursively) in the temp project
        empty!(localctx.env.project.deps)
        localctx.env.project.deps[pkg.name] = pkg.uuid
    end
    # Only put `pkg` and its deps (recursively) in the temp project
    seen_uuids = Set{UUID}()
    collect_deps!(seen_uuids, pkg; depth=0)

    pkgs = PackageSpec[]
    if target !== nothing
        collect_target_deps!(localctx, pkgs, pkg, target)
        for dpkg in pkgs
            # Also put eventual deps of target deps in new manifest
            collect_deps!(seen_uuids, dpkg; depth=1)
        end
    end

    mktempdir() do tmpdir
        localctx.env.project_file = joinpath(tmpdir, "Project.toml")
        localctx.env.manifest_file = joinpath(tmpdir, "Manifest.toml")

        function rewrite_manifests(manifest)
            # Rewrite paths in Manifest since relative paths won't work here due to the temporary environment
            for (uuid, entry) in manifest
                if uuid in keys(localctx.stdlibs)
                    entry.path = Types.stdlib_path(entry.name)
                end
                if entry.path !== nothing
                    entry.path = project_rel_path(mainctx, entry.path)
                end
            end
        end

        rewrite_manifests(localctx.env.manifest)

        # Add target deps to deps (https://github.com/JuliaLang/Pkg.jl/issues/427)
        if !isempty(pkgs)
            target_deps = deepcopy(pkgs)
            _add_or_develop(localctx, pkgs)
            need_to_resolve = false # add resolves
            entry = manifest_info(localctx, pkg.uuid)
            for deppkg in target_deps
                entry.deps[deppkg.name] = deppkg.uuid
            end
        end

        # Might have added stdlibs in `add` above
        rewrite_manifests(localctx.env.manifest)

        local new
        will_resolve = might_need_to_resolve && need_to_resolve
        if will_resolve
            _resolve_versions!(localctx, pkgs)
            new = apply_versions(localctx, pkgs)
        else
            prune_manifest(localctx)
        end
        # Remove deps that we added to the project just to keep their versions fixed,
        # since we know all of the packages should be in the manifest this should be
        # a trivial modification of the project file only.
        # See issue https://github.com/JuliaLang/Pkg.jl/issues/1144
        not_loadable = setdiff(should_be_in_manifest, should_be_in_project)
        Operations.rm(localctx, [PackageSpec(uuid = uuid) for uuid in not_loadable])

        write_env(localctx, display_diff = false)
        will_resolve && build_versions(localctx, new)

        sep = Sys.iswindows() ? ';' : ':'
        withenv("JULIA_LOAD_PATH" => "@$sep$tmpdir", "JULIA_PROJECT"=>nothing) do
            f(localctx)
        end
    end
end

function backwards_compatibility_for_test(
    ctx::Context, pkg::PackageSpec, testfile::String, pkgs_errored::Vector{String},
    coverage; julia_args=``, test_args=``
)
    printpkgstyle(ctx, :Testing, pkg.name)
    if ctx.preview
        @info("In preview mode, skipping tests for $(pkg.name)")
        return
    end
    code = """
        $(Base.load_path_setup_code(false))
        cd($(repr(dirname(testfile))))
        append!(empty!(ARGS), $(repr(test_args.exec)))
        include($(repr(testfile)))
        """
    cmd = ```
        $(Base.julia_cmd())
        --code-coverage=$(coverage ? "user" : "none")
        --color=$(Base.have_color ? "yes" : "no")
        --compiled-modules=$(Bool(Base.JLOptions().use_compiled_modules) ? "yes" : "no")
        --check-bounds=yes
        --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --track-allocation=$(("none", "user", "all")[Base.JLOptions().malloc_log + 1])
        $(julia_args)
        --eval $code
    ```
    run_test = () -> begin
        try
            run(cmd)
            printpkgstyle(ctx, :Testing, pkg.name * " tests passed ")
        catch err
            push!(pkgs_errored, pkg.name)
        end
    end
    with_dependencies_loadable_at_toplevel(ctx, pkg; might_need_to_resolve=true) do localctx
        if !Types.is_project_uuid(ctx, pkg.uuid)
            Display.status(localctx, mode=PKGMODE_MANIFEST)
        end

        run_test()
    end
end

function backwards_compat_for_build(ctx::Context, pkg::PackageSpec, build_file::String, verbose::Bool,
                                    might_need_to_resolve::Bool, max_name::Int)
    log_file = splitext(build_file)[1] * ".log"
    printpkgstyle(ctx, :Building,
        rpad(pkg.name * " ", max_name + 1, "─") * "→ " * Types.pathrepr(log_file))
    code = """
        $(Base.load_path_setup_code(false))
        cd($(repr(dirname(build_file))))
        include($(repr(build_file)))
        """
    cmd = ```
        $(Base.julia_cmd()) -O0 --color=no --history-file=no
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --compiled-modules=$(Bool(Base.JLOptions().use_compiled_modules) ? "yes" : "no")
        --eval $code
        ```
    run_build = () -> begin
        ok = open(log_file, "w") do log
            success(pipeline(cmd, stdout = verbose ? stdout : log, stderr = verbose ? stderr : log))
        end
        if !ok
            n_lines = isinteractive() ? 100 : 5000
            # TODO: Extract last n  lines more efficiently
            log_lines = readlines(log_file)
            log_show = join(log_lines[max(1, length(log_lines) - n_lines):end], '\n')
            full_log_at, last_lines =
            if length(log_lines) > n_lines
                "\n\nFull log at $log_file",
                ", showing the last $n_lines of log"
            else
                "", ""
            end
            @error "Error building `$(pkg.name)`$last_lines: \n$log_show$full_log_at"
        end
    end
    with_dependencies_loadable_at_toplevel(ctx, pkg;
                                           might_need_to_resolve=might_need_to_resolve) do localctx
        run_build()
    end
end

