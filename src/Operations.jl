# This file is a part of Julia. License is MIT: https://julialang.org/license

module Operations

using UUIDs
using Random: randstring
import LibGit2, Dates, TOML

import REPL
using REPL.TerminalMenus
using ..Types, ..Resolve, ..PlatformEngines, ..GitTools, ..MiniProgressBars
import ..depots, ..depots1, ..devdir, ..set_readonly, ..Types.PackageEntry
import ..Artifacts: ensure_artifact_installed, artifact_names, extract_all_hashes,
                    artifact_exists, select_downloadable_artifacts
using Base.BinaryPlatforms
import ...Pkg
import ...Pkg: pkg_server, Registry, pathrepr, can_fancyprint, printpkgstyle, stderr_f

#########
# Utils #
#########

function find_installed(name::String, uuid::UUID, sha1::SHA1)
    slug_default = Base.version_slug(uuid, sha1)
    # 4 used to be the default so look there first
    for slug in (slug_default, Base.version_slug(uuid, sha1, 4))
        for depot in depots()
            path = abspath(depot, "packages", name, slug)
            ispath(path) && return path
        end
    end
    return abspath(depots1(), "packages", name, slug_default)
end

# more accurate name is `should_be_tracking_registered_version`
# the only way to know for sure is to key into the registries
tracking_registered_version(pkg::Union{PackageSpec, PackageEntry}, julia_version=VERSION) =
    !is_stdlib(pkg.uuid, julia_version) && pkg.path === nothing && pkg.repo.source === nothing

function source_path(project_file::String, pkg::Union{PackageSpec, PackageEntry}, julia_version = VERSION)
    return is_stdlib(pkg.uuid, julia_version) ? Types.stdlib_path(pkg.name) :
        pkg.path        !== nothing ? joinpath(dirname(project_file), pkg.path) :
        pkg.repo.source !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        pkg.tree_hash   !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        nothing
end

#TODO rename
function load_version(version, fixed, preserve::PreserveLevel)
    if version === nothing
        return VersionSpec() # some stdlibs dont have a version
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

function load_direct_deps(env::EnvCache, pkgs::Vector{PackageSpec}=PackageSpec[];
                          preserve::PreserveLevel=PRESERVE_DIRECT)
    pkgs = copy(pkgs)
    for (name::String, uuid::UUID) in env.project.deps
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        entry = manifest_info(env.manifest, uuid)
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

function load_manifest_deps(manifest::Manifest, pkgs::Vector{PackageSpec}=PackageSpec[];
                            preserve::PreserveLevel=PRESERVE_ALL)
    pkgs = copy(pkgs)
    for (uuid, entry) in manifest.deps
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
    return pkgs
end

function load_all_deps(env::EnvCache, pkgs::Vector{PackageSpec}=PackageSpec[];
                       preserve::PreserveLevel=PRESERVE_ALL)
    pkgs = load_manifest_deps(env.manifest, pkgs; preserve=preserve)
    return load_direct_deps(env, pkgs; preserve=preserve)
end

function is_instantiated(env::EnvCache)::Bool
    # Load everything
    pkgs = load_all_deps(env)
    # If the top-level project is a package, ensure it is instantiated as well
    if env.pkg !== nothing
        # Top-level project may already be in the manifest (cyclic deps)
        # so only add it if it isn't there
        idx = findfirst(x -> x.uuid == env.pkg.uuid, pkgs)
        if idx === nothing
            push!(pkgs, Types.PackageSpec(name=env.pkg.name, uuid=env.pkg.uuid, version=env.pkg.version, path=dirname(env.project_file)))
        end
    end
    # Make sure all paths/artifacts exist
    return all(pkg -> is_package_downloaded(env.project_file, pkg), pkgs)
end

function update_manifest!(env::EnvCache, pkgs::Vector{PackageSpec}, deps_map, julia_version)
    manifest = env.manifest
    empty!(manifest.deps)
    if env.pkg !== nothing
        pkgs = push!(copy(pkgs), env.pkg::PackageSpec)
    end
    for pkg in pkgs
        entry = PackageEntry(;name = pkg.name, version = pkg.version, pinned = pkg.pinned,
                             tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid=pkg.uuid)
        if is_stdlib(pkg.uuid, julia_version)
            # do not set version for stdlibs
            entry.version = nothing
        end
        if Types.is_project(env, pkg)
            entry.deps = env.project.deps
        else
            entry.deps = deps_map[pkg.uuid]
        end
        env.manifest.deps[pkg.uuid] = entry
    end
    prune_manifest(env)
end


####################
# Registry Loading #
####################

function load_tree_hash!(registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec, julia_version)
    tracking_registered_version(pkg, julia_version) || return pkg
    hash = nothing
    for reg in registries
        reg_pkg = get(reg, pkg.uuid, nothing)
        reg_pkg === nothing && continue
        pkg_info = Registry.registry_info(reg_pkg)
        version_info = get(pkg_info.version_info, pkg.version, nothing)
        version_info === nothing && continue
        hash′ = version_info.git_tree_sha1
        if hash !== nothing
            hash == hash′ || pkgerror("hash mismatch in registries for $(pkg.name) at version $(pkg.version)")
        end
        hash = hash′
    end
    pkg.tree_hash = hash
    return pkg
end

#######################################
# Dependency gathering and resolution #
#######################################
get_compat(proj::Project, name::String) = haskey(proj.compat, name) ? proj.compat[name].val : Types.VersionSpec()
get_compat_str(proj::Project, name::String) = haskey(proj.compat, name) ? proj.compat[name].str : nothing
function set_compat(proj::Project, name::String, compat::String)
    proj.compat[name] = Types.Compat(Types.semver_spec(compat), compat)
end

function collect_project!(pkg::PackageSpec, path::String,
                          deps_map::Dict{UUID,Vector{PackageSpec}})
    deps_map[pkg.uuid] = PackageSpec[]
    project_file = projectfile_path(path; strict=true)
    if project_file === nothing
        pkgerror("could not find project file for package $(err_rep(pkg)) at `$path`")
    end
    project = read_package(project_file)
    julia_compat = get_compat(project, "julia")
    #=
    # TODO, this should either error or be quiet
    if julia_compat !== nothing && !(VERSION in julia_compat)
        println(io, "julia version requirement for package $(err_rep(pkg)) not satisfied")
    end
    =#
    for (name, uuid) in project.deps
        vspec = get_compat(project, name)
        push!(deps_map[pkg.uuid], PackageSpec(name, uuid, vspec))
    end
    if project.version !== nothing
        pkg.version = project.version
    else
        # @warn("project file for $(pkg.name) is missing a `version` entry")
        pkg.version = VersionNumber(0)
    end
    return
end

is_tracking_path(pkg) = pkg.path !== nothing
is_tracking_repo(pkg) = pkg.repo.source !== nothing
is_tracking_registry(pkg) = !is_tracking_path(pkg) && !is_tracking_repo(pkg)
isfixed(pkg) = !is_tracking_registry(pkg) || pkg.pinned

function collect_developed!(env::EnvCache, pkg::PackageSpec, developed::Vector{PackageSpec})
    source = project_rel_path(env, source_path(env.project_file, pkg))
    source_env = EnvCache(projectfile_path(source))
    pkgs = load_all_deps(source_env)
    for pkg in filter(is_tracking_path, pkgs)
        if any(x -> x.uuid == pkg.uuid, developed)
            continue
        end
        # normalize path
        pkg.path = Types.relative_project_path(env.project_file,
                   project_rel_path(source_env,
                   source_path(source_env.project_file, pkg)))
        push!(developed, pkg)
        collect_developed!(env, pkg, developed)
    end
end

function collect_developed(env::EnvCache, pkgs::Vector{PackageSpec})
    developed = PackageSpec[]
    for pkg in filter(is_tracking_path, pkgs)
        collect_developed!(env, pkg, developed)
    end
    return developed
end

function collect_fixed!(env::EnvCache, pkgs::Vector{PackageSpec}, names::Dict{UUID, String})
    deps_map = Dict{UUID,Vector{PackageSpec}}()
    if env.pkg !== nothing
        pkg = env.pkg
        collect_project!(pkg, dirname(env.project_file), deps_map)
        names[pkg.uuid] = pkg.name
    end
    for pkg in pkgs
        path = project_rel_path(env, source_path(env.project_file, pkg))
        if !isdir(path)
            pkgerror("expected package $(err_rep(pkg)) to exist at path `$path`")
        end
        collect_project!(pkg, path, deps_map)
    end

    fixed = Dict{UUID,Resolve.Fixed}()
    # Collect the dependencies for the fixed packages
    for (uuid, deps) in deps_map
        q = Dict{UUID, VersionSpec}()
        for dep in deps
            names[dep.uuid] = dep.name
            q[dep.uuid] = dep.version
        end
        if Types.is_project_uuid(env, uuid)
            fix_pkg = env.pkg
        else
            idx = findfirst(pkg -> pkg.uuid == uuid, pkgs)
            fix_pkg = pkgs[idx]
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
function resolve_versions!(env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, julia_version)
    # compatibility
    if julia_version !== nothing
        v = intersect(julia_version, get_compat(env.project, "julia"))
        if isempty(v)
            @warn "julia version requirement for project not satisfied" _module=nothing _file=nothing
        end
    end
    names = Dict{UUID, String}(uuid => stdlib for (uuid, stdlib) in stdlibs())
    # recursive search for packages which are tracking a path
    developed = collect_developed(env, pkgs)
    # But we only want to use information for those packages that we don't know about
    for pkg in developed
        if !any(x -> x.uuid == pkg.uuid, pkgs)
            push!(pkgs, pkg)
        end
    end
    # this also sets pkg.version for fixed packages
    fixed = collect_fixed!(env, filter(!is_tracking_registry, pkgs), names)
    # non fixed packages are `add`ed by version: their version is either restricted or free
    # fixed packages are `dev`ed or `add`ed by repo
    # at this point, fixed packages have a version and `deps`

    @assert length(Set(pkg.uuid::UUID for pkg in pkgs)) == length(pkgs)

    # check compat
    for pkg in pkgs
        compat = get_compat(env.project, pkg.name)
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
    graph, compat_map = deps_graph(env, registries, names, reqs, fixed, julia_version)
    Resolve.simplify_graph!(graph)
    vers = Resolve.resolve(graph)

    # update vector of package versions
    for (uuid, ver) in vers
        idx = findfirst(p -> p.uuid == uuid, pkgs)
        if idx !== nothing
            pkg = pkgs[idx]
            # Fixed packages are not returned by resolve (they already have their version set)
            pkg.version = vers[pkg.uuid]
        else
            name = is_stdlib(uuid) ? stdlibs()[uuid] : registered_name(registries, uuid)
            push!(pkgs, PackageSpec(;name=name, uuid=uuid, version=ver))
        end
    end
    final_deps_map = Dict{UUID, Dict{String, UUID}}()
    for pkg in pkgs
        load_tree_hash!(registries, pkg, julia_version)
        deps = begin
            if pkg.uuid in keys(fixed)
                deps_fixed = Dict{String, UUID}()
                for dep in keys(fixed[pkg.uuid].requires)
                    deps_fixed[names[dep]] = dep
                end
                deps_fixed
            else
                d = Dict{String, UUID}()
                for (uuid, _) in compat_map[pkg.uuid][pkg.version]
                    d[names[uuid]]  = uuid
                end
                d
            end
        end
        # julia is an implicit dependency
        filter!(d -> d.first != "julia", deps)
        final_deps_map[pkg.uuid] = deps
    end
    return final_deps_map
end

get_or_make!(d::Dict{K,V}, k::K) where {K,V} = get!(d, k) do; V() end

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
function deps_graph(env::EnvCache, registries::Vector{Registry.RegistryInstance}, uuid_to_name::Dict{UUID,String},
                    reqs::Resolve.Requires, fixed::Dict{UUID,Resolve.Fixed}, julia_version)
    uuids = Set{UUID}()
    union!(uuids, keys(reqs))
    union!(uuids, keys(fixed))
    for fixed_uuids in map(fx->keys(fx.requires), values(fixed))
        union!(uuids, fixed_uuids)
    end

    seen = Set{UUID}()

    # pkg -> version -> (dependency => compat):
    all_compat = Dict{UUID,Dict{VersionNumber,Dict{UUID,VersionSpec}}}()

    for (fp, fx) in fixed
        all_compat[fp]   = Dict(fx.version => Dict{UUID,VersionSpec}())
    end

    while true
        unseen = setdiff(uuids, seen)
        isempty(unseen) && break
        for uuid in unseen
            push!(seen, uuid)
            uuid in keys(fixed) && continue
            all_compat_u   = get_or_make!(all_compat,   uuid)

            # If we're requesting resolution of a package that is an stdlib and is not registered,
            # we must special-case it here.  This is further complicated by the fact that we can
            # ask this question relative to a particular Julia version.
            if is_unregistered_stdlib(uuid) || is_stdlib(uuid, julia_version)
                path = Types.stdlib_path(stdlibs()[uuid])
                proj_file = projectfile_path(path; strict=true)
                @assert proj_file !== nothing
                proj = read_package(proj_file)

                v = something(proj.version, VERSION)

                # TODO look at compat section for stdlibs?
                all_compat_u_vr = get_or_make!(all_compat_u, v)
                for (_, other_uuid) in proj.deps
                    push!(uuids, other_uuid)
                    all_compat_u_vr[other_uuid] = VersionSpec()
                end
            else
                for reg in registries
                    pkg = get(reg, uuid, nothing)
                    pkg === nothing && continue
                    info = Registry.registry_info(pkg)
                    for (v, compat_info) in Registry.compat_info(info)
                        # Filter yanked and if we are in offline mode also downloaded packages
                        # TODO, pull this into a function
                        Registry.isyanked(info, v) && continue
                        if Pkg.OFFLINE_MODE[]
                            pkg_spec = PackageSpec(name=pkg.name, uuid=pkg.uuid, version=v, tree_hash=Registry.treehash(info, v))
                            is_package_downloaded(env.project_file, pkg_spec) || continue
                        end

                        all_compat_u[v] = compat_info
                        union!(uuids, keys(compat_info))
                    end
                end
            end
        end
    end

    for uuid in uuids
        uuid == JULIA_UUID && continue
        if !haskey(uuid_to_name, uuid)
            name = registered_name(registries, uuid)
            name === nothing && pkgerror("cannot find name corresponding to UUID $(uuid) in a registry")
            uuid_to_name[uuid] = name
            entry = manifest_info(env.manifest, uuid)
            entry ≡ nothing && continue
            uuid_to_name[uuid] = entry.name
        end
    end

    return Resolve.Graph(all_compat, uuid_to_name, reqs, fixed, false, julia_version),
           all_compat
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
    version_path::String;
    io::IO=stderr_f()
)::Bool
    tmp_objects = String[]
    url_success = false
    for (url, top) in urls
        path = tempname() * randstring(6)
        push!(tmp_objects, path) # for cleanup
        url_success = true
        try
            PlatformEngines.download(url, path; verbose=false, io=io)
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
    io::IO,
    uuid::UUID,
    name::String,
    hash::SHA1,
    urls::Set{String},
    version_path::String
)::Nothing
    repo = nothing
    tree = nothing
    # TODO: Consolodate this with some of the repo handling in Types.jl
    try
        clones_dir = joinpath(depots1(), "clones")
        ispath(clones_dir) || mkpath(clones_dir)
        repo_path = joinpath(clones_dir, string(uuid))
        repo = GitTools.ensure_clone(io, repo_path, first(urls); isbare=true,
                                     header = "[$uuid] $name from $(first(urls))")
        git_hash = LibGit2.GitHash(hash.bytes)
        for url in urls
            try LibGit2.with(LibGit2.GitObject, repo, git_hash) do g
                end
                break # object was found, we can stop
            catch err
                err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            end
            GitTools.fetch(io, repo, url, refspecs=refspecs)
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

function collect_artifacts(pkg_root::String; platform::AbstractPlatform=HostPlatform())
    # Check to see if this package has an (Julia)Artifacts.toml
    artifacts_tomls = Tuple{String,Dict}[]
    for f in artifact_names
        artifacts_toml = joinpath(pkg_root, f)
        if isfile(artifacts_toml)
            selector_path = joinpath(pkg_root, ".pkg", "select_artifacts.jl")

            # If there is a dynamic artifact selector, run that in an appropriate sandbox to select artifacts
            if isfile(selector_path)
                select_cmd = Cmd(`$(gen_build_code(selector_path)) $(triplet(platform))`)
                addenv(select_cmd, "JULIA_LOAD_PATH" => "@stdlib")
                meta_toml = String(read(select_cmd))
                push!(artifacts_tomls, (artifacts_toml, TOML.parse(meta_toml)))
            else
                # Otherwise, use the standard selector from `Artifacts`
                artifacts = select_downloadable_artifacts(artifacts_toml; platform)
                push!(artifacts_tomls, (artifacts_toml, artifacts))
            end
            break
        end
    end
    return artifacts_tomls
end

function download_artifacts(env::EnvCache;
                            platform::AbstractPlatform=HostPlatform(),
                            julia_version = VERSION,
                            verbose::Bool=false,
                            io::IO=stderr_f())
    pkg_roots = String[]
    for (uuid, pkg) in env.manifest.deps
        pkg = manifest_info(env.manifest, uuid)
        pkg_root = source_path(env.project_file, pkg, julia_version)
        pkg_root === nothing || push!(pkg_roots, pkg_root)
    end
    envpkg = env.pkg
    envpkg === nothing || push!(pkg_roots, envpkg.path)
    for pkg_root in pkg_roots
        for (artifacts_toml, artifacts) in collect_artifacts(pkg_root; platform)
            # For each Artifacts.toml, install each artifact we've collected from it
            for name in keys(artifacts)
                ensure_artifact_installed(name, artifacts[name], artifacts_toml;
                                            verbose, quiet_download=!(io isa Base.TTY), io=io)
            end
            write_env_usage(artifacts_toml, "artifact_usage.toml")
        end
    end
end

function check_artifacts_downloaded(pkg_root::String; platform::AbstractPlatform=HostPlatform())
    for (artifacts_toml, artifacts) in collect_artifacts(pkg_root; platform)
        for name in keys(artifacts)
            if !artifact_exists(Base.SHA1(artifacts[name]["git-tree-sha1"]))
                return false
            end
            break
        end
    end
    return true
end


function find_urls(registries::Vector{Registry.RegistryInstance}, uuid::UUID)
    urls = Set{String}()
    for reg in registries
        reg_pkg = get(reg, uuid, nothing)
        reg_pkg === nothing && continue
        info = Registry.registry_info(reg_pkg)
        repo = info.repo
        repo === nothing && continue
        push!(urls, repo)
    end
    return urls
end


function download_source(ctx::Context; readonly=true)
    pkgs_to_install = NamedTuple{(:pkg, :urls, :path), Tuple{PackageEntry, Set{String}, String}}[]
    for pkg in values(ctx.env.manifest.deps)
        tracking_registered_version(pkg, ctx.julia_version) || continue
        path = source_path(ctx.env.project_file, pkg, ctx.julia_version)
        path === nothing && continue
        ispath(path) && continue
        urls = find_urls(ctx.registries, pkg.uuid)
        push!(pkgs_to_install, (;pkg, urls, path))
    end

    ########################################
    # Install from archives asynchronously #
    ########################################

    missed_packages = eltype(pkgs_to_install)[]
    widths = [textwidth(pkg.name) for (pkg, _) in pkgs_to_install]
    max_name = maximum(widths; init=0)

    @sync begin
        jobs = Channel{eltype(pkgs_to_install)}(ctx.num_concurrent_downloads)
        results = Channel(ctx.num_concurrent_downloads)

        @async begin
            for pkg in pkgs_to_install
                put!(jobs, pkg)
            end
        end

        for i in 1:ctx.num_concurrent_downloads
            @async begin
                for (pkg, urls, path) in jobs
                    if ctx.use_git_for_all_downloads
                        put!(results, (pkg, false, (urls, path)))
                        continue
                    end
                    try
                        archive_urls = Pair{String,Bool}[]
                        if (server = pkg_server()) !== nothing
                            url = "$server/package/$(pkg.uuid)/$(pkg.tree_hash)"
                            push!(archive_urls, url => true)
                        end
                        for repo_url in urls
                            url = get_archive_url_for_version(repo_url, pkg.tree_hash)
                            url !== nothing && push!(archive_urls, url => false)
                        end
                        success = install_archive(archive_urls, pkg.tree_hash, path, io=ctx.io)
                        if success && readonly
                            set_readonly(path) # In add mode, files should be read-only
                        end
                        if ctx.use_only_tarballs_for_downloads && !success
                            pkgerror("failed to get tarball from $(urls)")
                        end
                        put!(results, (pkg, success, (urls, path)))
                    catch err
                        put!(results, (pkg, err, catch_backtrace()))
                    end
                end
            end
        end

        bar = MiniProgressBar(; indent=2, header = "Progress", color = Base.info_color(),
                                  percentage=false, always_reprint=true)
        bar.max = length(pkgs_to_install)
        fancyprint = can_fancyprint(ctx.io)
        try
            for i in 1:length(pkgs_to_install)
                pkg::PackageEntry, exc_or_success, bt_or_pathurls = take!(results)
                exc_or_success isa Exception && pkgerror("Error when installing package $(pkg.name):\n",
                                                        sprint(Base.showerror, exc_or_success, bt_or_pathurls))
                success, (urls, path) = exc_or_success, bt_or_pathurls
                success || push!(missed_packages, (; pkg, urls, path))
                bar.current = i
                str = sprint(; context=ctx.io) do io
                    if success
                        fancyprint && print_progress_bottom(io)
                        vstr = pkg.version !== nothing ? "v$(pkg.version)" : "[$h]"
                        printpkgstyle(io, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
                        fancyprint && show_progress(io, bar)
                    end
                end
                print(ctx.io, str)
            end
        finally
            fancyprint && end_progress(ctx.io, bar)
            close(jobs)
        end
    end

    ##################################################
    # Use LibGit2 to download any remaining packages #
    ##################################################
    for (pkg, urls, path) in missed_packages
        uuid = pkg.uuid
        install_git(ctx.io, pkg.uuid, pkg.name, pkg.tree_hash, urls, path)
        readonly && set_readonly(path)
        vstr = pkg.version !== nothing ? "v$(pkg.version)" : "[$h]"
        printpkgstyle(ctx.io, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
    end

    return Set{UUID}(entry.pkg.uuid for entry in pkgs_to_install)
end

################################
# Manifest update and pruning #
################################
project_rel_path(env::EnvCache, path::String) = normpath(joinpath(dirname(env.project_file), path))

function prune_manifest(env::EnvCache)
    keep = collect(values(env.project.deps))
    env.manifest = prune_manifest(env.manifest, keep)
end

function prune_manifest(manifest::Manifest, keep::Vector{UUID})
    while !isempty(keep)
        clean = true
        for (uuid, entry) in manifest.deps
            uuid in keep || continue
            for dep in values(entry.deps)
                dep in keep && continue
                push!(keep, dep)
                clean = false
            end
        end
        clean && break
    end
    new_manifest = deepcopy(manifest)
    new_manifest.deps = Dict(uuid => entry for (uuid, entry) in manifest.deps if uuid in keep)
    return new_manifest
end


#########
# Build #
#########
get_deps(env::EnvCache, new_uuids::Set{UUID}) = _get_deps!(Set{UUID}(), env, new_uuids)
function _get_deps!(collected_uuids::Set{UUID}, env::EnvCache, new_uuids)
    for uuid in new_uuids
        is_stdlib(uuid) && continue
        uuid in collected_uuids && continue
        push!(collected_uuids, uuid)
        children_uuids = if Types.is_project_uuid(env, uuid)
            Set(values(env.project.deps))
        else
            info = manifest_info(env.manifest, uuid)
            if info === nothing
                pkgerror("could not find manifest entry for package with uuid $(uuid)")
            end
            Set(values(info.deps))
        end
        _get_deps!(collected_uuids, env, children_uuids)
    end
    return collected_uuids
end

# TODO: This function should be replacable with `is_instantiated` but
# see https://github.com/JuliaLang/Pkg.jl/issues/2470
function any_package_not_installed(manifest::Manifest)
    for (uuid, entry) in manifest.deps
        if Base.locate_package(Base.PkgId(uuid, entry.name)) === nothing
            return true
        end
    end
    return false
end

function build(ctx::Context, uuids::Set{UUID}, verbose::Bool)
    if any_package_not_installed(ctx.env.manifest) || !isfile(ctx.env.manifest_file)
        Pkg.instantiate(ctx)
    end
    all_uuids = get_deps(ctx.env, uuids)
    build_versions(ctx, all_uuids; verbose)
end

function dependency_order_uuids(env::EnvCache, uuids::Vector{UUID})::Dict{UUID,Int}
    order = Dict{UUID,Int}()
    seen = UUID[]
    k = 0
    function visit(uuid::UUID)
        uuid in seen &&
            return @warn("Dependency graph not a DAG, linearizing anyway")
        haskey(order, uuid) && return
        push!(seen, uuid)
        if Types.is_project_uuid(env, uuid)
            deps = values(env.project.deps)
        else
            entry = manifest_info(env.manifest, uuid)
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

const PkgUUID = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
pkg_scratchpath() = joinpath(depots1(), "scratchspaces", PkgUUID)

builddir(source_path::String) = joinpath(source_path, "deps")
buildfile(source_path::String) = joinpath(builddir(source_path), "build.jl")
function build_versions(ctx::Context, uuids::Set{UUID}; verbose=false)
    # collect builds for UUIDs with `deps/build.jl` files
    builds = Tuple{UUID,String,String,VersionNumber}[]
    for uuid in uuids
        is_stdlib(uuid) && continue
        if Types.is_project_uuid(ctx.env, uuid)
            path = dirname(ctx.env.project_file)
            name = ctx.env.pkg.name
            version = ctx.env.pkg.version
        else
            entry = manifest_info(ctx.env.manifest, uuid)
            if entry === nothing
                error("could not find entry with uuid $uuid in manifest $(ctx.env.manifest_file)")
            end
            name = entry.name
            if entry.tree_hash !== nothing
                path = find_installed(name, uuid, entry.tree_hash)
            elseif entry.path !== nothing
                path = project_rel_path(ctx.env, entry.path)
            else
                pkgerror("Could not find either `git-tree-sha1` or `path` for package $name")
            end
            version = something(entry.version, v"0.0")
        end
        ispath(path) || error("Build path for $name does not exist: $path")
        ispath(buildfile(path)) && push!(builds, (uuid, name, path, version))
    end
    # toposort builds by dependencies
    order = dependency_order_uuids(ctx.env, map(first, builds))
    sort!(builds, by = build -> order[first(build)])
    max_name = maximum(build->textwidth(build[2]), builds; init=0)

    bar = MiniProgressBar(; indent=2, header = "Progress", color = Base.info_color(),
                              percentage=false, always_reprint=true)
    bar.max = length(builds)
    fancyprint = can_fancyprint(ctx.io)
    fancyprint && start_progress(ctx.io, bar)

    # build each package versions in a child process
    try
    for (n, (uuid, name, source_path, version)) in enumerate(builds)
        pkg = PackageSpec(;uuid=uuid, name=name, version=version)
        build_file = buildfile(source_path)
        # compatibility shim
        build_project_override = isfile(projectfile_path(builddir(source_path))) ?
            nothing :
            gen_target_project(ctx.env, ctx.registries, pkg, source_path, "build")

        # Put log output in Pkg's scratchspace if the package is content adressed
        # by tree sha and in the build directory if it is tracked by path etc.
        entry = manifest_info(ctx.env.manifest, uuid)
        if entry !== nothing && entry.tree_hash !== nothing
            key = string(entry.tree_hash)
            scratch = joinpath(pkg_scratchpath(), key)
            mkpath(scratch)
            log_file = joinpath(scratch, "build.log")
            # Associate the logfile with the package beeing built
            dict = Dict{String,Any}(scratch => [
                Dict{String,Any}("time" => Dates.now(), "parent_projects" => [projectfile_path(source_path)])
            ])
            open(joinpath(depots1(), "logs", "scratch_usage.toml"), "a") do io
                TOML.print(io, dict)
            end
        else
            log_file = splitext(build_file)[1] * ".log"
        end

        fancyprint && print_progress_bottom(ctx.io)

        printpkgstyle(ctx.io, :Building,
                      rpad(name * " ", max_name + 1, "─") * "→ " * pathrepr(log_file))
        bar.current = n-1

        fancyprint && show_progress(ctx.io, bar)

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
            pkgerror("Error building `$(pkg.name)`$last_lines: \n$log_show$full_log_at")
        end
    end
    finally
        fancyprint && end_progress(ctx.io, bar)
    end
    return
end

##############
# Operations #
##############
function rm(ctx::Context, pkgs::Vector{PackageSpec}; mode::PackageMode)
    drop = UUID[]
    # find manifest-mode drops
    if mode == PKGMODE_MANIFEST
        for pkg in pkgs
            info = manifest_info(ctx.env.manifest, pkg.uuid)
            if info !== nothing
                pkg.uuid in drop || push!(drop, pkg.uuid)
            else
                str = has_name(pkg) ? pkg.name : string(pkg.uuid)
                @warn("`$str` not in manifest, ignoring")
            end
        end
    end
    # drop reverse dependencies
    while !isempty(drop)
        clean = true
        for (uuid, entry) in ctx.env.manifest.deps
            deps = values(entry.deps)
            isempty(drop ∩ deps) && continue
            uuid ∉ drop || continue
            push!(drop, uuid)
            clean = false
        end
        clean && break
    end
    # find project-mode drops
    if mode == PKGMODE_PROJECT
        for pkg in pkgs
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
    # only declare `compat` for remaining direct or `extra` dependencies
    # `julia` is always an implicit direct dependency
    filter!(ctx.env.project.compat) do (name, _)
        name == "julia" || name in keys(ctx.env.project.deps) || name in keys(ctx.env.project.extras)
    end
    deps_names = union(keys(ctx.env.project.deps), keys(ctx.env.project.extras))
    filter!(ctx.env.project.targets) do (target, deps)
        !isempty(filter!(in(deps_names), deps))
    end
    # only keep reachable manifest entires
    prune_manifest(ctx.env)
    # update project & manifest
    write_env(ctx.env)
    show_update(ctx.env; io=ctx.io)
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

function is_all_registered(registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec})
    pkgs = filter(tracking_registered_version, pkgs)
    for pkg in pkgs
        if !any(r->haskey(r, pkg.uuid), registries)
            return pkg
        end
    end
    return true
end

function check_registered(registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec})
    pkg = is_all_registered(registries, pkgs)
    if pkg isa PackageSpec
        pkgerror("expected package $(err_rep(pkg)) to be registered")
    end
    return nothing
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
        haskey(ctx.env.manifest.deps, pkg.uuid) && (ctx.env.manifest.deps[pkg.uuid].name != pkg.name) &&
            pkgerror("refusing to add package $(err_rep(pkg)):",
                     " package `$(ctx.env.manifest.deps[pkg.uuid].name) = \"$(pkg.uuid)\"` ",
                     "already exists in the manifest")
    end
end

function tiered_resolve(env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, julia_version)
    try # do not modify existing subgraph
        return targeted_resolve(env, registries, pkgs, PRESERVE_ALL, julia_version)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try # do not modify existing direct deps
        return targeted_resolve(env, registries, pkgs, PRESERVE_DIRECT, julia_version)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try
        return targeted_resolve(env, registries, pkgs, PRESERVE_SEMVER, julia_version)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    return targeted_resolve(env, registries, pkgs, PRESERVE_NONE, julia_version)
end

function targeted_resolve(env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, preserve::PreserveLevel, julia_version)
    if preserve == PRESERVE_ALL
        pkgs = load_all_deps(env, pkgs)
    elseif preserve == PRESERVE_DIRECT
        pkgs = load_direct_deps(env, pkgs)
    elseif preserve == PRESERVE_SEMVER
        pkgs = load_direct_deps(env, pkgs; preserve=preserve)
    elseif preserve == PRESERVE_NONE
        pkgs = load_direct_deps(env, pkgs; preserve=preserve)
    end
    check_registered(registries, pkgs)

    deps_map = resolve_versions!(env, registries, pkgs, julia_version)
    return pkgs, deps_map
end

function _resolve(io::IO, env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, preserve::PreserveLevel, julia_version)
    printpkgstyle(io, :Resolving, "package versions...")
    return preserve == PRESERVE_TIERED ?
        tiered_resolve(env, registries, pkgs, julia_version) :
        targeted_resolve(env, registries, pkgs, preserve, julia_version)
end

function add(ctx::Context, pkgs::Vector{PackageSpec}, new_git=Set{UUID}();
             preserve::PreserveLevel=PRESERVE_TIERED, platform::AbstractPlatform=HostPlatform())
    assert_can_add(ctx, pkgs)
    # load manifest data
    for (i, pkg) in pairs(pkgs)
        entry = manifest_info(ctx.env.manifest, pkg.uuid)
        is_dep = any(uuid -> uuid == pkg.uuid, [uuid for (name, uuid) in ctx.env.project.deps])
        pkgs[i] = update_package_add(ctx, pkg, entry, is_dep)
    end
    foreach(pkg -> ctx.env.project.deps[pkg.name] = pkg.uuid, pkgs) # update set of deps
    # resolve
    pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, preserve, ctx.julia_version)
    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version)
    new_apply = download_source(ctx)

    # After downloading resolutionary packages, search for (Julia)Artifacts.toml files
    # and ensure they are all downloaded and unpacked as well:
    download_artifacts(ctx.env, platform=platform, julia_version=ctx.julia_version, io=ctx.io)

    write_env(ctx.env) # write env before building
    show_update(ctx.env; io=ctx.io)
    build_versions(ctx, union(new_apply, new_git))
end

# Input: name, uuid, and path
function develop(ctx::Context, pkgs::Vector{PackageSpec}, new_git::Set{UUID};
                 preserve::PreserveLevel=PRESERVE_TIERED, platform::AbstractPlatform=HostPlatform())
    assert_can_add(ctx, pkgs)
    # no need to look at manifest.. dev will just nuke whatever is there before
    for pkg in pkgs
        ctx.env.project.deps[pkg.name] = pkg.uuid
    end
    # resolve & apply package versions
    pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, preserve, ctx.julia_version)
    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version)
    new_apply = download_source(ctx)
    download_artifacts(ctx.env; platform=platform, julia_version=ctx.julia_version, io=ctx.io)
    write_env(ctx.env) # write env before building
    show_update(ctx.env; io=ctx.io)
    build_versions(ctx, union(new_apply, new_git))
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
    new_git = Set{UUID}()
    # TODO check all pkg.version == VersionSpec()
    # set version constraints according to `level`
    for pkg in pkgs
        new = up_load_versions!(ctx, pkg, manifest_info(ctx.env.manifest, pkg.uuid), level)
        new && push!(new_git, pkg.uuid) #TODO put download + push! in utility function
    end
    # load rest of manifest data (except for version info)
    for pkg in pkgs
        up_load_manifest_info!(pkg, manifest_info(ctx.env.manifest, pkg.uuid))
    end
    pkgs = load_direct_deps(ctx.env, pkgs; preserve = (level == UPLEVEL_FIXED ? PRESERVE_NONE : PRESERVE_DIRECT))
    check_registered(ctx.registries, pkgs)
    deps_map = resolve_versions!(ctx.env, ctx.registries, pkgs, ctx.julia_version)
    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version)
    new_apply = download_source(ctx)
    download_artifacts(ctx.env, julia_version=ctx.julia_version, io=ctx.io)
    write_env(ctx.env) # write env before building
    show_update(ctx.env; io=ctx.io)
    build_versions(ctx, union(new_apply, new_git))
end

function update_package_pin!(registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec, entry::Union{Nothing, PackageEntry})
    if entry === nothing
        pkgerror("package $(err_rep(pkg)) not found in the manifest, run `Pkg.resolve()` and retry.")
    end

    #if entry.pinned && pkg.version == VersionSpec()
    #    println(ctx.io, "package $(err_rep(pkg)) already pinned")
    #end
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
            if is_all_registered(registries, [pkg]) !== true
                pkgerror("unable to pin unregistered package $(err_rep(pkg)) to an arbritrary version")
            end
        end
    end
end

function pin(ctx::Context, pkgs::Vector{PackageSpec})
    foreach(pkg -> update_package_pin!(ctx.registries, pkg, manifest_info(ctx.env.manifest, pkg.uuid)), pkgs)
    pkgs = load_direct_deps(ctx.env, pkgs)

    pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, PRESERVE_TIERED, ctx.julia_version)
    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version)

    new = download_source(ctx)
    download_artifacts(ctx.env; julia_version=ctx.julia_version, io=ctx.io)
    write_env(ctx.env) # write env before building
    show_update(ctx.env; io=ctx.io)
    build_versions(ctx, new)
end

function update_package_free!(registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec, entry::PackageEntry)
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
        if is_all_registered(registries, [pkg]) !== true
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
    foreach(pkg -> update_package_free!(ctx.registries, pkg, manifest_info(ctx.env.manifest, pkg.uuid)), pkgs)

    if any(pkg -> pkg.version == VersionSpec(), pkgs)
        pkgs = load_direct_deps(ctx.env, pkgs)
        check_registered(ctx.registries, pkgs)
        pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, PRESERVE_TIERED, ctx.julia_version)

        update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version)
        new = download_source(ctx)
        download_artifacts(ctx.env, io=ctx.io)
        write_env(ctx.env) # write env before building
        show_update(ctx.env; io=ctx.io)
        build_versions(ctx, new)
    else
        foreach(pkg -> manifest_info(ctx.env.manifest, pkg.uuid).pinned = false, pkgs)
        write_env(ctx.env)
        show_update(ctx.env; io=ctx.io)
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
        --color=$(Base.have_color === nothing ? "auto" : Base.have_color ? "yes" : "no")
        --compiled-modules=$(Bool(Base.JLOptions().use_compiled_modules) ? "yes" : "no")
        --check-bounds=yes
        --depwarn=$(Base.JLOptions().depwarn == 2 ? "error" : "yes")
        --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --track-allocation=$(("none", "user", "all")[Base.JLOptions().malloc_log + 1])
        --threads=$(Threads.nthreads())
        $(julia_args)
        --eval $(code)
    ```
end

function with_temp_env(fn::Function, temp_env::String)
    load_path = copy(LOAD_PATH)
    active_project = Base.ACTIVE_PROJECT[]
    try
        push!(empty!(LOAD_PATH), "@", temp_env)
        Base.ACTIVE_PROJECT[] = nothing
        fn()
    finally
        append!(empty!(LOAD_PATH), load_path)
        Base.ACTIVE_PROJECT[] = active_project
    end
end

# pick out a set of subgraphs and preserve their versions
function sandbox_preserve(env::EnvCache, target::PackageSpec, test_project::String)
    env = deepcopy(env)
    # include root in manifest (in case any dependencies point back to it)
    if env.pkg !== nothing
        env.manifest.deps[env.pkg.uuid] = PackageEntry(;name=env.pkg.name, path=dirname(env.project_file),
                                                  deps=env.project.deps)
    end
    # preserve important nodes
    keep = [target.uuid]
    append!(keep, collect(values(read_project(test_project).deps)))
    # prune and return
    return prune_manifest(env.manifest, keep)
end

function abspath!(env::EnvCache, manifest::Manifest)
    for (uuid, entry) in manifest.deps
        if entry.path !== nothing
            entry.path = project_rel_path(env, entry.path)
        end
    end
    return manifest
end

# ctx + pkg used to compute parent dep graph
function sandbox(fn::Function, ctx::Context, target::PackageSpec, target_path::String,
                 sandbox_path::String, sandbox_project_override;
                 force_latest_compatible_version::Bool=false,
                 allow_earlier_backwards_compatible_versions::Bool=true,
                 allow_reresolve::Bool=true)
    active_manifest = manifestfile_path(dirname(ctx.env.project_file))
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
        working_manifest = abspath!(ctx.env, sandbox_preserve(ctx.env, target, tmp_project))
        # - copy over fixed subgraphs from test subgraph
        # really only need to copy over "special" nodes
        sandbox_env = Types.EnvCache(projectfile_path(sandbox_path))
        sandbox_manifest = abspath!(sandbox_env, sandbox_env.manifest)
        for (name, uuid) in sandbox_env.project.deps
            entry = get(sandbox_manifest.deps, uuid, nothing)
            if entry !== nothing && isfixed(entry)
                subgraph = prune_manifest(sandbox_manifest, [uuid])
                for (uuid, entry) in subgraph.deps
                    if haskey(working_manifest.deps, uuid)
                        pkgerror("can not merge projects")
                    end
                    working_manifest.deps[uuid] = entry
                end
            end
        end

        Types.write_manifest(working_manifest, tmp_manifest)
        # sandbox
        with_temp_env(tmp) do
            temp_ctx = Context()
            temp_ctx.env.project.deps[target.name] = target.uuid
            try
                Pkg.resolve(temp_ctx; io=devnull)
                @debug "Using _parent_ dep graph"
            catch err# TODO
                err isa Resolve.ResolverError || rethrow()
                allow_reresolve || rethrow()
                @debug err
                @warn "Could not use exact versions of packages in manifest, re-resolving"
                temp_ctx.env.manifest.deps = Dict(uuid => entry for (uuid, entry) in temp_ctx.env.manifest.deps if isfixed(entry))
                Pkg.resolve(temp_ctx; io=devnull)
                @debug "Using _clean_ dep graph"
            end

            # Absolutify stdlibs paths
            for (uuid, entry) in temp_ctx.env.manifest.deps
                if is_stdlib(uuid)
                    entry.path = Types.stdlib_path(entry.name)
                end
            end
            write_env(temp_ctx.env, update_undo = false)

            if force_latest_compatible_version
                result = check_force_latest_compatible_version(
                    temp_ctx;
                    target_name = target.name,
                    allow_earlier_backwards_compatible_versions,
                )
                if !result
                    pkgerror("One or more direct dependencies is not at the latest compatible version")
                end
            end

            # Run sandboxed code
            path_sep = Sys.iswindows() ? ';' : ':'
            withenv(fn, "JULIA_LOAD_PATH" => "@$(path_sep)$(tmp)", "JULIA_PROJECT" => nothing)
        end
    end
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
function gen_target_project(env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec, source_path::String, target::String)
    test_project = Types.Project()
    if projectfile_path(source_path; strict=true) === nothing
        # no project file, assuming this is an old REQUIRE package
        test_project.deps = copy(env.manifest.deps[pkg.uuid].deps)
        if target == "test"
            test_REQUIRE_path = joinpath(source_path, "test", "REQUIRE")
            if isfile(test_REQUIRE_path)
                @warn "using test/REQUIRE files is deprecated and current support is lacking in some areas"
                test_pkgs = parse_REQUIRE(test_REQUIRE_path)
                package_specs = [PackageSpec(name=pkg) for pkg in test_pkgs]
                registry_resolve!(registries, package_specs)
                stdlib_resolve!(package_specs)
                ensure_resolved(env.manifest, package_specs, registry=true)
                for spec in package_specs
                    test_project.deps[spec.name] = spec.uuid
                end
            end
        end
        return test_project
    end
    # collect relevant info from source
    source_env = EnvCache(projectfile_path(source_path))
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
        compat = get_compat_str(source_env.project, name)
        compat === nothing && continue
        set_compat(test_project, name, compat)
    end
    return test_project
end

testdir(source_path::String) = joinpath(source_path, "test")
testfile(source_path::String) = joinpath(testdir(source_path), "runtests.jl")
function test(ctx::Context, pkgs::Vector{PackageSpec};
              coverage=false, julia_args::Cmd=``, test_args::Cmd=``,
              test_fn=nothing,
              force_latest_compatible_version::Bool=false,
              allow_earlier_backwards_compatible_versions::Bool=true,
              allow_reresolve::Bool=true)
    Pkg.instantiate(ctx; allow_autoprecomp = false) # do precomp later within sandbox

    # load manifest data
    for pkg in pkgs
        is_stdlib(pkg.uuid) && continue
        if Types.is_project_uuid(ctx.env, pkg.uuid)
            pkg.path = dirname(ctx.env.project_file)
            pkg.version = ctx.env.pkg.version
        else
            entry = manifest_info(ctx.env.manifest, pkg.uuid)
            pkg.version = entry.version
            pkg.tree_hash = entry.tree_hash
            pkg.repo = entry.repo
            pkg.path = entry.path
            pkg.pinned = entry.pinned
        end
    end

    # See if we can find the test files for all packages
    missing_runtests = String[]
    source_paths     = String[]
    for pkg in pkgs
        sourcepath = project_rel_path(ctx.env, source_path(ctx.env.project_file, pkg, ctx.julia_version)) # TODO
        !isfile(testfile(sourcepath)) && push!(missing_runtests, pkg.name)
        push!(source_paths, sourcepath)
    end
    if !isempty(missing_runtests)
        pkgerror(length(missing_runtests) == 1 ? "Package " : "Packages ",
                join(missing_runtests, ", "),
                " did not provide a `test/runtests.jl` file")
    end

    # sandbox
    pkgs_errored = Tuple{String, Base.Process}[]
    for (pkg, source_path) in zip(pkgs, source_paths)
        # compatibility shim between "targets" and "test/Project.toml"
        test_project_override = isfile(projectfile_path(testdir(source_path))) ?
            nothing :
            gen_target_project(ctx.env, ctx.registries, pkg, source_path, "test")
        # now we sandbox
        printpkgstyle(ctx.io, :Testing, pkg.name)
        sandbox(ctx, pkg, source_path, testdir(source_path), test_project_override; force_latest_compatible_version, allow_earlier_backwards_compatible_versions, allow_reresolve) do
            test_fn !== nothing && test_fn()
            sandbox_ctx = Context(;io=ctx.io)
            status(sandbox_ctx.env; mode=PKGMODE_COMBINED, io=sandbox_ctx.io)
            Pkg._auto_precompile(sandbox_ctx)
            printpkgstyle(ctx.io, :Testing, "Running tests...")
            flush(stdout)
            cmd = gen_test_code(testfile(source_path); coverage=coverage, julia_args=julia_args, test_args=test_args)
            p = run(ignorestatus(cmd))
            if success(p)
                printpkgstyle(ctx.io, :Testing, pkg.name * " tests passed ")
            else
                push!(pkgs_errored, (pkg.name, p))
            end
        end
    end

    # TODO: Should be included in Base
    function signal_name(signal::Integer)
        if signal == Base.SIGHUP
            "HUP"
        elseif signal == Base.SIGINT
            "INT"
        elseif signal == Base.SIGQUIT
            "QUIT"
        elseif signal == Base.SIGKILL
            "KILL"
        elseif signal == Base.SIGPIPE
            "PIPE"
        elseif signal == Base.SIGTERM
            "TERM"
        else
            string(signal)
        end
    end

    # report errors
    if !isempty(pkgs_errored)
        function reason(p)
            if Base.process_signaled(p)
                " (received signal: " * signal_name(p.termsignal) * ")"
            elseif Base.process_exited(p) && p.exitcode != 1
                " (exit code: " * string(p.exitcode) * ")"
            else
                ""
            end
        end

        if length(pkgs_errored) == 1
            pkg_name, p = first(pkgs_errored)
            pkgerror("Package $pkg_name errored during testing$(reason(p))")
        else
            failures = ["• $pkg_name$(reason(p))" for (pkg_name, p) in pkgs_errored]
            pkgerror("Packages errored during testing:\n", join(failures, "\n"))
        end
    end
end



# Display

function stat_rep(x::PackageSpec; name=true)
    name = name ? "$(x.name)" : ""
    version = x.version == VersionSpec() ? "" : "v$(x.version)"
    rev = ""
    if x.repo.rev !== nothing
        rev = occursin(r"\b([a-f0-9]{40})\b", x.repo.rev) ? x.repo.rev[1:7] : x.repo.rev
    end
    subdir_str = x.repo.subdir === nothing ? "" : ":$(x.repo.subdir)"
    repo = Operations.is_tracking_repo(x) ? "`$(x.repo.source)$(subdir_str)#$(rev)`" : ""
    path = Operations.is_tracking_path(x) ? "$(pathrepr(x.path))" : ""
    pinned = x.pinned ? "⚲" : ""
    return join(filter(!isempty, [name,version,repo,path,pinned]), " ")
end

print_single(io::IO, pkg::PackageSpec) = print(io, stat_rep(pkg))

is_instantiated(::Nothing) = false
is_instantiated(x::PackageSpec) = x.version != VersionSpec() || is_stdlib(x.uuid)
# Compare an old and new node of the dependency graph and print a single line to summarize the change
function print_diff(io::IO, old::Union{Nothing,PackageSpec}, new::Union{Nothing,PackageSpec})
    if !is_instantiated(old) && is_instantiated(new)
        printstyled(io, "+ $(stat_rep(new))"; color=:light_green)
    elseif !is_instantiated(new)
        printstyled(io, "- $(stat_rep(old))"; color=:light_red)
    elseif is_tracking_registry(old) && is_tracking_registry(new) &&
           new.version isa VersionNumber && old.version isa VersionNumber && new.version != old.version
        if new.version > old.version
            printstyled(io, "↑ $(stat_rep(old)) ⇒ $(stat_rep(new; name=false))"; color=:light_yellow)
        else
            printstyled(io, "↓ $(stat_rep(old)) ⇒ $(stat_rep(new; name=false))"; color=:light_magenta)
        end
    else
        printstyled(io, "~ $(stat_rep(old)) ⇒ $(stat_rep(new; name=false))"; color=:light_yellow)
    end
end

function diff_array(old_env::Union{EnvCache,Nothing}, new_env::EnvCache; manifest=true)
    function index_pkgs(pkgs, uuid)
        idx = findfirst(pkg -> pkg.uuid == uuid, pkgs)
        return idx === nothing ? nothing : pkgs[idx]
    end
    # load deps
    new = manifest ? load_manifest_deps(new_env.manifest) : load_direct_deps(new_env)
    T, S = Union{UUID,Nothing}, Union{PackageSpec,Nothing}
    if old_env === nothing
        return Tuple{T,S,S}[(pkg.uuid, nothing, pkg)::Tuple{T,S,S} for pkg in new]
    end
    old = manifest ? load_manifest_deps(old_env.manifest) : load_direct_deps(old_env)
    # merge old and new into single array
    all_uuids = union(T[pkg.uuid for pkg in old], T[pkg.uuid for pkg in new])
    return Tuple{T,S,S}[(uuid, index_pkgs(old, uuid), index_pkgs(new, uuid))::Tuple{T,S,S} for uuid in all_uuids]
end

function is_package_downloaded(project_file::String, pkg::PackageSpec)
    sourcepath = source_path(project_file, pkg)
    @assert sourcepath !== nothing
    isdir(sourcepath) || return false
    check_artifacts_downloaded(sourcepath) || return false
    return true
end

function print_status(env::EnvCache, old_env::Union{Nothing,EnvCache}, header::Symbol,
                      uuids::Vector, names::Vector; manifest=true, diff=false, ignore_indent=false, io)
    not_installed_indicator = sprint((io, args) -> printstyled(io, args...; color=:red), "→", context=io)
    filter = !isempty(uuids) || !isempty(names)
    # setup
    xs = diff_array(old_env, env; manifest=manifest)
    # filter and return early if possible
    if isempty(xs) && !diff
        printpkgstyle(io, header, "$(pathrepr(manifest ? env.manifest_file : env.project_file)) (empty " *
                      (manifest ? "manifest" : "project") * ")", ignore_indent)
        return nothing
    end
    xs = !diff ? xs : eltype(xs)[(id, old, new) for (id, old, new) in xs if old != new]
    if isempty(xs)
        printpkgstyle(io, Symbol("No Changes"), "to $(pathrepr(manifest ? env.manifest_file : env.project_file))", ignore_indent)
        return nothing
    end
    xs = !filter ? xs : eltype(xs)[(id, old, new) for (id, old, new) in xs if (id in uuids || something(new, old).name in names)]
    if isempty(xs)
        printpkgstyle(io, Symbol("No Matches"),
                      "in $(diff ? "diff for " : "")$(pathrepr(manifest ? env.manifest_file : env.project_file))", ignore_indent)
        return nothing
    end
    # main print
    printpkgstyle(io, header, pathrepr(manifest ? env.manifest_file : env.project_file), ignore_indent)
    # Sort stdlibs and _jlls towards the end in status output
    xs = sort!(xs, by = (x -> (is_stdlib(x[1]), endswith(something(x[3], x[2]).name, "_jll"), something(x[3], x[2]).name, x[1])))
    all_packages_downloaded = true
    for (uuid, old, new) in xs
        if Types.is_project_uuid(env, uuid)
            continue
        end
        pkg_downloaded = !is_instantiated(new) || is_package_downloaded(env.project_file, new)
        all_packages_downloaded &= pkg_downloaded
        print(io, pkg_downloaded ? " " : not_installed_indicator)
        printstyled(io, " [", string(uuid)[1:8], "] "; color = :light_black)
        diff ? print_diff(io, old, new) : print_single(io, new)
        println(io)
    end
    if !all_packages_downloaded
        printpkgstyle(io, :Info, "packages marked with $not_installed_indicator not downloaded, use `instantiate` to download", ignore_indent)
    end
    return nothing
end

function git_head_env(env, project_dir)
    new_env = EnvCache()
    try
        LibGit2.with(LibGit2.GitRepo(project_dir)) do repo
            git_path = LibGit2.path(repo)
            project_path = relpath(env.project_file, git_path)
            manifest_path = relpath(env.manifest_file, git_path)
            new_env.project = read_project(GitTools.git_file_stream(repo, "HEAD:$project_path", fakeit=true))
            new_env.manifest = read_manifest(GitTools.git_file_stream(repo, "HEAD:$manifest_path", fakeit=true))
            return new_env
        end
    catch err
        err isa PkgError || rethrow(err)
        return nothing
    end
end

function show_update(env::EnvCache; ignore_indent=false, io::IO)
    old_env = EnvCache()
    old_env.project = env.original_project
    old_env.manifest = env.original_manifest
    status(env; header=:Updating, mode=PKGMODE_COMBINED, env_diff=old_env, ignore_indent=ignore_indent, io=io)
    return nothing
end

function status(env::EnvCache, pkgs::Vector{PackageSpec}=PackageSpec[];
                header=nothing, mode::PackageMode=PKGMODE_PROJECT, git_diff::Bool=false, env_diff=nothing, ignore_indent=false, io::IO)
    io == Base.devnull && return
    # if a package, print header
    if header === nothing && env.pkg !== nothing
       printpkgstyle(io, :Project, string(env.pkg.name, " v", env.pkg.version); color=Base.info_color())
    end
    # load old env
    old_env = nothing
    if git_diff
        project_dir = dirname(env.project_file)
        if !ispath(joinpath(project_dir, ".git"))
            @warn "diff option only available for environments in git repositories, ignoring."
        else
            old_env = git_head_env(env, project_dir)
            if old_env === nothing
                @warn "could not read project from HEAD, displaying absolute status instead."
            end
        end
    elseif env_diff !== nothing
        old_env = env_diff
    end
    # display
    filter_uuids = [pkg.uuid::UUID for pkg in pkgs if pkg.uuid !== nothing]
    filter_names = [pkg.name::String for pkg in pkgs if pkg.name !== nothing]
    diff = old_env !== nothing
    header = something(header, diff ? :Diff : :Status)
    if mode == PKGMODE_PROJECT || mode == PKGMODE_COMBINED
        print_status(env, old_env, header, filter_uuids, filter_names; manifest=false, diff=diff, ignore_indent=ignore_indent, io=io)
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        print_status(env, old_env, header, filter_uuids, filter_names; diff=diff, ignore_indent=ignore_indent, io=io)
    end
end

function check_force_latest_compatible_version(ctx::Types.Context;
                                               target_name = nothing,
                                               allow_earlier_backwards_compatible_versions::Bool = true)
    direct_deps = load_direct_deps(ctx.env)
    direct_deps_uuids = [dep.uuid for dep in direct_deps]
    uuid_list = filter(!is_stdlib, direct_deps_uuids)
    isempty(uuid_list) && return true
    results = check_force_latest_compatible_version.(
        Ref(ctx),
        uuid_list;
        target_name,
        allow_earlier_backwards_compatible_versions,
    )
    return all(results)
end

function check_force_latest_compatible_version(ctx::Types.Context,
                                               uuid::Base.UUID;
                                               target_name= nothing,
                                               allow_earlier_backwards_compatible_versions::Bool = true)
    dep = ctx.env.manifest.deps[uuid]
    name = dep.name
    active_version = dep.version
    has_compat = haskey(ctx.env.project.compat, name)
    if !has_compat
        if name != target_name
            @warn(
                "Package does not have a [compat] entry",
                name, uuid, active_version, target_name,
            )
        end
        return true
    end
    compat_entry = ctx.env.project.compat[name].val
    latest_compatible_version = get_latest_compatible_version(
        ctx,
        uuid,
        compat_entry,
    )
    earliest_backwards_compatible_version = get_earliest_backwards_compatible_version(latest_compatible_version)
    if allow_earlier_backwards_compatible_versions
        result = active_version >= earliest_backwards_compatible_version
    else
        result = active_version >= latest_compatible_version
    end
    if !result
        @error(
            "Package is not at the latest compatible version",
            name,
            uuid,
            compat_entry,
            active_version,
            latest_compatible_version,
            earliest_backwards_compatible_version,
            allow_earlier_backwards_compatible_versions,
        )
    end
    return result
end

function get_earliest_backwards_compatible_version(ver::Base.VersionNumber)
    (ver.major > 0) && return Base.VersionNumber(ver.major, 0, 0)
    (ver.minor > 0) && return Base.VersionNumber(0, ver.minor, 0)
    return Base.VersionNumber(0, 0, ver.patch)
end

function get_latest_compatible_version(ctx::Types.Context,
                                       uuid::Base.UUID,
                                       compat_spec::VersionSpec)
    all_registered_versions = get_all_registered_versions(ctx, uuid)
    compatible_versions = filter(in(compat_spec), all_registered_versions)
    latest_compatible_version = maximum(compatible_versions)
    return latest_compatible_version
end

function get_all_registered_versions(ctx::Types.Context,
                                     uuid::Base.UUID)
    versions = Set{VersionNumber}()
    for reg in ctx.registries
        pkg = get(reg, uuid, nothing)
        if pkg !== nothing
            info = Registry.registry_info(pkg)
            union!(versions, keys(info.version_info))
        end
    end
    return versions
end

function warn_if_manifest_has_different_julia_version(io::IO, man::Manifest)
    if man.julia_version != Base.VERSION
        printpkgstyle(io, :Warning,
            "The manifest was generated using Julia $(repr(man.julia_version)). The current Julia version is $(repr(Base.VERSION))",
            color = Base.warn_color())
    end
end
warn_if_manifest_has_different_julia_version(ctx::Types.Context) =
    warn_if_manifest_has_different_julia_version(ctx.io, ctx.env.manifest)

function check_manifest_originated_from_current_project(env::EnvCache)
    if isnothing(env.manifest.project_hash)
        # if there's no project hash, the manifest couldn't have originated from a project
        return false
    end
    return env.manifest.project_hash == Types.project_hash(env.project)
end

end # module
