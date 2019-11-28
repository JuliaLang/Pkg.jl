# This file is a part of Julia. License is MIT: https://julialang.org/license

module Operations

using UUIDs
using Random: randstring
import LibGit2

import REPL
using REPL.TerminalMenus
using ..Types, ..Resolve, ..PlatformEngines, ..GitTools, ..Display
import ..depots, ..depots1, ..devdir, ..set_readonly, ..Types.PackageEntry
import ..Artifacts: ensure_all_artifacts_installed, artifact_names, extract_all_hashes, artifact_exists
using ..BinaryPlatforms
import ...Pkg
import ...Pkg: pkg_server

#########
# Utils #
#########
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

function source_path(pkg::PackageSpec)
    return is_stdlib(pkg.uuid)    ? Types.stdlib_path(pkg.name) :
        pkg.path        !== nothing ? pkg.path :
        pkg.repo.source !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        pkg.tree_hash   !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        nothing
end

is_dep(ctx::Context, pkg::PackageSpec) =
    any(uuid -> uuid == pkg.uuid, [uuid for (name, uuid) in ctx.env.project.deps])

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

function load_direct_deps(ctx::Context, pkgs::Vector{PackageSpec};
                          preserve::PreserveLevel=PRESERVE_DIRECT)
    pkgs = copy(pkgs)
    for (name::String, uuid::UUID) in ctx.env.project.deps
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        entry = manifest_info(ctx, uuid)
        push!(pkgs, entry === nothing ?
              PackageSpec(;uuid=uuid, name=name) :
              PackageSpec(;
                uuid      = uuid,
                name      = name,
                path      = entry.path,
                repo      = entry.repo,
                pinned    = entry.pinned,
                tree_hash = entry.tree_hash, # TODO should tree_hash be changed too?
                version   = load_version(entry.version, isfixed(entry), preserve),
              ))
    end
    return pkgs
end

function load_all_deps(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[];
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
            tree_hash = entry.tree_hash, # TODO should tree_hash be changed too?
            version   = load_version(entry.version, isfixed(entry), preserve),
        ))
    end
    return load_direct_deps(ctx, pkgs; preserve=preserve)
end

function is_instantiated(ctx::Context)::Bool
    # Load everything
    pkgs = load_all_deps(ctx)
    # Make sure all paths exist
    for pkg in pkgs
        sourcepath = Operations.source_path(pkg)
        isdir(sourcepath) || return false
        check_artifacts_downloaded(sourcepath) || return false
    end
    return true
end

function update_manifest!(ctx::Context, pkgs::Vector{PackageSpec})
    manifest = ctx.env.manifest
    empty!(manifest)
    #find_registered!(ctx.env, [pkg.uuid for pkg in pkgs]) # Is this necessary? its for `load_deps`...
    for pkg in pkgs
        entry = PackageEntry(;name = pkg.name, version = pkg.version, pinned = pkg.pinned,
                             tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo)
        is_stdlib(pkg.uuid) && (entry.version = nothing) # do not set version for stdlibs
        entry.deps = load_deps(ctx, pkg)
        ctx.env.manifest[pkg.uuid] = entry
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
include("backwards_compatible_isolation.jl")

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
        path = project_rel_path(ctx, source_path(pkg))
        project_file = projectfile_path(path; strict=true)
        project_file === nothing && pkgerror("could not find Project file for package $(pkg.name)")
        project = read_project(project_file)
        return project.deps
    end
end

function collect_project!(ctx::Context, pkg::PackageSpec, path::String, fix_deps_map::Dict{UUID,Vector{PackageSpec}})
    fix_deps_map[pkg.uuid] = valtype(fix_deps_map)()
    project_file = projectfile_path(path; strict=true)
    (project_file === nothing) && pkgerror("could not find project file for $(pkg.name) at $(path)")
    project = read_package(project_file)
    compat = project.compat
    if haskey(compat, "julia") && !(VERSION in Types.semver_spec(compat["julia"]))
        @warn("julia version requirement for package $(pkg.name) not satisfied")
    end
    for (deppkg_name, uuid) in project.deps
        vspec = haskey(compat, deppkg_name) ? Types.semver_spec(compat[deppkg_name]) : VersionSpec()
        deppkg = PackageSpec(deppkg_name, uuid, vspec)
        push!(fix_deps_map[pkg.uuid], deppkg)
    end
    if project.version !== nothing
        pkg.version = project.version
    else
        # @warn "project file for $(pkg.name) is missing a `version` entry"
        set_maximum_version_registry!(ctx, pkg)
    end
    return
end

istracking(pkg) = pkg.path !== nothing || pkg.repo.source !== nothing
isfixed(pkg) = istracking(pkg) || pkg.pinned

function collect_fixed!(ctx::Context, pkgs::Vector{PackageSpec}, names::Dict{UUID, String})
    fix_deps_map = Dict{UUID,Vector{PackageSpec}}()
    for pkg in pkgs
        path = project_rel_path(ctx, source_path(pkg))
        if !isdir(path)
            pkgerror("path $(path) for package $(pkg.name) no longer exists. Remove the package or `develop` it at a new path")
        end
        collect_project!(ctx, pkg, path, fix_deps_map)
    end

    fixed = Dict{UUID,Resolve.Fixed}()
    # Collect the dependencies for the fixed packages
    for (uuid, deps) in fix_deps_map
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

# Resolve a set of versions given package version specs
# looks at uuid, version, repo/path,
# sets version to a VersionNumber
# adds any other packages which may be in the dependency graph
# all versioned packges should have a `tree_hash`
function resolve_versions!(ctx::Context, pkgs::Vector{PackageSpec})
    # compatibility
    proj_compat = Types.project_compatibility(ctx, "julia")
    v = intersect(VERSION, proj_compat)
    if isempty(v)
        @warn "julia version requirement for project not satisfied" _module=nothing _file=nothing
    end

    # anything not mentioned is fixed
    names = Dict{UUID, String}(uuid => stdlib for (uuid, stdlib) in ctx.stdlibs)

    # construct data structures for resolver and call it
    # this also sets pkg.version for fixed packages
    fixed = collect_fixed!(ctx, filter(istracking, pkgs), names)

    # non fixed packages are `add`ed by version: their version is either restricted or free
    # fixed packages are `dev`ed or `add`ed by repo
    # at this point, fixed packages have a version and `deps`

    # check compat
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
            name = (uuid in keys(ctx.stdlibs)) ? ctx.stdlibs[uuid] : registered_name(ctx, uuid)
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
            if uuid in keys(ctx.stdlibs)
                path = Types.stdlib_path(ctx.stdlibs[uuid])
                proj_file = projectfile_path(path; strict=true)
                @assert proj_file !== nothing
                proj = Types.read_package(proj_file)

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

function download_artifacts(pkgs::Vector{PackageSpec}; platform::Platform=platform_key_abi(),
                            verbose::Bool=false)
    # Filter out packages that have no source_path()
    pkg_roots = String[p for p in source_path.(pkgs) if p !== nothing]
    return download_artifacts(pkg_roots; platform=platform, verbose=verbose)
end

function download_artifacts(pkg_roots::Vector{String}; platform::Platform=platform_key_abi(),
                            verbose::Bool=false)
    for path in pkg_roots
        # Check to see if this package has an (Julia)Artifacts.toml
        for f in artifact_names
            artifacts_toml = joinpath(path, f)
            if isfile(artifacts_toml)
                ensure_all_artifacts_installed(artifacts_toml; platform=platform, verbose=verbose)
                write_env_usage(artifacts_toml, "artifact_usage.toml")
                break
            end
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
        path = source_path(pkg)
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
                        push!(archive_urls, url => false)
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

################################
# Manifest update and pruning #
################################
project_rel_path(ctx::Context, path::String) =
    normpath(joinpath(dirname(ctx.env.project_file), path))

function prune_manifest(ctx::Context)
    keep = collect(values(ctx.env.project.deps))
    ctx.env.manifest = prune_manifest!(ctx.env.manifest, keep)
end

function prune_manifest!(manifest::Dict, keep::Vector{UUID})
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
        pkg.uuid in keys(ctx.stdlibs) && continue
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
        uuid in keys(ctx.stdlibs) && return
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
        uuid in keys(ctx.stdlibs) && continue
        if Types.is_project_uuid(ctx, uuid)
            path = dirname(ctx.env.project_file)
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
            version = v"0.0"
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

        if !isfile(projectfile_path(builddir(source_path)))
            backwards_compat_for_build(ctx, pkg, build_file,
                                       verbose, might_need_to_resolve, max_name)
            continue
        end

        log_file = splitext(build_file)[1] * ".log"
        printpkgstyle(ctx, :Building,
                      rpad(name * " ", max_name + 1, "─") * "→ " * Types.pathrepr(log_file))

        sandbox(ctx, pkg, source_path, builddir(source_path)) do
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
    Display.print_env_diff(ctx)
    write_env(ctx.env)
end

update_package_add(ctx::Context, pkg::PackageSpec, ::Nothing, is_dep::Bool) = pkg
function update_package_add(ctx::Context, pkg::PackageSpec, entry::PackageEntry, is_dep::Bool)
    if entry.pinned
        if pkg.version == VersionSpec()
            println(ctx.io, "`$(pkg.name)` is pinned at `v$(entry.version)`: maintaining pinned version")
        end
        return PackageSpec(; uuid=pkg.uuid, name=pkg.name, pinned=true,
                           version=entry.version, tree_hash=entry.tree_hash)
    end
    if entry.path !== nothing || entry.repo.source !== nothing || pkg.repo.source !== nothing
        return pkg # overwrite everything, nothing to copy over
    end
    if is_stdlib(pkg.uuid)
        return pkg # stdlibs are not versioned like other packages
    elseif is_dep && ((isa(pkg.version, VersionNumber) && entry.version == pkg.version) ||
                      (!isa(pkg.version, VersionNumber) && entry.version ∈ pkg.version))
        # leave the package as is at the installed version
        return PackageSpec(; uuid=pkg.uuid, name=pkg.name, version=entry.version,
                           tree_hash=entry.tree_hash)
    end
    # adding a new version not compatible with the old version, so we just overwrite
    return pkg
end

function check_registered(ctx::Context, pkgs::Vector{PackageSpec})
    pkgs = filter(tracking_registered_version, pkgs)
    find_registered!(ctx, UUID[pkg.uuid for pkg in pkgs])
    for pkg in pkgs
        isempty(registered_paths(ctx, pkg.uuid)) || continue
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

function tiered_resolve(ctx::Context, pkgs::Vector{PackageSpec})
    try # do not modify existing subgraph
        return targeted_resolve(ctx, pkgs, PRESERVE_ALL)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try # do not modify existing direct deps
        return targeted_resolve(ctx, pkgs, PRESERVE_DIRECT)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try
        return targeted_resolve(ctx, pkgs, PRESERVE_SEMVER)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    return targeted_resolve(ctx, pkgs, PRESERVE_NONE)
end

function targeted_resolve(ctx::Context, pkgs::Vector{PackageSpec}, preserve::PreserveLevel)
    if preserve == PRESERVE_ALL
        pkgs = load_all_deps(ctx, pkgs)
    elseif preserve == PRESERVE_DIRECT
        pkgs = load_direct_deps(ctx, pkgs)
    elseif preserve == PRESERVE_SEMVER
        pkgs = load_direct_deps(ctx, pkgs; preserve=preserve)
    elseif preserve == PRESERVE_NONE
        pkgs = load_direct_deps(ctx, pkgs; preserve=preserve)
    end
    check_registered(ctx, pkgs)
    resolve_versions!(ctx, pkgs)
    return pkgs
end

function _resolve(ctx::Context, pkgs::Vector{PackageSpec}, preserve::PreserveLevel)
    printpkgstyle(ctx, :Resolving, "package versions...")
    return preserve == PRESERVE_TIERED ?
        tiered_resolve(ctx, pkgs) :
        targeted_resolve(ctx, pkgs, preserve)
end

function add(ctx::Context, pkgs::Vector{PackageSpec}, new_git=UUID[];
             preserve::PreserveLevel=PRESERVE_TIERED, platform::Platform=platform_key_abi())
    assert_can_add(ctx, pkgs)
    # load manifest data
    for (i, pkg) in pairs(pkgs)
        entry = manifest_info(ctx, pkg.uuid)
        pkgs[i] = update_package_add(ctx, pkg, entry, is_dep(ctx, pkg))
    end
    foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, pkgs) # update set of deps
    # resolve
    pkgs = _resolve(ctx, pkgs, preserve)
    update_manifest!(ctx, pkgs)
    new_apply = download_source(ctx, pkgs)

    # After downloading resolutionary packages, search for (Julia)Artifacts.toml files
    # and ensure they are all downloaded and unpacked as well:
    download_artifacts(pkgs; platform=platform)

    Display.print_env_diff(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git))
end

# Input: name, uuid, and path
function develop(ctx::Context, pkgs::Vector{PackageSpec}, new_git::Vector{UUID};
                 strict::Bool=false, platform::Platform=platform_key_abi())
    assert_can_add(ctx, pkgs)
    # no need to look at manifest.. dev will just nuke whatever is there before
    for pkg in pkgs
        ctx.env.project.deps[pkg.name] = pkg.uuid
    end
    pkgs = strict ? load_all_deps(ctx, pkgs) : load_direct_deps(ctx, pkgs)
    check_registered(ctx, pkgs)

    # resolve & apply package versions
    resolve_versions!(ctx, pkgs)
    update_manifest!(ctx, pkgs)
    new_apply = download_source(ctx, pkgs; readonly=true)
    download_artifacts(pkgs; platform=platform)

    Display.print_env_diff(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git))
end

# load version constraint
# if version isa VersionNumber -> set tree_hash too
up_load_versions!(ctx::Context, pkg::PackageSpec, ::Nothing, level::UpgradeLevel) = false
function up_load_versions!(ctx::Context, pkg::PackageSpec, entry::PackageEntry, level::UpgradeLevel)
    entry.version !== nothing || return false # no version to set
    if entry.pinned || level == UPLEVEL_FIXED
        pkg.version = entry.version
        pkg.tree_hash = entry.tree_hash
    elseif entry.repo.source !== nothing # repo packages have a version but are treated special
        pkg.repo = entry.repo
        if level == UPLEVEL_MAJOR
            # Updating a repo package is equivalent to adding it
            new = Types.handle_repo_add!(ctx, pkg)
            pkg.version = entry.version
            if pkg.tree_hash != entry.tree_hash
                # TODO parse find_installed and set new version
            end
            return new
        else
            pkg.version = entry.version
            pkg.tree_hash = entry.tree_hash
        end
    else
        ver = entry.version
        r = level == UPLEVEL_PATCH ? VersionRange(ver.major, ver.minor) :
            level == UPLEVEL_MINOR ? VersionRange(ver.major) :
            level == UPLEVEL_MAJOR ? VersionRange() :
                error("unexpected upgrade level: $level")
        pkg.version = VersionSpec(r)
    end
    return false
end

up_load_manifest_info!(pkg::PackageSpec, ::Nothing) = nothing
function up_load_manifest_info!(pkg::PackageSpec, entry::PackageEntry)
    pkg.name = entry.name # TODO check name is same
    pkg.repo = entry.repo # TODO check that repo is same
    pkg.path = entry.path
    pkg.pinned = entry.pinned
    # `pkg.version` and `pkg.tree_hash` is set by `up_load_versions!`
end

function up(ctx::Context, pkgs::Vector{PackageSpec}, level::UpgradeLevel)
    new_git = UUID[]
    # TODO check all pkg.version == VersionSpec()
    # set version constraints according to `level`
    for pkg in pkgs
        new = up_load_versions!(ctx, pkg, manifest_info(ctx, pkg.uuid), level)
        new && push!(new_git, pkg.uuid) #TODO put download + push! in utility function
    end
    # load rest of manifest data (except for version info)
    for pkg in pkgs
        up_load_manifest_info!(pkg, manifest_info(ctx, pkg.uuid))
    end
    pkgs = load_direct_deps(ctx, pkgs) # make sure to include at least direct deps
    check_registered(ctx, pkgs)
    resolve_versions!(ctx, pkgs)
    prune_manifest(ctx)
    update_manifest!(ctx, pkgs)
    new_apply = download_source(ctx, pkgs)

    download_artifacts(pkgs)
    Display.print_env_diff(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, union(UUID[pkg.uuid for pkg in new_apply], new_git))
    # TODO what to do about repo packages?
end

function update_package_pin!(ctx::Context, pkg::PackageSpec, entry::PackageEntry)
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
        if entry.repo.source !== nothing || entry.path !== nothing
            # A pin in this case includes an implicit `free` to switch to tracking registered versions
            # First, make sure the package is registered so we have something to free to
            if isempty(registered_paths(ctx, pkg.uuid))
                pkgerror("unable to pin unregistered package $(err_rep(pkg)) to an arbritrary version")
            end
        end
    end
end

function pin(ctx::Context, pkgs::Vector{PackageSpec})
    foreach(pkg -> update_package_pin!(ctx, pkg, manifest_info(ctx, pkg.uuid)), pkgs)
    pkgs = load_direct_deps(ctx, pkgs)
    check_registered(ctx, pkgs)

    resolve_versions!(ctx, pkgs)
    update_manifest!(ctx, pkgs)

    new = download_source(ctx, pkgs)
    download_artifacts(pkgs)
    Display.print_env_diff(ctx)
    write_env(ctx.env) # write env before building
    build_versions(ctx, UUID[pkg.uuid for pkg in new])
end

function update_package_free!(ctx::Context, pkg::PackageSpec, entry::PackageEntry)
    if entry.pinned
        pkg.pinned = false
        is_stdlib(pkg.uuid) && return # nothing left to do
        pkg.version = entry.version
        pkg.repo = entry.repo
        pkg.tree_hash = entry.tree_hash
        return
    end
    if entry.path !== nothing || entry.repo.source !== nothing
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
    foreach(pkg -> update_package_free!(ctx, pkg, manifest_info(ctx, pkg.uuid)), pkgs)

    if any(pkg -> pkg.version == VersionSpec(), pkgs)
        pkgs = load_direct_deps(ctx, pkgs)
        check_registered(ctx, pkgs)
        resolve_versions!(ctx, pkgs)
        update_manifest!(ctx, pkgs)
        new = download_source(ctx, pkgs)
        download_artifacts(new)
        Display.print_env_diff(ctx)
        write_env(ctx.env) # write env before building
        build_versions(ctx, UUID[pkg.uuid for pkg in new])
    else
        foreach(pkg -> manifest_info(ctx, pkg.uuid).pinned = false, pkgs)
        Display.print_env_diff(ctx)
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
    # load target deps
    keep = Types.is_project(ctx, target) ? collect(values(env.project.deps)) : [target.uuid]
    # preserve test deps
    project = read_project(test_project)
    project !== nothing && append!(keep, collect(values(project.deps)))
    # prune and return
    graph = prune_manifest!(env.manifest, keep)
    return graph
end

function abspath!(ctx, manifest::Dict{UUID,PackageEntry})
    for (uuid, entry) in manifest
        entry.path !== nothing || continue
        entry.path = project_rel_path(ctx, entry.path)
    end
    return manifest
end

# ctx + pkg used to compute parent dep graph
function sandbox(fn::Function, ctx::Context, target::PackageSpec, target_path::String,
                 sandbox_path::String)
    active_manifest = manifestfile_path(dirname(ctx.env.project_file))
    sandbox_project = projectfile_path(sandbox_path)

    mktempdir() do tmp
        tmp_project  = projectfile_path(tmp)
        tmp_manifest = manifestfile_path(tmp)

        # Copy env info over to temp env
        isfile(sandbox_project) && cp(sandbox_project, tmp_project)
        if isfile(active_manifest)
            @debug "Active Manifest detected"
            # copy over preserved subgraph
            # abspath! to maintain location of all deved nodes
            Types.write_manifest(abspath!(ctx, sandbox_preserve(ctx, target, tmp_project)),
                                 tmp_manifest)
        end
        with_temp_env(tmp) do
            try
                Pkg.API.develop(PackageSpec(;repo=GitRepo(;source=target_path)); strict=true)
                @debug "Using _parent_ dep graph"
            catch err# TODO
                @error err
                isfile(tmp_manifest) && Base.rm(tmp_manifest) # retry with a clean dependency graph
                Pkg.API.develop(PackageSpec(;repo=GitRepo(;source=target_path)))
                @debug "Using _clean_ dep graph"
            end
            # Run sandboxed code
            withenv(fn, "JULIA_LOAD_PATH" => tmp)
        end
    end
end

function update_package_test!(pkg::PackageSpec, entry::PackageEntry)
    is_stdlib(pkg.uuid) && return
    pkg.version = entry.version
    pkg.tree_hash = entry.tree_hash
    pkg.repo = entry.repo
    pkg.path = entry.path
    pkg.pinned = entry.pinned
end

testdir(source_path::String) = joinpath(source_path, "test")
testfile(source_path::String) = joinpath(testdir(source_path), "runtests.jl")
function test(ctx::Context, pkgs::Vector{PackageSpec};
        coverage=false, test_fn=nothing,
        julia_args::Cmd=``,
        test_args::Cmd=``)
    Pkg.instantiate(ctx)

    # load manifest data
    for pkg in pkgs
        if Types.is_project_uuid(ctx, pkg.uuid)
            pkg.path = dirname(ctx.env.project_file)
            pkg.version = ctx.env.pkg.version
        else
            update_package_test!(pkg, manifest_info(ctx, pkg.uuid))
        end
    end

    # See if we can find the test files for all packages
    missing_runtests = String[]
    source_paths     = String[]
    for pkg in pkgs
        pkg.special_action = PKGSPEC_TESTED
        sourcepath = project_rel_path(ctx, source_path(pkg)) # TODO
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
        if !isfile(projectfile_path(testdir(source_path)))
            backwards_compatibility_for_test(ctx, pkg, testfile(source_path),
                                             pkgs_errored, coverage; julia_args=julia_args, test_args=test_args)
            continue
        end

        printpkgstyle(ctx, :Testing, pkg.name)
        sandbox(ctx, pkg, source_path, testdir(source_path)) do
            println(ctx.io, "Running sandbox")
            test_fn !== nothing && test_fn()
            Display.status(Context(), mode=PKGMODE_PROJECT)
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
    git_source = pkg.repo.source === nothing ? nothing :
        isurl(pkg.repo.source) ? pkg.repo.source :
        project_rel_path(ctx, pkg.repo.source)
    info = PackageInfo(
        name                 = pkg.name,
        version              = pkg.version != VersionSpec() ? pkg.version : nothing,
        tree_hash            = pkg.tree_hash === nothing ? nothing : string(pkg.tree_hash), # TODO or should it just be a SHA?
        ispinned             = pkg.pinned,
        is_tracking_registry = pkg.repo.source === nothing && pkg.path === nothing,
        isdeveloped          = pkg.path !== nothing,
        git_revision         = pkg.repo.rev,
        git_source           = git_source,
        source               = project_rel_path(ctx, source_path(pkg)),
        dependencies         = copy(entry.deps), #TODO is copy needed?
    )
    return info
end

end # module
