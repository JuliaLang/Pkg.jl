# This file is a part of Julia. License is MIT: https://julialang.org/license

module Operations

using UUIDs
using Random: randstring
import LibGit2

import REPL
using REPL.TerminalMenus
using ..Types, ..Resolve, ..PlatformEngines, ..GitTools
import ..depots, ..depots1, ..devdir, ..set_readonly, ..Types.PackageEntry
import ..Artifacts: ensure_all_artifacts_installed, artifact_names, extract_all_hashes, artifact_exists
using ..BinaryPlatforms
import ...Pkg
import ...Pkg: pkg_server

#########
# Utils #
#########
uuids(pkgs::Vector{PackageSpec}) = UUID[pkg.uuid for pkg in pkgs]
projectdir(ctx::Context) = dirname(ctx.env.project_file)
function find_installed(name::String, uuid::UUID, sha1::SHA1)
    slug_default = Base.version_slug(uuid, sha1)
    # 4 used to be the default so look there first
    for slug in (Base.version_slug(uuid, sha1, 4), slug_default)
        for depot in depots()
            path = abspath(depot, "packages", name, slug)
            ispath(path) && return path
        end
    end
    return abspath(depots1(), "packages", name, slug_default)
end

# more accurate name is `should_be_tracking_registered_version`
# the only way to know for sure is to key into the registries
tracking_registered_version(pkg) =
    !is_stdlib(pkg.uuid) && pkg.path === nothing && pkg.repo.source === nothing

function source_path(ctx::Context, pkg::PackageSpec)
    return is_stdlib(pkg.uuid)      ? Types.stdlib_path(pkg.name) :
        pkg.path        !== nothing ? project_rel_path(ctx, pkg.path) :
        pkg.repo.source !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        pkg.tree_hash   !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        nothing
end


#TODO rename
function load_version(version, fixed, preserve::PreserveLevel)
    if version === nothing
        return VersionSpec() # stdlibs dont have a version
    elseif fixed
        return version # dont change state if a package is fixed
    elseif preserve == PRESERVE_ALL || preserve == PRESERVE_DIRECT
        return something(version, VersionSpec())
    elseif preserve == PRESERVE_SEMVER && version != VersionSpec()
        return Types.semver_spec("$(version.major).$(version.minor).$(version.patch)")
    elseif preserve == PRESERVE_NONE
        return VersionSpec()
    end
end

function PackageSpec(uuid::UUID, entry::PackageEntry)
    return PackageSpec(;
        uuid      = uuid,
        name      = entry.name,
        path      = entry.path,
        repo      = entry.repo,
        pinned    = entry.pinned,
        tree_hash = entry.tree_hash,
        version   = something(entry.version, VersionSpec())
    )
end

# TODO should preserve_none nuke the git revision?
function load_direct_deps(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[], new::Vector{UUID}=UUID[];
                          unregistered::Bool=true, preserve::PreserveLevel=PRESERVE_DIRECT,
                          keep=nothing)
    pkgs = copy(pkgs) # TODO this is needed for resolve tiers, but perhaps does not belong here
    for (name::String, uuid::UUID) in ctx.env.project.deps
        keep !== nothing && !in(uuid, keep) && continue
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        entry = manifest_info(ctx, uuid)
        pkg = nothing
        if entry === nothing
            source = get(ctx.env.project.source, name, nothing)
            if source !== nothing && unregistered
                pkg = handle_unregistered_pkg(ctx, projectdir(ctx), source, new)
                collect_unregistered!(ctx, pkg, pkgs, new)
            else
                pkg = PackageSpec(; uuid = uuid, name = name, repo = GitRepo(; source = source))
            end
        else
            pkg = PackageSpec(;
                uuid      = uuid,
                name      = name,
                path      = entry.path,
                repo      = entry.repo,
                pinned    = entry.pinned,
                tree_hash = entry.tree_hash,
                version   = load_version(entry.version, isfixed(entry), preserve),
              )
            if !is_tracking_registry(pkg) && unregistered
                collect_unregistered_fixed!(ctx, pkg, pkgs)
            end
        end
        push!(pkgs, pkg)
    end
    return pkgs
end

function load_manifest_deps(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[];
                            preserve::PreserveLevel=PRESERVE_ALL)
    pkgs = copy(pkgs)
    for (uuid, entry) in ctx.env.manifest
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        push!(pkgs, PackageSpec(
            uuid      = uuid,
            name      = entry.name,
            path      = entry.path,
            pinned    = entry.pinned,
            repo      = entry.repo,
            tree_hash = entry.tree_hash,
            version   = load_version(entry.version, isfixed(entry), preserve),
        ))
    end
    return pkgs
end

function load_all_deps(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[], new::Vector{UUID}=UUID[];
                       preserve::PreserveLevel=PRESERVE_ALL)
    pkgs = load_direct_deps(ctx, pkgs, new; preserve=preserve)
    return load_manifest_deps(ctx, pkgs; preserve=preserve)
end

function is_instantiated(ctx::Context)::Bool
    # Load everything
    pkgs = load_all_deps(ctx)
    # Make sure all paths exist
    for pkg in pkgs
        sourcepath = Operations.source_path(ctx, pkg)
        isdir(sourcepath) || return false
        check_artifacts_downloaded(sourcepath) || return false
    end
    return true
end

function update_env!(ctx::Context, pkgs::Vector{PackageSpec})
    # update manifest
    empty!(ctx.env.manifest)
    for pkg in pkgs
        entry = PackageEntry(;name = pkg.name, version = pkg.version, pinned = pkg.pinned,
                             tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo)
        is_stdlib(pkg.uuid) && (entry.version = nothing) # do not set version for stdlibs
        entry.deps = load_deps(ctx, pkg)
        ctx.env.manifest[pkg.uuid] = entry
    end
    # update project
    for pkg in pkgs
        pkg.uuid in values(ctx.env.project.deps) || continue
        !is_tracking_registry(pkg) || continue
        pkg.repo.source !== nothing || continue # old style project files discard the source when tracking path
        ctx.env.project.source[pkg.name] = pkg.repo.source
    end
    # remove unnecesary sources for project
    for (name, uuid) in ctx.env.project.deps
        name in keys(ctx.env.project.source) && continue
        delete!(ctx.env.project.source, name)
    end
end

####################
# Registry Loading #
####################
function load_package_data(f::Base.Callable, path::String, versions)
    toml = parse_toml(path, fakeit=true)
    data = Dict{VersionNumber,Dict{String,Any}}()
    for ver in versions
        ver::VersionNumber
        for (v, d) in toml, (key, value) in d
            vr = VersionRange(v)
            ver in vr || continue
            dict = get!(data, ver, Dict{String,Any}())
            haskey(dict, key) && pkgerror("$ver/$key is duplicated in $path")
            dict[key] = f(value)
        end
    end
    return data
end

load_package_data(f::Base.Callable, path::String, version::VersionNumber) =
    get(load_package_data(f, path, [version]), version, nothing)

function load_package_data_raw(T::Type, path::String)
    toml = parse_toml(path, fakeit=true)
    data = Dict{VersionRange,Dict{String,T}}()
    for (v, d) in toml, (key, value) in d
        vr = VersionRange(v)
        dict = get!(data, vr, Dict{String,T}())
        haskey(dict, key) && pkgerror("$vr/$key is duplicated in $path")
        dict[key] = T(value)
    end
    return data
end

function load_versions(path::String; include_yanked = false)
    toml = parse_toml(path, "Versions.toml"; fakeit=true)
    return Dict{VersionNumber, SHA1}(
        VersionNumber(ver) => SHA1(info["git-tree-sha1"]) for (ver, info) in toml
            if !get(info, "yanked", false) || include_yanked)
end

function load_tree_hash(ctx::Context, pkg::PackageSpec)
    hashes = SHA1[]
    for path in registered_paths(ctx, pkg.uuid)
        vers = load_versions(path; include_yanked = true)
        hash = get(vers, pkg.version, nothing)
        hash !== nothing && push!(hashes, hash)
    end
    isempty(hashes) && return nothing
    length(unique!(hashes)) == 1 || pkgerror("hash mismatch")
    return hashes[1]
end

function load_tree_hashes!(ctx::Context, pkgs::Vector{PackageSpec})
    for pkg in pkgs
        tracking_registered_version(pkg) || continue
        pkg.tree_hash = load_tree_hash(ctx, pkg)
    end
end

#######################################
# Dependency gathering and resolution #
#######################################
function set_maximum_version_registry!(ctx::Context, pkg::PackageSpec)
    pkgversions = Set{VersionNumber}()
    for path in registered_paths(ctx, pkg.uuid)
        pathvers = keys(load_versions(path; include_yanked = false))
        union!(pkgversions, pathvers)
    end
    if length(pkgversions) == 0
        pkg.version = VersionNumber(0)
    else
        max_version = maximum(pkgversions)
        pkg.version = VersionNumber(max_version.major, max_version.minor, max_version.patch, max_version.prerelease, ("",))
    end
end

function load_deps(ctx::Context, pkg::PackageSpec)::Dict{String,UUID}
    if tracking_registered_version(pkg)
        for path in registered_paths(ctx, pkg.uuid)
            data = load_package_data(UUID, joinpath(path, "Deps.toml"), pkg.version)
            data !== nothing && return data
        end
        return Dict{String,UUID}()
    else
        path = project_rel_path(ctx, source_path(ctx, pkg))
        project_file = projectfile_path(path; strict=true)
        project_file === nothing && pkgerror("could not find Project file for package $(pkg.name)")
        project = read_project(project_file)
        return project.deps
    end
end

function collect_project!(ctx::Context, pkg::PackageSpec, path::String,
                          deps_map::Dict{UUID,Vector{PackageSpec}})
    deps_map[pkg.uuid] = PackageSpec[]
    project_file = projectfile_path(path; strict=true)
    if project_file === nothing
        pkgerror("could not find project file for package $(err_rep(pkg)) at `$path`")
    end
    project = read_package(project_file)
    julia_compat = get(project.compat, "julia", nothing)
    if julia_compat !== nothing && !(VERSION in Types.semver_spec(julia_compat))
        println(ctx.io, "julia version requirement for package $(err_rep(pkg)) not satisfied")
    end
    for (name, uuid) in project.deps
        vspec = Types.semver_spec(get(project.compat, name, ">= 0"))
        push!(deps_map[pkg.uuid], PackageSpec(name, uuid, vspec))
    end
    if project.version !== nothing
        pkg.version = project.version
    else
        # @warn "project file for $(pkg.name) is missing a `version` entry"
        set_maximum_version_registry!(ctx, pkg)
    end
    return
end

is_tracking_path(pkg) = pkg.path !== nothing
is_tracking_repo(pkg) = !is_tracking_path(pkg) && (pkg.repo.source !== nothing || pkg.repo.rev !== nothing)
is_tracking_registry(pkg) = !is_tracking_path(pkg) && !is_tracking_repo(pkg)
isfixed(pkg) = !is_tracking_registry(pkg) || pkg.pinned

function collect_fixed!(ctx::Context, pkgs::Vector{PackageSpec}, names::Dict{UUID, String})
    deps_map = Dict{UUID,Vector{PackageSpec}}()
    for pkg in pkgs
        path = project_rel_path(ctx, source_path(ctx, pkg))
        if !isdir(path)
            pkgerror("expected package $(err_rep(pkg)) to exist at path `$path`")
        end
        collect_project!(ctx, pkg, path, deps_map)
    end

    fixed = Dict{UUID,Resolve.Fixed}()
    # Collect the dependencies for the fixed packages
    for (uuid, deps) in deps_map
        idx = findfirst(pkg -> pkg.uuid == uuid, pkgs)
        fix_pkg = pkgs[idx]
        q = Dict{UUID, VersionSpec}()
        for dep in deps
            names[dep.uuid] = dep.name
            q[dep.uuid] = dep.version
        end
        fixed[uuid] = Resolve.Fixed(fix_pkg.version, q)
    end
    return fixed
end


function project_compatibility(ctx::Context, name::String)
    return VersionSpec(Types.semver_spec(get(ctx.env.project.compat, name, ">= 0")))
end

# Resolve a set of versions given package version specs
# looks at uuid, version, repo/path,
# sets version to a VersionNumber
# adds any other packages which may be in the dependency graph
# all versioned packges should have a `tree_hash`
function resolve_versions!(ctx::Context, pkgs::Vector{PackageSpec})
    check_registered(ctx, pkgs)
    # compatibility
    v = intersect(VERSION, project_compatibility(ctx, "julia"))
    if isempty(v)
        @warn "julia version requirement for project not satisfied" _module=nothing _file=nothing
    end
    names = Dict{UUID, String}(uuid => stdlib for (uuid, stdlib) in stdlibs())
    # construct data structures for resolver and call it
    # this also sets pkg.version for fixed packages
    fixed = collect_fixed!(ctx, filter(!is_tracking_registry, pkgs), names)
    # non fixed packages are `add`ed by version: their version is either restricted or free
    # fixed packages are `dev`ed or `add`ed by repo
    # at this point, fixed packages have a version and `deps`

    # check compat
    for pkg in pkgs
        compat = project_compatibility(ctx, pkg.name)
        v = intersect(pkg.version, compat)
        if isempty(v)
            throw(Resolve.ResolverError(
                "empty intersection between $(pkg.name)@$(pkg.version) and project compatibility $(compat)"))
        end
        # Work around not clobbering 0.x.y+ for checked out old type of packages
        if !(pkg.version isa VersionNumber)
            pkg.version = v
        end
    end

    for pkg in pkgs
        names[pkg.uuid] = pkg.name
    end
    reqs = Resolve.Requires(pkg.uuid => VersionSpec(pkg.version) for pkg in pkgs)
    graph = deps_graph(ctx, names, reqs, fixed)
    Resolve.simplify_graph!(graph)
    vers = Resolve.resolve(graph)

    find_registered!(ctx, collect(keys(vers)))
    # update vector of package versions
    for (uuid, ver) in vers
        idx = findfirst(p -> p.uuid == uuid, pkgs)
        if idx !== nothing
            pkg = pkgs[idx]
            # Fixed packages are not returned by resolve (they already have their version set)
            pkg.version = vers[pkg.uuid]
        else
            name = is_stdlib(uuid) ? stdlibs()[uuid] : registered_name(ctx, uuid)
            push!(pkgs, PackageSpec(;name=name, uuid=uuid, version=ver))
        end
    end
    load_tree_hashes!(ctx, pkgs)
end

get_or_make!(d::Dict{K,V}, k::K) where {K,V} = get!(d, k) do; V() end

function deps_graph(ctx::Context, uuid_to_name::Dict{UUID,String}, reqs::Resolve.Requires, fixed::Dict{UUID,Resolve.Fixed})
    uuids = collect(union(keys(reqs), keys(fixed), map(fx->keys(fx.requires), values(fixed))...))
    seen = UUID[]

    all_versions = Dict{UUID,Set{VersionNumber}}()
    all_deps     = Dict{UUID,Dict{VersionRange,Dict{String,UUID}}}()
    all_compat   = Dict{UUID,Dict{VersionRange,Dict{String,VersionSpec}}}()

    for (fp, fx) in fixed
        all_versions[fp] = Set([fx.version])
        all_deps[fp]     = Dict(VersionRange(fx.version) => Dict())
        all_compat[fp]   = Dict(VersionRange(fx.version) => Dict())
    end

    while true
        unseen = setdiff(uuids, seen)
        isempty(unseen) && break
        for uuid in unseen
            push!(seen, uuid)
            uuid in keys(fixed) && continue
            all_versions_u = get_or_make!(all_versions, uuid)
            all_deps_u     = get_or_make!(all_deps,     uuid)
            all_compat_u   = get_or_make!(all_compat,   uuid)

            # Collect deps + compat for stdlib
            if is_stdlib(uuid)
                path = Types.stdlib_path(stdlibs()[uuid])
                proj_file = projectfile_path(path; strict=true)
                @assert proj_file !== nothing
                proj = read_package(proj_file)

                v = something(proj.version, VERSION)
                push!(all_versions_u, v)
                vr = VersionRange(v)

                all_deps_u_vr = get_or_make!(all_deps_u, vr)
                for (name, other_uuid) in proj.deps
                    all_deps_u_vr[name] = other_uuid
                    other_uuid in uuids || push!(uuids, other_uuid)
                end

                # TODO look at compat section for stdlibs?
                all_compat_u_vr = get_or_make!(all_compat_u, vr)
                for (name, other_uuid) in proj.deps
                    all_compat_u_vr[name] = VersionSpec()
                end
            else
                for path in registered_paths(ctx, uuid)
                    version_info = load_versions(path; include_yanked = false)
                    versions = sort!(collect(keys(version_info)))
                    deps_data = load_package_data_raw(UUID, joinpath(path, "Deps.toml"))
                    compat_data = load_package_data_raw(VersionSpec, joinpath(path, "Compat.toml"))

                    union!(all_versions_u, versions)

                    for (vr, dd) in deps_data
                        all_deps_u_vr = get_or_make!(all_deps_u, vr)
                        for (name,other_uuid) in dd
                            # check conflicts??
                            all_deps_u_vr[name] = other_uuid
                            other_uuid in uuids || push!(uuids, other_uuid)
                        end
                    end
                    for (vr, cd) in compat_data
                        all_compat_u_vr = get_or_make!(all_compat_u, vr)
                        for (name,vs) in cd
                            # check conflicts??
                            all_compat_u_vr[name] = vs
                        end
                    end
                end
            end
        end
        find_registered!(ctx, uuids)
    end

    for uuid in uuids
        if !haskey(uuid_to_name, uuid)
            name = registered_name(ctx, uuid)
            name === nothing && pkgerror("cannot find name corresponding to UUID $(uuid) in a registry")
            uuid_to_name[uuid] = name
            entry = manifest_info(ctx, uuid)
            entry ≡ nothing && continue
            uuid_to_name[uuid] = entry.name
        end
    end

    return Resolve.Graph(all_versions, all_deps, all_compat, uuid_to_name, reqs, fixed, #=verbose=# ctx.graph_verbose)
end

function load_urls(ctx::Context, pkgs::Vector{PackageSpec})
    urls = Dict{UUID,Vector{String}}()
    for pkg in pkgs
        uuid = pkg.uuid
        ver = pkg.version::VersionNumber
        urls[uuid] = String[]
        for path in registered_paths(ctx, uuid)
            info = parse_toml(path, "Package.toml")
            repo = info["repo"]
            repo in urls[uuid] || push!(urls[uuid], repo)
        end
    end
    foreach(sort!, values(urls))
    return urls
end

########################
# Package installation #
########################

function get_archive_url_for_version(url::String, ref)
    if (m = match(r"https://github.com/(.*?)/(.*?).git", url)) !== nothing
        return "https://api.github.com/repos/$(m.captures[1])/$(m.captures[2])/tarball/$(ref)"
    end
    return nothing
end

# Returns if archive successfully installed
function install_archive(
    urls::Vector{Pair{String,Bool}},
    hash::SHA1,
    version_path::String
)::Bool
    tmp_objects = String[]
    url_success = false
    for (url, top) in urls
        path = tempname() * randstring(6) * ".tar.gz"
        push!(tmp_objects, path) # for cleanup
        url_success = true
        try
            PlatformEngines.download(url, path; verbose=false)
        catch e
            e isa InterruptException && rethrow()
            url_success = false
        end
        url_success || continue
        dir = joinpath(tempdir(), randstring(12))
        push!(tmp_objects, dir) # for cleanup
        # Might fail to extract an archive (Pkg#190)
        try
            unpack(path, dir; verbose=false)
        catch e
            e isa InterruptException && rethrow()
            @warn "failed to extract archive downloaded from $(url)"
            url_success = false
        end
        url_success || continue
        if top
            unpacked = dir
        else
            dirs = readdir(dir)
            # 7z on Win might create this spurious file
            filter!(x -> x != "pax_global_header", dirs)
            @assert length(dirs) == 1
            unpacked = joinpath(dir, dirs[1])
        end
        # Assert that the tarball unpacked to the tree sha we wanted
        # TODO: Enable on Windows when tree_hash handles
        # executable bits correctly, see JuliaLang/julia #33212.
        if !Sys.iswindows()
            if SHA1(GitTools.tree_hash(unpacked)) != hash
                @warn "tarball content does not match git-tree-sha1"
                url_success = false
            end
            url_success || continue
        end
        # Move content to version path
        !isdir(version_path) && mkpath(version_path)
        mv(unpacked, version_path; force=true)
        break # successful install
    end
    # Clean up and exit
    foreach(x -> Base.rm(x; force=true, recursive=true), tmp_objects)
    return url_success
end

const refspecs = ["+refs/*:refs/remotes/cache/*"]
function install_git(
    ctx::Context,
    uuid::UUID,
    name::String,
    hash::SHA1,
    urls::Vector{String},
    version::Union{VersionNumber,Nothing},
    version_path::String
)::Nothing
    repo = nothing
    tree = nothing
    # TODO: Consolodate this with some of the repo handling in Types.jl
    try
        clones_dir = joinpath(depots1(), "clones")
        ispath(clones_dir) || mkpath(clones_dir)
        repo_path = joinpath(clones_dir, string(uuid))
        repo = GitTools.ensure_clone(ctx, repo_path, urls[1]; isbare=true,
                                     header = "[$uuid] $name from $(urls[1])")
        git_hash = LibGit2.GitHash(hash.bytes)
        for url in urls
            try LibGit2.with(LibGit2.GitObject, repo, git_hash) do g
                end
                break # object was found, we can stop
            catch err
                err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            end
            GitTools.fetch(ctx, repo, url, refspecs=refspecs)
        end
        tree = try
            LibGit2.GitObject(repo, git_hash)
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            error("$name: git object $(string(hash)) could not be found")
        end
        tree isa LibGit2.GitTree ||
            error("$name: git object $(string(hash)) should be a tree, not $(typeof(tree))")
        mkpath(version_path)
        GitTools.checkout_tree_to_path(repo, tree, version_path)
        return
    finally
        repo !== nothing && LibGit2.close(repo)
        tree !== nothing && LibGit2.close(tree)
    end
end

function download_artifacts(ctx::Context, pkgs::Vector{PackageSpec}; platform::Platform=platform_key_abi(),
                            verbose::Bool=false)
    # Filter out packages that have no source_path()
    pkg_roots = String[p for p in source_path.((ctx,), pkgs) if p !== nothing]
    return download_artifacts(ctx, pkg_roots; platform=platform, verbose=verbose)
end

function download_artifacts(ctx::Context, pkg_roots::Vector{String}; platform::Platform=platform_key_abi(),
                            verbose::Bool=false)
    # List of Artifacts.toml files that we're going to download from
    artifacts_tomls = String[]

    for path in pkg_roots
        # Check to see if this package has an (Julia)Artifacts.toml
        for f in artifact_names
            artifacts_toml = joinpath(path, f)
            if isfile(artifacts_toml)
                push!(artifacts_tomls, artifacts_toml)
                break
            end
        end
    end

    if !isempty(artifacts_tomls)
        for artifacts_toml in artifacts_tomls
            ensure_all_artifacts_installed(artifacts_toml; platform=platform, verbose=verbose, quiet_download=!(stderr isa Base.TTY))
            write_env_usage(artifacts_toml, "artifact_usage.toml")
        end
    end
end

function check_artifacts_downloaded(pkg_root::String; platform::Platform=platform_key_abi())
    for f in artifact_names
        artifacts_toml = joinpath(pkg_root, f)
        if isfile(artifacts_toml)
            hashes = extract_all_hashes(artifacts_toml)
            if !all(artifact_exists.(hashes))
                return false
            end
            break
        end
    end
    return true
end

# install & update manifest
function download_source(ctx::Context, pkgs::Vector{PackageSpec}; readonly=true)
    pkgs = filter(tracking_registered_version, pkgs)
    urls = load_urls(ctx, pkgs)
    return download_source(ctx, pkgs, urls; readonly=readonly)
end

function download_source(ctx::Context, pkgs::Vector{PackageSpec},
                        urls::Dict{UUID, Vector{String}}; readonly=true)
    probe_platform_engines!()
    new_pkgs = PackageSpec[]

    pkgs_to_install = Tuple{PackageSpec, String}[]
    for pkg in pkgs
        path = source_path(ctx, pkg)
        ispath(path) && continue
        push!(pkgs_to_install, (pkg, path))
        push!(new_pkgs, pkg)
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
                if ctx.use_libgit2_for_all_downloads
                    put!(results, (pkg, false, path))
                    continue
                end
                try
                    archive_urls = Pair{String,Bool}[]
                    if (server = pkg_server()) !== nothing
                        url = "$server/package/$(pkg.uuid)/$(pkg.tree_hash)"
                        push!(archive_urls, url => true)
                    end
                    for repo_url in urls[pkg.uuid]
                        url = get_archive_url_for_version(repo_url, pkg.tree_hash)
                        url !== nothing && push!(archive_urls, url => false)
                    end
                    success = install_archive(archive_urls, pkg.tree_hash, path)
                    if success && readonly
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
            vstr = pkg.version !== nothing ? "v$(pkg.version)" : "[$h]"
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
        install_git(ctx, pkg.uuid, pkg.name, pkg.tree_hash, urls[uuid], pkg.version::VersionNumber, path)
        readonly && set_readonly(path)
        vstr = pkg.version !== nothing ? "v$(pkg.version)" : "[$h]"
        printpkgstyle(ctx, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
    end

    return new_pkgs
end

function download(ctx::Context, pkgs::Vector{PackageSpec}, new::Vector{UUID}=UUID[];
                  platform::Platform=platform_key_abi())
    union!(new, uuids(download_source(ctx, pkgs)))
    # After downloading resolutionary packages, search for (Julia)Artifacts.toml files
    # and ensure they are all downloaded and unpacked as well:
    download_artifacts(ctx, pkgs; platform=platform)
    return new
end

################################
# Manifest update and pruning #
################################
project_rel_path(ctx::Context, path::String) = project_rel_path(projectdir(ctx), path)
project_rel_path(project::String, path::String) = normpath(joinpath(project, path))

function prune_manifest(ctx::Context)
    keep = collect(values(ctx.env.project.deps))
    ctx.env.manifest = prune_manifest(ctx.env.manifest, keep)
end

function prune_manifest(manifest::Dict, keep::Vector{UUID})
    while !isempty(keep)
        clean = true
        for (uuid, entry) in manifest
            uuid in keep || continue
            for dep in values(entry.deps)
                dep in keep && continue
                push!(keep, dep)
                clean = false
            end
        end
        clean && break
    end
    return Dict(uuid => entry for (uuid, entry) in manifest if uuid in keep)
end

function any_package_not_installed(ctx)
    for (uuid, entry) in ctx.env.manifest
        if Base.locate_package(Base.PkgId(uuid, entry.name)) === nothing
            return true
        end
    end
    return false
end

#########
# Build #
#########
function _get_deps!(ctx::Context, pkgs::Vector{PackageSpec}, uuids::Vector{UUID})
    for pkg in pkgs
        is_stdlib(pkg.uuid) && continue
        pkg.uuid in uuids && continue
        push!(uuids, pkg.uuid)
        if Types.is_project(ctx, pkg)
            pkgs = [PackageSpec(name, uuid) for (name, uuid) in ctx.env.project.deps]
        else
            info = manifest_info(ctx, pkg.uuid)
            if info === nothing
                pkgerror("could not find manifest entry for package $(err_rep(pkg))")
            end
            pkgs = [PackageSpec(name, uuid) for (name, uuid) in info.deps]
        end
        _get_deps!(ctx, pkgs, uuids)
    end
    return
end

function build(ctx::Context, pkgs::Vector{PackageSpec}, verbose::Bool)
    if any_package_not_installed(ctx) || !isfile(ctx.env.manifest_file)
        Pkg.instantiate(ctx)
    end
    uuids = UUID[]
    _get_deps!(ctx, pkgs, uuids)
    build_versions(ctx, uuids; might_need_to_resolve=true, verbose=verbose)
end

function dependency_order_uuids(ctx::Context, uuids::Vector{UUID})::Dict{UUID,Int}
    order = Dict{UUID,Int}()
    seen = UUID[]
    k = 0
    function visit(uuid::UUID)
        is_stdlib(uuid) && return
        uuid in seen &&
            return @warn("Dependency graph not a DAG, linearizing anyway")
        haskey(order, uuid) && return
        push!(seen, uuid)
        if Types.is_project_uuid(ctx, uuid)
            deps = values(ctx.env.project.deps)
        else
            entry = manifest_info(ctx, uuid)
            deps = values(entry.deps)
        end
        foreach(visit, deps)
        pop!(seen)
        order[uuid] = k += 1
    end
    visit(uuid::String) = visit(UUID(uuid))
    foreach(visit, uuids)
    return order
end

function gen_build_code(build_file::String)
    code = """
        $(Base.load_path_setup_code(false))
        cd($(repr(dirname(build_file))))
        include($(repr(build_file)))
        """
    return ```
        $(Base.julia_cmd()) -O0 --color=no --history-file=no
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --compiled-modules=$(Bool(Base.JLOptions().use_compiled_modules) ? "yes" : "no")
        --eval $code
        ```
end

builddir(source_path::String) = joinpath(source_path, "deps")
buildfile(source_path::String) = joinpath(builddir(source_path), "build.jl")
function build_versions(ctx::Context, uuids::Vector{UUID}; might_need_to_resolve=false, verbose=false)
    # collect builds for UUIDs with `deps/build.jl` files
    builds = Tuple{UUID,String,String,VersionNumber}[]
    for uuid in uuids
        is_stdlib(uuid) && continue
        if Types.is_project_uuid(ctx, uuid)
            path = projectdir(ctx)
            name = ctx.env.pkg.name
            version = ctx.env.pkg.version
        else
            entry = manifest_info(ctx, uuid)
            name = entry.name
            if entry.tree_hash !== nothing
                path = find_installed(name, uuid, entry.tree_hash)
            elseif entry.path !== nothing
                path = project_rel_path(ctx, entry.path)
            else
                pkgerror("Could not find either `git-tree-sha1` or `path` for package $name")
            end
            version = something(entry.version, v"0.0")
        end
        ispath(path) || error("Build path for $name does not exist: $path")
        ispath(buildfile(path)) && push!(builds, (uuid, name, path, version))
    end
    # toposort builds by dependencies
    order = dependency_order_uuids(ctx, map(first, builds))
    sort!(builds, by = build -> order[first(build)])
    max_name = isempty(builds) ? 0 : maximum(textwidth.([build[2] for build in builds]))
    # build each package versions in a child process
    for (uuid, name, source_path, version) in builds
        pkg = PackageSpec(;uuid=uuid, name=name, version=version)
        build_file = buildfile(source_path)
        # compatibility shim
        build_project_override = isfile(projectfile_path(builddir(source_path))) ?
            nothing :
            gen_target_project(ctx, pkg, source_path, "build")

        log_file = splitext(build_file)[1] * ".log"
        printpkgstyle(ctx, :Building,
                      rpad(name * " ", max_name + 1, "─") * "→ " * Types.pathrepr(log_file))

        sandbox(ctx, pkg, source_path, builddir(source_path), build_project_override) do
            flush(stdout)
            ok = open(log_file, "w") do log
                std = verbose ? ctx.io : log
                success(pipeline(gen_build_code(buildfile(source_path)),
                                 stdout=std, stderr=std))
            end
            ok && return
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
    return
end

##############
# Operations #
##############
function rm(ctx::Context, pkgs::Vector{PackageSpec})
    drop = UUID[]
    # find manifest-mode drops
    for pkg in pkgs
        pkg.mode == PKGMODE_MANIFEST || continue
        info = manifest_info(ctx, pkg.uuid)
        if info !== nothing
            pkg.uuid in drop || push!(drop, pkg.uuid)
        else
            str = has_name(pkg) ? pkg.name : string(pkg.uuid)
            @warn("`$str` not in manifest, ignoring")
        end
    end
    # drop reverse dependencies
    while !isempty(drop)
        clean = true
        for (uuid, entry) in ctx.env.manifest
            deps = values(entry.deps)
            isempty(drop ∩ deps) && continue
            uuid ∉ drop || continue
            push!(drop, uuid)
            clean = false
        end
        clean && break
    end
    # find project-mode drops
    for pkg in pkgs
        pkg.mode == PKGMODE_PROJECT || continue
        found = false
        for (name::String, uuid::UUID) in ctx.env.project.deps
            pkg.name == name || pkg.uuid == uuid || continue
            pkg.name == name ||
                error("project file name mismatch for `$uuid`: $(pkg.name) ≠ $name")
            pkg.uuid == uuid ||
                error("project file UUID mismatch for `$name`: $(pkg.uuid) ≠ $uuid")
            uuid in drop || push!(drop, uuid)
            found = true
            break
        end
        found && continue
        str = has_name(pkg) ? pkg.name : string(pkg.uuid)
        @warn("`$str` not in project, ignoring")
    end
    # delete drops from project
    n = length(ctx.env.project.deps)
    filter!(ctx.env.project.deps) do (_, uuid)
        uuid ∉ drop
    end
    if length(ctx.env.project.deps) == n
        println(ctx.io, "No changes")
        return
    end
    # remove drops from `source`
    filter!(ctx.env.project.source) do (name, _)
        name in keys(ctx.env.project.deps)
    end
    # only declare `compat` for direct dependencies
    # `julia` is always an implicit direct dependency
    filter!(ctx.env.project.compat) do (name, _)
        name == "julia" || name in keys(ctx.env.project.deps)
    end
    deps_names = append!(collect(keys(ctx.env.project.deps)),
                         collect(keys(ctx.env.project.extras)))
    filter!(ctx.env.project.targets) do (target, deps)
        !isempty(filter!(in(deps_names), deps))
    end

    # only keep reachable manifest entires
    prune_manifest(ctx)
    # update project & manifest
    show_update(ctx)
    write_env(ctx.env)
end

is_registered(ctx::Context, uuid::UUID) = !isempty(registered_paths(ctx, uuid))
function check_registered(ctx::Context, pkgs::Vector{PackageSpec})
    pkgs = filter(tracking_registered_version, pkgs)
    find_registered!(ctx, UUID[pkg.uuid for pkg in pkgs])
    for pkg in pkgs
        is_registered(ctx, pkg.uuid) && continue
        pkgerror("expected package $(err_rep(pkg)) to be registered")
    end
end

# Check if the package can be added without colliding/overwriting things
function assert_can_add(ctx::Context, pkgs::Vector{PackageSpec})
    for pkg in pkgs
        @assert pkg.name !== nothing && pkg.uuid !== nothing
        # package with the same name exist in the project: assert that they have the same uuid
        get(ctx.env.project.deps, pkg.name, pkg.uuid) == pkg.uuid ||
            pkgerror("refusing to add package $(err_rep(pkg)):",
                     " package `$(pkg.name) = \"$(get(ctx.env.project.deps, pkg.name, pkg.uuid))\"` ",
                     "already exists as a direct dependency")
        # package with the same uuid exist in the project: assert they have the same name
        name = findfirst(==(pkg.uuid), ctx.env.project.deps)
        (name === nothing || name == pkg.name) ||
            pkgerror("refusing to add package $(err_rep(pkg)):",
                     " package `$(pkg.name) = \"$(ctx.env.project.deps[name])\"` ",
                     "already exists as a direct dependency")
        # package with the same uuid exist in the manifest: assert they have the same name
        haskey(ctx.env.manifest, pkg.uuid) && (ctx.env.manifest[pkg.uuid].name != pkg.name) &&
            pkgerror("refusing to add package $(err_rep(pkg)):",
                     " package `$(ctx.env.manifest[pkg.uuid].name) = \"$(pkg.uuid)\"` ",
                     "already exists in the manifest")
    end
end

function tiered_resolve(ctx::Context, pkgs::Vector{PackageSpec}, new::Vector{UUID}, should_preserve_all::Bool)
    if should_preserve_all
        try # do not modify existing subgraph
            return targeted_resolve(ctx, pkgs, PRESERVE_ALL, new)
        catch err
            err isa Resolve.ResolverError || rethrow()
        end
    end
    try # do not modify existing direct deps
        return targeted_resolve(ctx, pkgs, PRESERVE_DIRECT, new)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try
        return targeted_resolve(ctx, pkgs, PRESERVE_SEMVER, new)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    return targeted_resolve(ctx, pkgs, PRESERVE_NONE, new)
end

function targeted_resolve(ctx::Context, pkgs::Vector{PackageSpec}, preserve::PreserveLevel, new::Vector{UUID})
    if preserve == PRESERVE_ALL
        pkgs = load_all_deps(ctx, pkgs, new)
    elseif preserve == PRESERVE_DIRECT
        pkgs = load_direct_deps(ctx, pkgs, new)
    elseif preserve == PRESERVE_SEMVER
        pkgs = load_direct_deps(ctx, pkgs, new; preserve=preserve)
    elseif preserve == PRESERVE_NONE
        pkgs = load_direct_deps(ctx, pkgs, new; preserve=preserve)
    end
    resolve_versions!(ctx, pkgs)
    return pkgs
end

function resolve(ctx::Context, pkgs::Vector{PackageSpec}, new::Vector{UUID}, preserve::PreserveLevel, should_preserve_all::Bool)
    printpkgstyle(ctx, :Resolving, "package versions...")
    return preserve == PRESERVE_TIERED ?
        tiered_resolve(ctx, pkgs, new, should_preserve_all) :
        targeted_resolve(ctx, pkgs, preserve, new)
end

function is_valid_repo(path)
    valid = nothing
    if isdir(joinpath(path, ".git"))
        LibGit2.with(LibGit2.GitRepo(path)) do repo
            valid = GitTools.has_valid_HEAD(repo)
        end
        return valid
    end
    return false
end

function renormalize_source(project_path::String, source::String)
    if !isurl(source)
        use_abspath = isabspath(source)
        source = project_rel_path(project_path, source)
        source = use_abspath ? source : relpath(source, pwd())
    end
    return source
end

function handle_unregistered_pkg(ctx::Context, project_path::String, source::String, new::Vector{UUID};
                                 force_add::Bool=false)
    source = renormalize_source(project_path, source)
    new_pkg = PackageSpec(; repo=GitRepo(;source=source))
    if force_add || isurl(source) || is_valid_repo(source)
        Types.handle_repo_add!(ctx, new_pkg) && push!(new, new_pkg.uuid)
    else
        Types.handle_repo_develop!(ctx, new_pkg, false) && push!(new, new_pkg.uuid)
    end
    return new_pkg
end

function collect_unregistered_fixed!(ctx::Context, pkg::PackageSpec, pkgs::Vector{PackageSpec})
    entry = manifest_info(ctx, pkg.uuid)
    all_deps = load_all_deps
    for (name, uuid) in entry.deps
        entry = manifest_info(ctx, uuid)
        entry === nothing && continue
        new_pkg = PackageSpec(uuid, entry)
        is_tracking_registry(new_pkg) && continue
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        push!(pkgs, new_pkg)
        collect_unregistered_fixed!(ctx, new_pkg, pkgs)
    end
    return pkgs
end

function collect_unregistered!(ctx::Context, pkg::PackageSpec, pkgs::Vector{PackageSpec}, new::Vector{UUID})
    project_path = project_rel_path(ctx, source_path(ctx, pkg))
    projectfile = projectfile_path(project_path; strict=true)
    if projectfile === nothing
        pkgerror("could not find project file for package $(err_rep(pkg)) at `$(project_path)`")
    end
    src_project = Types.read_project(projectfile)
    for (name, uuid) in src_project.deps
        source = get(src_project.source, name, nothing)
        if source !== nothing
            new_pkg = handle_unregistered_pkg(ctx, project_path, source, new)
            findfirst(pkg -> pkg.uuid == new_pkg.uuid, pkgs) === nothing || continue
            push!(pkgs, new_pkg)
            collect_unregistered!(ctx, new_pkg, pkgs, new)
        end
    end
end

function collect_unregistered!(ctx::Context, pkgs::Vector{PackageSpec}, new::Vector{UUID})
    for pkg in filter(!is_tracking_registry, pkgs)
        collect_unregistered!(ctx, pkg, pkgs, new)
    end
    return pkgs
end

add_package(ctx::Context, pkg::PackageSpec, ::Nothing) = pkg
function add_package(ctx::Context, pkg::PackageSpec, entry::PackageEntry)
    if entry.pinned
        if pkg.version == VersionSpec()
            println(ctx.io, "`$(pkg.name)` is pinned at `v$(entry.version)`: maintaining pinned version")
        end
        return PackageSpec(; uuid=pkg.uuid, name=pkg.name, pinned=true,
                           version=entry.version, tree_hash=entry.tree_hash)
    end
    if !is_tracking_registry(entry) || !is_tracking_registry(pkg)
        return pkg # overwrite everything, nothing to copy over
    end
    if is_stdlib(pkg.uuid)
        return pkg # stdlibs are not versioned like other packages
    elseif any(==(pkg.uuid), [uuid for (name, uuid) in ctx.env.project.deps]) &&
        ((isa(pkg.version, VersionNumber) && entry.version == pkg.version) ||
         (!isa(pkg.version, VersionNumber) && entry.version ∈ pkg.version))
        # leave the package as is at the installed version
        return PackageSpec(; uuid=pkg.uuid, name=pkg.name, version=entry.version,
                           tree_hash=entry.tree_hash)
    end
    # adding a new version not compatible with the old version, so we just overwrite
    return pkg
end

function add(ctx::Context, pkgs::Vector{PackageSpec}, new=UUID[];
             preserve::PreserveLevel=PRESERVE_TIERED, platform::Platform=platform_key_abi())
    should_preserve_all = isempty(intersect(values(ctx.env.project.deps), uuids(pkgs)))
    foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, pkgs) # update set of deps
    pkgs = map(pkg -> add_package(ctx, pkg, manifest_info(ctx, pkg.uuid)), pkgs)
    collect_unregistered!(ctx, pkgs, new)
    pkgs = resolve(ctx, pkgs, new, preserve, should_preserve_all)
    update_env!(ctx, pkgs)
    new = download(ctx, pkgs; platform=platform)
    show_update(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, new)
end

# Input: name, uuid, and path
function develop(ctx::Context, pkgs::Vector{PackageSpec}, new::Vector{UUID};
                 preserve::PreserveLevel=PRESERVE_TIERED, platform::Platform=platform_key_abi())
    should_preserve_all = isempty(intersect(values(ctx.env.project.deps), uuids(pkgs)))
    foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, pkgs)
    collect_unregistered!(ctx, pkgs, new)
    pkgs = resolve(ctx, pkgs, new, preserve, should_preserve_all)
    update_env!(ctx, pkgs)
    new = download(ctx, pkgs; platform=platform)
    show_update(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, new)
end

function update_package!(ctx::Context, pkg::PackageSpec, level::UpgradeLevel, new::Vector{UUID})
    if pkg.pinned || level == UPLEVEL_FIXED
        return pkg
    end
    if !is_tracking_registry(pkg)
        if level == UPLEVEL_MAJOR
            source = renormalize_source(projectdir(ctx), something(pkg.path, pkg.repo.source))
            new_pkg = PackageSpec(; repo=GitRepo(;source=source))
            if is_tracking_path(pkg)
                Types.handle_repo_develop!(ctx, new_pkg, false) && push!(new, new_pkg.uuid)
            else
                Types.handle_repo_add!(ctx, new_pkg) && push!(new, new_pkg.uuid)
            end
            return new_pkg
        end
        return pkg
    end
    # TODO pkg.version should only by a number or an empty VersionSpec by this point
    if pkg.version isa VersionNumber
        r = level == UPLEVEL_PATCH ? VersionRange(pkg.version.major, pkg.version.minor) :
            level == UPLEVEL_MINOR ? VersionRange(pkg.version.major) :
            VersionRange() 
        pkg.version = VersionSpec(r)
    end
    return pkg
end

function update(ctx::Context, pkgs::Vector{PackageSpec}, new::Vector{UUID}, level::UpgradeLevel)
    pkgs = map(pkg -> update_package!(ctx, pkg, level, new), pkgs)
    pkgs = load_direct_deps(ctx, pkgs, new; preserve = (level == UPLEVEL_FIXED ? PRESERVE_NONE : PRESERVE_DIRECT))
    resolve_versions!(ctx, pkgs)
    prune_manifest(ctx)
    update_env!(ctx, pkgs)
    new = download(ctx, pkgs, new)
    show_update(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, new)
end

function pin_package!(ctx::Context, pkg::PackageSpec, entry::PackageEntry)
    if entry.pinned && pkg.version == VersionSpec()
        println(ctx.io, "package $(err_rep(pkg)) already pinned")
    end
    # update pinned package
    pkg.pinned = true
    if is_stdlib(pkg.uuid)
        return nothing # nothing left to do
    elseif pkg.version == VersionSpec()
        pkg.version = entry.version # pin at current version
        pkg.repo = entry.repo
        pkg.tree_hash = entry.tree_hash
        pkg.path = entry.path
    else # given explicit registered version
        if !is_tracking_registry(entry)
            # A pin in this case includes an implicit `free` to switch to tracking registered versions
            # First, make sure the package is registered so we have something to free to
            if isempty(registered_paths(ctx, pkg.uuid))
                pkgerror("unable to pin unregistered package $(err_rep(pkg)) to an arbritrary version")
            end
        end
    end
end

function pin(ctx::Context, pkgs::Vector{PackageSpec})
    foreach(pkg -> pin_package!(ctx, pkg, manifest_info(ctx, pkg.uuid)), pkgs)
    pkgs = load_direct_deps(ctx, pkgs)
    resolve_versions!(ctx, pkgs)
    update_env!(ctx, pkgs)
    new = download(ctx, pkgs)
    show_update(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, new)
end

function free_package!(ctx::Context, pkg::PackageSpec, entry::PackageEntry)
    if entry.pinned
        pkg.pinned = false
        is_stdlib(pkg.uuid) && return # nothing left to do
        pkg.version = entry.version
        pkg.repo = entry.repo
        pkg.tree_hash = entry.tree_hash
        return
    end
    if !is_tracking_registry(entry)
        # make sure the package is registered so we have something to free to
        if isempty(registered_paths(ctx, pkg.uuid))
            pkgerror("unable to free unregistered package $(err_rep(pkg))")
        end
        return # -> name, uuid
    end
    pkgerror("expected package $(err_rep(pkg)) to be pinned, tracking a path,",
             " or tracking a repository")
end

# TODO: this is two techinically different operations with the same name
# split into two subfunctions ...
function free(ctx::Context, pkgs::Vector{PackageSpec})
    foreach(pkg -> free_package!(ctx, pkg, manifest_info(ctx, pkg.uuid)), pkgs)

    if any(pkg -> pkg.version == VersionSpec(), pkgs)
        pkgs = load_direct_deps(ctx, pkgs)
        resolve_versions!(ctx, pkgs)
        update_env!(ctx, pkgs)
        new = download(ctx, pkgs)
        show_update(ctx)
        write_env(ctx.env) # write env before building
        build_versions(ctx, new)
    else
        foreach(pkg -> manifest_info(ctx, pkg.uuid).pinned = false, pkgs)
        show_update(ctx)
        write_env(ctx.env)
    end
end

function gen_test_code(testfile::String;
        coverage=false,
        julia_args::Cmd=``,
        test_args::Cmd=``)
    code = """
        $(Base.load_path_setup_code(false))
        cd($(repr(dirname(testfile))))
        append!(empty!(ARGS), $(repr(test_args.exec)))
        include($(repr(testfile)))
        """
    return ```
        $(Base.julia_cmd())
        --code-coverage=$(coverage ? "user" : "none")
        --color=$(Base.have_color ? "yes" : "no")
        --compiled-modules=$(Bool(Base.JLOptions().use_compiled_modules) ? "yes" : "no")
        --check-bounds=yes
        --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --track-allocation=$(("none", "user", "all")[Base.JLOptions().malloc_log + 1])
        $(julia_args)
        --eval $(code)
    ```
end

function with_temp_env(fn::Function, temp_env::String)
    load_path = copy(LOAD_PATH)
    active_project = Base.ACTIVE_PROJECT[]
    try
        push!(empty!(LOAD_PATH), temp_env)
        Base.ACTIVE_PROJECT[] = temp_env
        fn()
    finally
        append!(empty!(LOAD_PATH), load_path)
        Base.ACTIVE_PROJECT[] = active_project
    end
end

# pick out a set of subgraphs and preserve their versions
function sandbox_preserve(ctx::Context, target::PackageSpec, test_project::String)
    env = deepcopy(ctx.env)
    # include root in manifest (in case any dependencies point back to it)
    if env.pkg !== nothing
        env.manifest[env.pkg.uuid] = PackageEntry(;name=env.pkg.name, path=dirname(env.project_file),
                                                  deps=env.project.deps)
    end
    # preserve important nodes
    keep = [target.uuid]
    append!(keep, collect(values(read_project(test_project).deps)))
    # prune and return
    return prune_manifest(env.manifest, keep)
end

abspath!(ctx::Context, manifest::Dict{UUID,PackageEntry}) =
    abspath!(projectdir(ctx), manifest)
function abspath!(project::String, manifest::Dict{UUID,PackageEntry})
    for (uuid, entry) in manifest
        entry.path !== nothing || continue
        entry.path = project_rel_path(project, entry.path)
    end
    return manifest
end

# ctx + pkg used to compute parent dep graph
function sandbox(fn::Function, ctx::Context, target::PackageSpec, target_path::String,
                 sandbox_path::String, sandbox_project_override)
    active_manifest = manifestfile_path(projectdir(ctx))
    sandbox_project = projectfile_path(sandbox_path)

    mktempdir() do tmp
        tmp_project  = projectfile_path(tmp)
        tmp_manifest = manifestfile_path(tmp)

        # Copy env info over to temp env
        if sandbox_project_override !== nothing
            Types.write_project(sandbox_project_override, tmp_project)
        elseif isfile(sandbox_project)
            cp(sandbox_project, tmp_project)
            chmod(tmp_project, 0o600)
        end
        # create merged manifest
        # - copy over active subgraph
        # - abspath! to maintain location of all deved nodes
        working_manifest = abspath!(ctx, sandbox_preserve(ctx, target, tmp_project))
        # - copy over fixed subgraphs from test subgraph
        # really only need to copy over "special" nodes
        sandbox_env = Types.EnvCache(projectfile_path(sandbox_path))
        sandbox_manifest = abspath!(sandbox_path, sandbox_env.manifest)
        for (name, uuid) in sandbox_env.project.deps
            entry = get(sandbox_manifest, uuid, nothing)
            if entry !== nothing && !is_tracking_registry(entry)
                subgraph = prune_manifest(sandbox_manifest, [uuid])
                for (uuid, entry) in subgraph
                    if haskey(working_manifest, uuid)
                        pkgerror("can not merge projects")
                    end
                    working_manifest[uuid] = entry
                end
            end
        end
        Types.write_manifest(working_manifest, tmp_manifest)
        # sandbox
        with_temp_env(tmp) do
            temp_ctx = Context()
            temp_ctx.env.project.deps[target.name] = target.uuid
            temp_ctx.env.project.source[target.name] = target_path
            for (uuid, entry) in temp_ctx.env.manifest
                is_tracking_registry(entry) && continue
                temp_ctx.env.project.source[entry.name] = something(entry.path, entry.repo.source)
            end
            write_env(temp_ctx.env, update_undo = false)
            try
                Pkg.status()
                Pkg.resolve(; io=devnull)
                @debug "Using _parent_ dep graph"
            catch err# TODO
                @error err
                temp_ctx.env.manifest = Dict(uuid => entry for (uuid, entry) in temp_ctx.env.manifest if isfixed(entry))
                Pkg.resolve(temp_ctx; io=devnull)
                @debug "Using _clean_ dep graph"
            end
            # Run sandboxed code
            path_sep = Sys.iswindows() ? ';' : ':'
            withenv(fn, "JULIA_LOAD_PATH" => "@$(path_sep)$(tmp)")
        end
    end
end

function test_package!(pkg::PackageSpec, entry::PackageEntry)
    is_stdlib(pkg.uuid) && return
    pkg.version = entry.version
    pkg.tree_hash = entry.tree_hash
    pkg.repo = entry.repo
    pkg.path = entry.path
    pkg.pinned = entry.pinned
end

# Mostly here to give PkgEval some more coverage for packages
# that still use test/REQUIRE. Ignores version bounds
function parse_REQUIRE(require_path::String)
    packages = String[]
    for entry in eachline(require_path)
        if startswith(entry, '#') || isempty(entry)
            continue
        end
        # For lines like @osx Foo, ignore @osx
        words = split(entry)
        if startswith(words[1], '@')
            popfirst!(words)
        end
        push!(packages, popfirst!(words))
    end
    return packages
end

# "targets" based test deps -> "test/Project.toml" based deps
function gen_target_project(ctx::Context, pkg::PackageSpec, source_path::String, target::String)
    test_project = Types.Project()
    if projectfile_path(source_path; strict=true) === nothing
        # no project file, assuming this is an old REQUIRE package
        test_project.deps = copy(ctx.env.manifest[pkg.uuid].deps)
        if target == "test"
            test_REQUIRE_path = joinpath(source_path, "test", "REQUIRE")
            if isfile(test_REQUIRE_path)
                @warn "using test/REQUIRE files is deprecated and current support is lacking in some areas"
                test_pkgs = parse_REQUIRE(test_REQUIRE_path)
                package_specs = [PackageSpec(name=pkg) for pkg in test_pkgs]
                registry_resolve!(ctx, package_specs)
                stdlib_resolve!(package_specs)
                ensure_resolved(ctx, package_specs, registry=true)
                for spec in package_specs
                    test_project.deps[spec.name] = spec.uuid
                end
            end
        end
        return test_project
    end
    # collect relevant info from source
    source_ctx = Context(env = EnvCache(projectfile_path(source_path)))
    source_env = source_ctx.env
    # collect regular dependencies
    test_project.deps = source_env.project.deps
    # collect test dependencies
    for name in get(source_env.project.targets, target, String[])
        uuid = get(source_env.project.extras, name, nothing)
        if uuid === nothing
            pkgerror("`$name` declared as a `$target` dependency, but no such entry in `extras`")
        end
        test_project.deps[name] = uuid
    end
    # collect compat entries
    for (name, uuid) in test_project.deps
        compat = get(source_env.project.compat, name, nothing)
        compat === nothing && continue
        test_project.compat[name] = compat
    end
    return test_project
end

testdir(source_path::String) = joinpath(source_path, "test")
testfile(source_path::String) = joinpath(testdir(source_path), "runtests.jl")
function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, julia_args::Cmd=``, test_args::Cmd=``,
              test_fn=nothing)
    Pkg.instantiate(ctx)

    # load manifest data
    for pkg in pkgs
        if Types.is_project_uuid(ctx, pkg.uuid)
            pkg.path = projectdir(ctx)
            pkg.version = ctx.env.pkg.version
        else
            test_package!(pkg, manifest_info(ctx, pkg.uuid))
        end
    end

    # See if we can find the test files for all packages
    missing_runtests = String[]
    source_paths     = String[]
    for pkg in pkgs
        sourcepath = project_rel_path(ctx, source_path(ctx, pkg)) # TODO
        !isfile(testfile(sourcepath)) && push!(missing_runtests, pkg.name)
        push!(source_paths, sourcepath)
    end
    if !isempty(missing_runtests)
        pkgerror(length(missing_runtests) == 1 ? "Package " : "Packages ",
                join(missing_runtests, ", "),
                " did not provide a `test/runtests.jl` file")
    end

    # sandbox
    pkgs_errored = String[]
    for (pkg, source_path) in zip(pkgs, source_paths)
        # compatibility shim between "targets" and "test/Project.toml"
        test_project_override = isfile(projectfile_path(testdir(source_path))) ?
            nothing :
            gen_target_project(ctx, pkg, source_path, "test")
        # now we sandbox
        printpkgstyle(ctx, :Testing, pkg.name)
        sandbox(ctx, pkg, source_path, testdir(source_path), test_project_override) do
            test_fn !== nothing && test_fn()
            status(Context(); mode=PKGMODE_COMBINED)
            flush(stdout)
            try
                run(gen_test_code(testfile(source_path); coverage=coverage, julia_args=julia_args, test_args=test_args))
                printpkgstyle(ctx, :Testing, pkg.name * " tests passed ")
            catch err
                push!(pkgs_errored, pkg.name)
            end
        end
    end

    # report errors
    if !isempty(pkgs_errored)
        pkgerror(length(pkgs_errored) == 1 ? "Package " : "Packages ",
                 join(pkgs_errored, ", "),
                 " errored during testing")
    end
end

function package_info(ctx::Context, pkg::PackageSpec)::PackageInfo
    entry = manifest_info(ctx, pkg.uuid)
    if entry === nothing
        pkgerror("expected package $(err_rep(pkg)) to exist in the manifest",
                 " (use `resolve` to populate the manifest)")
    end
    package_info(ctx, pkg, entry)
end

function package_info(ctx::Context, pkg::PackageSpec, entry::PackageEntry)::PackageInfo
    git_source = !is_tracking_repo(pkg) ? nothing :
        isurl(pkg.repo.source) ? pkg.repo.source :
        project_rel_path(ctx, pkg.repo.source)
    info = PackageInfo(
        name                 = pkg.name,
        version              = pkg.version != VersionSpec() ? pkg.version : nothing,
        tree_hash            = pkg.tree_hash === nothing ? nothing : string(pkg.tree_hash),
        is_direct_dep        = pkg.uuid in values(ctx.env.project.deps),
        is_pinned            = pkg.pinned,
        is_tracking_path     = pkg.path !== nothing,
        is_tracking_repo     = pkg.repo.rev !== nothing || pkg.repo.source !== nothing,
        is_tracking_registry = is_tracking_registry(pkg),
        git_revision         = pkg.repo.rev,
        git_source           = git_source,
        source               = project_rel_path(ctx, source_path(ctx, pkg)),
        dependencies         = copy(entry.deps), #TODO is copy needed?
    )
    return info
end

# Display

function stat_rep(x::PackageSpec; name=true)
    name = name ? "$(x.name)" : ""
    version = x.version == VersionSpec() ? "" : "v$(x.version)"
    rev = ""
    if x.repo.rev !== nothing
        rev = occursin(r"\b([a-f0-9]{40})\b", x.repo.rev) ? x.repo.rev[1:7] : x.repo.rev
        rev = "#$rev"
    end
    repo = Operations.is_tracking_repo(x) ? "`$(x.repo.source)$(rev)`" : ""
    path = Operations.is_tracking_path(x) ? "$(pathrepr(x.path))" : ""
    pinned = x.pinned ? "⚲" : ""
    return join(filter(!isempty, [name,version,repo,path,pinned]), " ")
end

print_single(ctx::Context, pkg::PackageSpec) = printstyled(ctx.io, stat_rep(pkg); color=:white)

is_uninstantiated(::Nothing) = true
is_uninstantiated(x::PackageSpec) = x.version == VersionSpec() && !is_stdlib(x.uuid)
function print_diff(ctx::Context, old::Union{Nothing,PackageSpec}, new::Union{Nothing,PackageSpec})
    if is_uninstantiated(old) && !is_uninstantiated(new)
        printstyled(ctx.io, "+ $(stat_rep(new))"; color=:light_green)
    elseif is_uninstantiated(new)
        printstyled(ctx.io, "- $(stat_rep(old))"; color=:light_red)
    elseif is_tracking_registry(old) && is_tracking_registry(new)
        if new.version > old.version
            printstyled(ctx.io, "↑ $(stat_rep(old)) ⇒ $(stat_rep(new; name=false))"; color=:light_yellow)
        else
            printstyled(ctx.io, "↓ $(stat_rep(old)) ⇒ $(stat_rep(new; name=false))"; color=:light_magenta)
        end
    else
        printstyled(ctx.io, "~ $(stat_rep(old)) ⇒ $(stat_rep(new; name=false))"; color=:light_yellow)
    end
end

function diff_array(old_ctx::Union{Context,Nothing}, new_ctx::Context; manifest=true)
    function index_pkgs(pkgs, uuid)
        idx = findfirst(pkg -> pkg.uuid == uuid, pkgs)
        return idx === nothing ? nothing : pkgs[idx]
    end

    new = manifest ? load_manifest_deps(new_ctx) : load_direct_deps(new_ctx; unregistered=false)
    if old_ctx === nothing
        return [(pkg.uuid, nothing, pkg) for pkg in new]
    end
    old = manifest ? load_manifest_deps(old_ctx) : load_direct_deps(old_ctx; unregistered=false)

    all_uuids = union([pkg.uuid for pkg in old], [pkg.uuid for pkg in new])
    return [(uuid, index_pkgs(old, uuid), index_pkgs(new, uuid)) for uuid in all_uuids]
end

function print_status(ctx::Context, old_ctx::Union{Nothing,Context}, header::Symbol,
                      uuids::Vector, names::Vector; manifest=true, diff=false)
    ctx.io = something(ctx.status_io, ctx.io) # for instrumenting tests
    filter = !isempty(uuids) || !isempty(names)
    # print header
    printpkgstyle(ctx, header, pathrepr(manifest ? ctx.env.manifest_file : ctx.env.project_file))
    # setup
    printed_something, empty_diff = false, true
    xs = diff_array(old_ctx, ctx; manifest=manifest)
    xs = sort!(xs, by = (x -> (is_stdlib(x[1]), something(x[3], x[2]).name, x[1])))
    # return early
    if isempty(xs)
        printpkgstyle(ctx, header, manifest ? "empty manifest" : "empty project")
        return nothing
    end
    # main print
    for (uuid, old, new) in xs
        diff && old == new && continue # in diff mode and no diff to show
        empty_diff = false
        filter && !(uuid in uuids) && !(something(new, old).name in names) && continue
        printed_something = true

        printstyled(ctx.io, "   $(string(uuid)[1:8]) "; color = :light_black)
        diff ? print_diff(ctx, old, new) : print_single(ctx, new)
        println(ctx.io)
    end
    if !printed_something
        printpkgstyle(ctx, header, (diff && empty_diff) ? "empty diff" : "no matches")
    end
    return nothing
end

function git_head_context(ctx, project_dir)
    env = EnvCache()
    return try
        LibGit2.with(LibGit2.GitRepo(project_dir)) do repo
            git_path = LibGit2.path(repo)
            project_path = relpath(ctx.env.project_file, git_path)
            manifest_path = relpath(ctx.env.manifest_file, git_path)
            env.project = read_project(GitTools.git_file_stream(repo, "HEAD:$project_path", fakeit=true))
            env.manifest = read_manifest(GitTools.git_file_stream(repo, "HEAD:$manifest_path", fakeit=true))
            Context(;env=env)
        end
    catch err
        nothing
    end
end

function show_update(ctx::Context)
    old_env = EnvCache()
    old_env.project = ctx.env.original_project
    old_env.manifest = ctx.env.original_manifest
    if old_env.project != ctx.env.project || old_env.manifest != ctx.env.manifest
        status(ctx; header=:Updating, mode=PKGMODE_COMBINED, env_diff=old_env)
    end
    return nothing
end

function status(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[];
                header=nothing, mode::PackageMode=PKGMODE_PROJECT, git_diff::Bool=false, env_diff=nothing)
    ctx.io == Base.devnull && return
    # if a packge, print header
    if header === nothing && ctx.env.pkg !== nothing
       printstyled(ctx.io, "Project "; color=Base.info_color(), bold=true)
       println(ctx.io, ctx.env.pkg.name, " v", ctx.env.pkg.version)
    end
    # load old ctx
    old_ctx = nothing
    if git_diff
        project_dir = projectdir(ctx)
        if !ispath(joinpath(project_dir, ".git"))
            @warn "diff option only available for environments in git repositories, ignoring."
        else
            old_ctx = git_head_context(ctx, project_dir)
            if old_ctx === nothing
                @warn "could not read project from HEAD, displaying absolute status instead."
            end
        end
    elseif env_diff !== nothing
        old_ctx = Context(;env=env_diff)
    end
    # display
    filter_uuids = [pkg.uuid for pkg in pkgs if pkg.uuid !== nothing]
    filter_names = [pkg.name for pkg in pkgs if pkg.name !== nothing]
    diff = old_ctx !== nothing
    header = something(header, diff ? :Diff : :Status)
    if mode == PKGMODE_PROJECT || mode == PKGMODE_COMBINED
        print_status(ctx, old_ctx, header, filter_uuids, filter_names; manifest=false, diff=diff)
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        print_status(ctx, old_ctx, header, filter_uuids, filter_names; diff=diff)
    end
end

end # module
