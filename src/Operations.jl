# This file is a part of Julia. License is MIT: https://julialang.org/license

module Operations

using Base: CacheFlags
using FileWatching: FileWatching
using UUIDs
using Random: randstring
import LibGit2, Dates, TOML

using ..Types, ..Resolve, ..PlatformEngines, ..GitTools, ..MiniProgressBars
import ..depots, ..depots1, ..devdir, ..set_readonly, ..Types.PackageEntry
import ..Artifacts: ensure_artifact_installed, artifact_names, extract_all_hashes,
    artifact_exists, select_downloadable_artifacts, mv_temp_dir_retries
using Base.BinaryPlatforms
import ...Pkg
import ...Pkg: pkg_server, Registry, pathrepr, can_fancyprint, printpkgstyle, stderr_f, OFFLINE_MODE
import ...Pkg: UPDATED_REGISTRY_THIS_SESSION, RESPECT_SYSIMAGE_VERSIONS, should_autoprecompile
import ...Pkg: usable_io, discover_repo, create_cachedir_tag, manifest_rel_path

#########
# Utils #
#########

# Helper functions for yanked package checking
function is_pkgversion_yanked(uuid::UUID, version::VersionNumber, registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries())
    for reg in registries
        reg_pkg = get(reg, uuid, nothing)
        if reg_pkg !== nothing
            info = Registry.registry_info(reg, reg_pkg)
            if haskey(info.version_info, version) && Registry.isyanked(info, version)
                return true
            end
        end
    end
    return false
end

function is_pkgversion_yanked(pkg::PackageSpec, registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries())
    if pkg.uuid === nothing || pkg.version === nothing || !(pkg.version isa VersionNumber)
        return false
    end
    return is_pkgversion_yanked(pkg.uuid, pkg.version, registries)
end

function is_pkgversion_yanked(entry::PackageEntry, registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries())
    if entry.version === nothing || !(entry.version isa VersionNumber)
        return false
    end
    return is_pkgversion_yanked(entry.uuid, entry.version, registries)
end

function get_pkg_deprecation_info(pkg::Union{PackageSpec, PackageEntry}, registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries())
    pkg.uuid === nothing && return nothing
    for reg in registries
        reg_pkg = get(reg, pkg.uuid, nothing)
        if reg_pkg !== nothing
            info = Registry.registry_info(reg, reg_pkg)
            if Registry.isdeprecated(info)
                return info.deprecated
            end
        end
    end
    return nothing
end

function default_preserve()
    return if Base.get_bool_env("JULIA_PKG_PRESERVE_TIERED_INSTALLED", false)
        PRESERVE_TIERED_INSTALLED
    else
        PRESERVE_TIERED
    end
end

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
tracking_registered_version(pkg::Union{PackageSpec, PackageEntry}, julia_version = VERSION) =
    !is_stdlib(pkg.uuid, julia_version) && pkg.path === nothing && pkg.repo.source === nothing


# Try to download all registries referenced in `ctx.env.manifest.registries`.
# Warn if some fail, but don't error (packages may still work with the registries we have).
function ensure_manifest_registries!(ctx::Context)
    manifest_regs = ctx.env.manifest.registries
    isempty(manifest_regs) && return

    regs_by_uuid = Dict(reg.uuid => reg for reg in ctx.registries)
    missing = ManifestRegistryEntry[]
    for entry in values(manifest_regs)
        reg = get(regs_by_uuid, entry.uuid, nothing)
        if reg === nothing
            push!(missing, entry)
        end
    end

    isempty(missing) && return

    # Try to install missing registries that have URLs
    specs = Registry.RegistrySpec[]
    for entry in missing
        if entry.url !== nothing
            push!(specs, Registry.RegistrySpec(uuid = entry.uuid, url = entry.url))
        end
    end

    if !isempty(specs)
        try
            Registry.add(specs; io = ctx.io)
            copy!(ctx.registries, Registry.reachable_registries())
        catch e
            # Warn but don't error - packages may still work with available registries
            @warn "Failed to install some registries from manifest" exception = (e, catch_backtrace())
        end
    end

    return
end

function source_path(manifest_file::String, pkg::Union{PackageSpec, PackageEntry}, julia_version = VERSION)
    return pkg.tree_hash !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        pkg.path !== nothing ? normpath(joinpath(dirname(manifest_file), pkg.path)) :
        is_or_was_stdlib(pkg.uuid, julia_version) ? Types.stdlib_path(pkg.name) :
        nothing
end

#TODO rename
function load_version(version, fixed, preserve::PreserveLevel)
    if version === nothing
        return VersionSpec() # some stdlibs dont have a version
    elseif fixed
        return version # dont change state if a package is fixed
    elseif preserve == PRESERVE_ALL || preserve == PRESERVE_ALL_INSTALLED || preserve == PRESERVE_DIRECT
        return something(version, VersionSpec())
    elseif preserve == PRESERVE_SEMVER && version != VersionSpec()
        return Types.semver_spec("$(version.major).$(version.minor).$(version.patch)")
    elseif preserve == PRESERVE_NONE
        return VersionSpec()
    end
end

function load_direct_deps(
        env::EnvCache, pkgs::Vector{PackageSpec} = PackageSpec[];
        preserve::PreserveLevel = PRESERVE_DIRECT
    )
    pkgs_direct = load_project_deps(env.project, env.project_file, env.manifest, env.manifest_file, pkgs; preserve)

    for (path, project) in env.workspace
        append!(pkgs_direct, load_project_deps(project, path, env.manifest, env.manifest_file, pkgs; preserve))
    end

    unique_uuids = Set{UUID}(pkg.uuid for pkg in pkgs_direct)
    for uuid in unique_uuids
        idxs = findall(pkg -> pkg.uuid == uuid, pkgs_direct)
        # TODO: Assert that projects do not have conflicting sources
        pkg = pkgs_direct[idxs[1]]
        idx_to_drop = Int[]
        for i in Iterators.drop(idxs, 1)
            # Merge in sources from other projects
            # Manifest info like pinned, tree_hash and version should be the same
            # since that is all loaded from the same manifest
            if pkg.path === nothing && pkgs_direct[i].path !== nothing
                pkg.path = pkgs_direct[i].path
            end
            if pkg.repo.source === nothing && pkgs_direct[i].repo.source !== nothing
                pkg.repo.source = pkgs_direct[i].repo.source
            end
            if pkg.repo.rev === nothing && pkgs_direct[i].repo.rev !== nothing
                pkg.repo.rev = pkgs_direct[i].repo.rev
            end
            push!(idx_to_drop, i)
        end
        sort!(unique!(idx_to_drop))
        deleteat!(pkgs_direct, idx_to_drop)
    end

    return vcat(pkgs, pkgs_direct)
end

function load_project_deps(
        project::Project, project_file::String, manifest::Manifest, manifest_file::String, pkgs::Vector{PackageSpec} = PackageSpec[];
        preserve::PreserveLevel = PRESERVE_DIRECT
    )
    pkgs_direct = PackageSpec[]
    if project.name !== nothing && project.uuid !== nothing && findfirst(pkg -> pkg.uuid == project.uuid, pkgs) === nothing
        path = Types.relative_project_path(manifest_file, dirname(project_file))
        pkg = PackageSpec(; name = project.name, uuid = project.uuid, version = project.version, path)
        push!(pkgs_direct, pkg)
    end

    for (name::String, uuid::UUID) in project.deps
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        path, repo = get_path_repo(project, project_file, manifest_file, name)
        entry = manifest_info(manifest, uuid)
        push!(
            pkgs_direct, entry === nothing ?
                PackageSpec(; uuid, name, path, repo) :
                PackageSpec(;
                    uuid = uuid,
                    name = name,
                    path = path === nothing ? entry.path : path,
                    repo = repo == GitRepo() ? entry.repo : repo,
                    pinned = entry.pinned,
                    tree_hash = entry.tree_hash, # TODO should tree_hash be changed too?
                    version = load_version(entry.version, isfixed(entry), preserve),
                )
        )
    end
    return pkgs_direct
end

function load_manifest_deps(
        manifest::Manifest, pkgs::Vector{PackageSpec} = PackageSpec[];
        preserve::PreserveLevel = PRESERVE_ALL
    )
    pkgs = copy(pkgs)
    for (uuid, entry) in manifest
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        push!(
            pkgs, PackageSpec(
                uuid = uuid,
                name = entry.name,
                path = entry.path,
                pinned = entry.pinned,
                repo = entry.repo,
                tree_hash = entry.tree_hash, # TODO should tree_hash be changed too?
                version = load_version(entry.version, isfixed(entry), preserve),
            )
        )
    end
    return pkgs
end


function load_all_deps(
        env::EnvCache, pkgs::Vector{PackageSpec} = PackageSpec[];
        preserve::PreserveLevel = PRESERVE_ALL
    )
    pkgs = load_manifest_deps(env.manifest, pkgs; preserve = preserve)
    # Sources takes presedence over the manifest...
    for pkg in pkgs
        path, repo = get_path_repo(env.project, env.project_file, env.manifest_file, pkg.name)
        if path !== nothing
            # Path from [sources] takes precedence - clear tree_hash and repo from manifest
            pkg.tree_hash = nothing
            pkg.repo = GitRepo()  # Clear any repo info
            pkg.path = path
        end
        if repo.source !== nothing
            # Repo from [sources] takes precedence - clear path from manifest
            pkg.path = nothing
            pkg.repo.source = repo.source
        end
        if repo.rev !== nothing
            pkg.repo.rev = repo.rev
        end
    end
    return load_direct_deps(env, pkgs; preserve = preserve)
end

function load_all_deps_loadable(env::EnvCache)
    deps = load_all_deps(env)
    keep = Set{UUID}(values(env.project.deps))
    prune_deps(env.manifest, keep)
    filtered = filter(pkg -> pkg.uuid in keep, deps)
    return filtered
end


function is_instantiated(env::EnvCache, workspace::Bool = false; platform = HostPlatform())::Bool
    # Load everything
    if workspace
        pkgs = Operations.load_all_deps(env)
    else
        pkgs = Operations.load_all_deps_loadable(env)
    end
    # If the top-level project is a package, ensure it is instantiated as well
    if env.pkg !== nothing
        # Top-level project may already be in the manifest (cyclic deps)
        # so only add it if it isn't there
        idx = findfirst(x -> x.uuid == env.pkg.uuid, pkgs)
        if idx === nothing
            push!(pkgs, Types.PackageSpec(name = env.pkg.name, uuid = env.pkg.uuid, version = env.pkg.version, path = dirname(env.project_file)))
        end
    else
        # Make sure artifacts for project exist even if it is not a package
        check_artifacts_downloaded(dirname(env.project_file); platform) || return false
    end
    # Make sure all paths/artifacts exist
    return all(pkg -> is_package_downloaded(env.manifest_file, pkg; platform), pkgs)
end

function update_manifest!(env::EnvCache, pkgs::Vector{PackageSpec}, deps_map, julia_version, registries::Vector{Registry.RegistryInstance})
    manifest = env.manifest
    empty!(manifest)

    # Determine which registries are used by tracking packages
    used_registry_uuids = Set{UUID}()
    pkg_to_registries = Dict{UUID, Vector{UUID}}()

    for pkg in pkgs
        if tracking_registered_version(pkg, julia_version)
            # Find all registries that have this package version
            pkg_reg_uuids = UUID[]
            for reg in registries
                reg_pkg = get(reg, pkg.uuid, nothing)
                reg_pkg === nothing && continue
                pkg_info = Registry.registry_info(reg, reg_pkg)
                version_info = get(pkg_info.version_info, pkg.version, nothing)
                version_info === nothing && continue
                push!(pkg_reg_uuids, reg.uuid)
                push!(used_registry_uuids, reg.uuid)
            end
            if !isempty(pkg_reg_uuids)
                pkg_to_registries[pkg.uuid] = pkg_reg_uuids
            end
        end
    end

    # Build registry entries and name map for used registries only
    uuid_to_name = Dict{UUID, String}()
    registry_entries = Dict{String, ManifestRegistryEntry}()
    for reg in registries
        reg.uuid in used_registry_uuids || continue
        reg_name = getfield(reg, :name)
        uuid_to_name[reg.uuid] = reg_name
        registry_entries[reg_name] = ManifestRegistryEntry(
            id = reg_name,
            uuid = reg.uuid,
            url = getfield(reg, :repo),
        )
    end

    # Build package entries
    for pkg in pkgs
        entry = PackageEntry(;
            name = pkg.name, version = pkg.version, pinned = pkg.pinned,
            tree_hash = pkg.tree_hash, path = pkg.path, repo = pkg.repo, uuid = pkg.uuid
        )
        if is_stdlib(pkg.uuid, julia_version)
            # Only set stdlib versions for versioned (external) stdlibs
            entry.version = stdlib_version(pkg.uuid, julia_version)
        end
        entry.deps = deps_map[pkg.uuid]

        # Convert registry UUIDs to names
        if haskey(pkg_to_registries, pkg.uuid)
            reg_names = String[]
            for reg_uuid in pkg_to_registries[pkg.uuid]
                if haskey(uuid_to_name, reg_uuid)
                    push!(reg_names, uuid_to_name[reg_uuid])
                end
            end
            entry.registries = reg_names
        end

        env.manifest[pkg.uuid] = entry
    end
    prune_manifest(env)

    env.manifest.registries = registry_entries
    env.manifest.manifest_format = v"2.1.0"
    return record_project_hash(env)
end

"""
    get_project_syntax_version(p::Project) -> VersionNumber

Extract the syntax version from a Project.

This function determines which version of Julia syntax a package uses, following
this precedence order:

1. If `syntax.julia_version` is present in the Project.toml, use that value
2. If `compat.julia` is specified, use the minimum version from the compat range
3. Otherwise, default to the current Julia VERSION

This information is used to populate the `syntax.julia_version` field in the
Manifest.toml, allowing Base's loading system to parse each package with the
correct syntax version.
"""
function get_project_syntax_version(p::Project)::VersionNumber
    # First check syntax.julia_version entry in Project.other
    if p.julia_syntax_version !== nothing
        return VersionNumber(syntax_table["julia_version"])
    end

    # If not found, default to minimum(compat["julia"])
    if haskey(p.compat, "julia")
        julia_compat = p.compat["julia"]
        # Get the minimum version from the first range
        if !isempty(julia_compat.val.ranges)
            first_range = first(julia_compat.val.ranges)
            lower_bound = first_range.lower
            return VersionNumber(lower_bound.t[1], lower_bound.t[2], lower_bound.t[3])
        end
    end

    # Finally, if neither of those are set, default to the current Julia version
    return VERSION
end

# This has to be done after the packages have been downloaded
# since we need access to the Project file to read the information
# about extensions
function fixups_from_projectfile!(ctx::Context)
    env = ctx.env
    for pkg in values(env.manifest)
        if ctx.julia_version !== VERSION && is_stdlib(pkg.uuid, ctx.julia_version)
            # Special handling for non-current julia_version resolving given the source for historical stdlibs
            # isn't available at this stage as Pkg thinks it should not be needed, so rely on STDLIBS_BY_VERSION
            stdlibs = Types.get_last_stdlibs(ctx.julia_version)
            p = stdlibs[pkg.uuid]
            pkg.weakdeps = Dict{String, Base.UUID}(stdlibs[uuid].name => uuid for uuid in p.weakdeps)
            # pkg.exts = p.exts # TODO: STDLIBS_BY_VERSION doesn't record this
            # pkg.entryfile = p.entryfile # TODO: STDLIBS_BY_VERSION doesn't record this
            for (name, _) in pkg.weakdeps
                if !(name in p.deps)
                    delete!(pkg.deps, name)
                end
            end
        else
            # normal mode based on project files.
            # isfile_casesenstive within locate_project_file used to error on Windows if given a
            # relative path so abspath it to be extra safe https://github.com/JuliaLang/julia/pull/55220
            sourcepath = source_path(env.manifest_file, pkg)
            if sourcepath === nothing
                pkgerror("could not find source path for package $(pkg.name) based on manifest $(env.manifest_file)")
            end
            project_file = Base.locate_project_file(abspath(sourcepath))
            if project_file isa String && isfile(project_file)
                p = Types.read_project(project_file)
                pkg.weakdeps = p.weakdeps
                pkg.exts = p.exts
                pkg.entryfile = p.entryfile
                pkg.julia_syntax_version = get_project_syntax_version(p)

                for (name, _) in p.weakdeps
                    if !haskey(p.deps, name)
                        delete!(pkg.deps, name)
                    end
                end
            end
        end
    end
    return prune_manifest(env)
end

####################
# Registry Loading #
####################

function load_tree_hash!(
        registries::Vector{Registry.RegistryInstance},
        pkg::PackageSpec,
        julia_version,
    )
    if is_stdlib(pkg.uuid, julia_version) && pkg.tree_hash !== nothing
        # manifests from newer julia versions might have stdlibs that are upgradable (FORMER_STDLIBS)
        # that have tree_hash recorded, which we need to clear for this version where they are not upgradable
        # given regular stdlibs don't have tree_hash recorded
        pkg.tree_hash = nothing
        return pkg
    end
    tracking_registered_version(pkg, julia_version) || return pkg
    hash = nothing
    for reg in registries
        reg_pkg = get(reg, pkg.uuid, nothing)
        reg_pkg === nothing && continue
        pkg_info = Registry.registry_info(reg, reg_pkg)
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

# Helper to check if compat is compatible with a non-upgradable stdlib, warn if not, and return appropriate VersionSpec
function check_stdlib_compat(name::String, uuid::UUID, compat::VersionSpec, project::Project, project_file::String, julia_version)
    is_stdlib(uuid) && !(uuid in Types.UPGRADABLE_STDLIBS_UUIDS) || return compat

    stdlib_ver = stdlib_version(uuid, julia_version)
    stdlib_ver === nothing && return compat
    isempty(compat) && return compat
    stdlib_ver in compat && return compat

    compat_str = get_compat_str(project, name)
    if compat_str !== nothing
        suggested_compat = string(compat_str, ", ", stdlib_ver.major == 0 ? string(stdlib_ver.major, ".", stdlib_ver.minor) : string(stdlib_ver.major))
        @warn """Ignoring incompatible compat entry `$name = $(repr(compat_str))` in $(repr(project_file)).
        $name is a non-upgradable standard library with version $stdlib_ver in the current Julia version.
        Fix by setting compat to $(repr(suggested_compat)) to mark support of the current version $stdlib_ver.""" maxlog = 1
    end
    return VersionSpec("*")
end

# Get compat for a dependency, checking if it's a non-upgradable stdlib and warning if incompatible
function get_compat_with_stdlib_check(project::Project, project_file::String, name::String, uuid::UUID, julia_version)
    compat = get_compat(project, name)
    return check_stdlib_compat(name, uuid, compat, project, project_file, julia_version)
end

function set_compat(proj::Project, name::String, compat::String)
    semverspec = Types.semver_spec(compat, throw = false)
    isnothing(semverspec) && return false
    proj.compat[name] = Types.Compat(semverspec, compat)
    return true
end
function set_compat(proj::Project, name::String, ::Nothing)
    delete!(proj.compat, name)
    return true
end

function reset_all_compat!(proj::Project)
    for name in keys(proj.compat)
        compat = proj.compat[name]
        if compat.val != Types.semver_spec(compat.str)
            proj.compat[name] = Types.Compat(Types.semver_spec(compat.str), compat.str)
        end
    end
    return nothing
end

function collect_project(pkg::Union{PackageSpec, Nothing}, path::String, manifest_file::String, julia_version)
    deps = PackageSpec[]
    weakdeps = Set{UUID}()
    project_file = projectfile_path(path; strict = true)
    project = project_file === nothing ? Project() : read_project(project_file)
    julia_compat = get_compat(project, "julia")
    if !isnothing(julia_compat) && !isnothing(julia_version) && !(julia_version in julia_compat)
        pkgerror("julia version requirement for package at `$path` not satisfied: compat entry \"julia = $(get_compat_str(project, "julia"))\" does not include Julia version $julia_version")
    end
    for (name, uuid) in project.deps
        dep_path, repo = get_path_repo(project, project_file, manifest_file, name)
        vspec = get_compat_with_stdlib_check(project, something(project_file, path), name, uuid, julia_version)
        push!(deps, PackageSpec(name = name, uuid = uuid, version = vspec, path = dep_path, repo = repo))
    end
    for (name, uuid) in project.weakdeps
        vspec = get_compat_with_stdlib_check(project, something(project_file, path), name, uuid, julia_version)
        push!(deps, PackageSpec(name, uuid, vspec))
        push!(weakdeps, uuid)
    end
    if pkg !== nothing
        if project.version !== nothing
            pkg.version = project.version
        else
            # @warn("project file for $(pkg.name) is missing a `version` entry")
            pkg.version = VersionNumber(0)
        end
    end
    return deps, weakdeps
end

is_tracking_path(pkg) = pkg.path !== nothing
is_tracking_repo(pkg) = (pkg.repo.source !== nothing || pkg.repo.rev !== nothing)
is_tracking_registry(pkg) = !is_tracking_path(pkg) && !is_tracking_repo(pkg)
isfixed(pkg) = !is_tracking_registry(pkg) || pkg.pinned

function collect_developed!(env::EnvCache, pkg::PackageSpec, developed::Vector{PackageSpec})
    source = source_path(env.manifest_file, pkg)
    source_env = EnvCache(projectfile_path(source))
    pkgs = load_project_deps(source_env.project, source_env.project_file, source_env.manifest, source_env.manifest_file)
    for pkg in pkgs
        if any(x -> x.uuid == pkg.uuid, developed)
            continue
        end
        if is_tracking_path(pkg)
            # normalize path
            # TODO: If path is collected from project, it is relative to the project file
            # otherwise relative to manifest file....
            pkg.path = Types.relative_project_path(
                env.manifest_file,
                source_path(source_env.manifest_file, pkg)
            )
            push!(developed, pkg)
            collect_developed!(env, pkg, developed)
        elseif is_tracking_repo(pkg)
            push!(developed, pkg)
        end
    end
    return
end

function collect_developed(env::EnvCache, pkgs::Vector{PackageSpec})
    developed = PackageSpec[]
    for pkg in filter(is_tracking_path, pkgs)
        collect_developed!(env, pkg, developed)
    end
    return developed
end

function collect_fixed!(env::EnvCache, pkgs::Vector{PackageSpec}, names::Dict{UUID, String}, julia_version)
    deps_map = Dict{UUID, Vector{PackageSpec}}()
    weak_map = Dict{UUID, Set{UUID}}()

    uuid = Types.project_uuid(env)
    deps, weakdeps = collect_project(env.pkg, dirname(env.project_file), env.manifest_file, julia_version)
    deps_map[uuid] = deps
    weak_map[uuid] = weakdeps
    names[uuid] = env.pkg === nothing ? "project" : env.pkg.name

    for (path, project) in env.workspace
        uuid = Types.project_uuid(project, path)
        pkg = project.name === nothing ? nothing : PackageSpec(name = project.name, uuid = uuid)
        deps, weakdeps = collect_project(pkg, path, env.manifest_file, julia_version)
        deps_map[Types.project_uuid(env)] = deps
        weak_map[Types.project_uuid(env)] = weakdeps
        names[uuid] = project.name === nothing ? "project" : project.name
    end

    pkg_queue = collect(pkgs)
    pkg_by_uuid = Dict{UUID, PackageSpec}()
    for pkg in pkgs
        pkg.uuid === nothing && continue
        pkg_by_uuid[pkg.uuid] = pkg
    end
    new_fixed_pkgs = PackageSpec[]
    seen = Set(keys(pkg_by_uuid))
    while !isempty(pkg_queue)
        pkg = popfirst!(pkg_queue)
        pkg.uuid === nothing && continue
        # add repo package if necessary
        source = source_path(env.manifest_file, pkg)
        path = source
        if (path === nothing || !isdir(path)) && (pkg.repo.rev !== nothing || pkg.repo.source !== nothing)
            # ensure revved package is installed
            # pkg.tree_hash is set in here
            Types.handle_repo_add!(Types.Context(env = env), pkg)
            # Recompute path
            path = source_path(env.manifest_file, pkg)
        end
        if !isdir(path)
            # Find which packages depend on this missing package for better error reporting
            dependents = String[]
            for (dep_uuid, dep_entry) in env.manifest.deps
                if pkg.uuid in values(dep_entry.deps) || pkg.uuid in values(dep_entry.weakdeps)
                    push!(dependents, dep_entry.name === nothing ? "unknown package [$dep_uuid]" : dep_entry.name)
                end
            end

            error_msg = "expected package $(err_rep(pkg)) to exist at path `$path`"
            error_msg *= "\n\nThis package is referenced in the manifest file: $(env.manifest_file)"

            if !isempty(dependents)
                if length(dependents) == 1
                    error_msg *= "\nIt is required by: $(dependents[1])"
                else
                    error_msg *= "\nIt is required by:\n$(join(["  - $dep" for dep in dependents], "\n"))"
                end
            end
            pkgerror(error_msg)
        end
        deps, weakdeps = collect_project(pkg, path, env.manifest_file, julia_version)
        deps_map[pkg.uuid] = deps
        weak_map[pkg.uuid] = weakdeps
        for dep in deps
            names[dep.uuid] = dep.name
            dep_uuid = dep.uuid
            if !is_tracking_registry(dep) && dep_uuid !== nothing && !(dep_uuid in seen)
                # Only recursively collect path sources if the path actually exists
                # Repo sources (with URL/rev) are always collected
                if is_tracking_path(dep)
                    dep_source = source_path(env.manifest_file, dep)
                    if dep_source !== nothing && isdir(dep_source)
                        push!(pkg_queue, dep)
                        push!(new_fixed_pkgs, dep)
                        pkg_by_uuid[dep_uuid] = dep
                        push!(seen, dep_uuid)
                    end
                else
                    # Repo source - always add to queue
                    push!(pkg_queue, dep)
                    push!(new_fixed_pkgs, dep)
                    pkg_by_uuid[dep_uuid] = dep
                    push!(seen, dep_uuid)
                end
            elseif dep_uuid !== nothing && !haskey(pkg_by_uuid, dep_uuid)
                pkg_by_uuid[dep_uuid] = dep
            end
        end
    end

    fixed = Dict{UUID, Resolve.Fixed}()
    # Collect the dependencies for the fixed packages
    for (uuid, deps) in deps_map
        q = Dict{UUID, VersionSpec}()
        for dep in deps
            names[dep.uuid] = dep.name
            dep_version = dep.version
            dep_version === nothing && continue
            q[dep.uuid] = dep_version isa VersionSpec ? dep_version : VersionSpec(dep_version)
        end
        fix_pkg = Types.is_project_uuid(env, uuid) ? env.pkg : get(pkg_by_uuid, uuid, nothing)
        fixpkgversion = fix_pkg === nothing ? v"0.0.0" : fix_pkg.version
        fixed[uuid] = Resolve.Fixed(fixpkgversion, q, get(weak_map, uuid, Set{UUID}()))
    end
    return fixed, new_fixed_pkgs
end

# drops build detail in version but keeps the main prerelease context
# i.e. dropbuild(v"2.0.1-rc1.21321") == v"2.0.1-rc1"
dropbuild(v::VersionNumber) = VersionNumber(v.major, v.minor, v.patch, isempty(v.prerelease) ? () : (v.prerelease[1],))

function get_compat_workspace(env, name)
    # Are we allowing packages with the same name and different uuids
    # in different project files in the same workspace? In that case,
    # need to pass in a UUID here instead of a name.
    compat = get_compat(env.project, name)
    for (_, project) in env.workspace
        compat = intersect(compat, get_compat(project, name))
    end

    uuid = get(env.project.deps, name, nothing)
    if uuid !== nothing
        compat = check_stdlib_compat(name, uuid, compat, env.project, env.project_file, VERSION)
    end

    return compat
end

# Resolve a set of versions given package version specs
# looks at uuid, version, repo/path,
# sets version to a VersionNumber
# adds any other packages which may be in the dependency graph
# all versioned packages should have a `tree_hash`
function resolve_versions!(
        env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, julia_version,
        installed_only::Bool
    )
    installed_only = installed_only || OFFLINE_MODE[]

    # compatibility
    if julia_version !== nothing
        # only set the manifest julia_version if ctx.julia_version is not nothing
        env.manifest.julia_version = dropbuild(julia_version)
        v = intersect(julia_version, get_compat_workspace(env, "julia"))
        if isempty(v)
            @warn "julia version requirement for project not satisfied" _module = nothing _file = nothing
        end
    end

    jll_fix = Dict{UUID, VersionNumber}()
    for pkg in pkgs
        if !is_stdlib(pkg.uuid, julia_version) && endswith(pkg.name, "_jll") && pkg.version isa VersionNumber
            jll_fix[pkg.uuid] = pkg.version
        end
    end

    names = Dict{UUID, String}(uuid => info.name for (uuid, info) in stdlib_infos())
    # recursive search for packages which are tracking a path
    developed = collect_developed(env, pkgs)
    # But we only want to use information for those packages that we don't know about
    for pkg in developed
        if !any(x -> x.uuid == pkg.uuid, pkgs)
            push!(pkgs, pkg)
        end
    end
    # this also sets pkg.version for fixed packages
    pkgs_fixed = filter(!is_tracking_registry, pkgs)
    fixed, new_fixed_pkgs = collect_fixed!(env, pkgs_fixed, names, julia_version)
    for new_pkg in new_fixed_pkgs
        any(x -> x.uuid == new_pkg.uuid, pkgs) && continue
        push!(pkgs, new_pkg)
    end
    # non fixed packages are `add`ed by version: their version is either restricted or free
    # fixed packages are `dev`ed or `add`ed by repo
    # at this point, fixed packages have a version and `deps`

    @assert length(Set(pkg.uuid::UUID for pkg in pkgs)) == length(pkgs)

    # check compat
    for pkg in pkgs
        compat = get_compat_workspace(env, pkg.name)
        v = intersect(pkg.version, compat)
        if isempty(v)
            throw(
                Resolve.ResolverError(
                    "empty intersection between $(pkg.name)@$(pkg.version) and project compatibility $(compat)"
                )
            )
        end
        # Work around not clobbering 0.x.y+ for checked out old type of packages
        if !(pkg.version isa VersionNumber)
            pkg.version = v
        end
    end

    for pkg in pkgs
        names[pkg.uuid] = pkg.name
    end

    # Unless using the unbounded or historical resolver, always allow stdlibs to update. Helps if the previous resolve
    # happened on a different julia version / commit and the stdlib version in the manifest is not the current stdlib version
    unbind_stdlibs = julia_version === VERSION
    reqs = Resolve.Requires(pkg.uuid => is_stdlib(pkg.uuid, julia_version) && unbind_stdlibs ? VersionSpec("*") : VersionSpec(pkg.version) for pkg in pkgs)
    deps_map_compressed, compat_map_compressed, weak_deps_map_compressed, weak_compat_map_compressed, pkg_versions_map, pkg_versions_per_registry, uuid_to_name, reqs, fixed = deps_graph(env, registries, names, reqs, fixed, julia_version, installed_only)
    graph = Resolve.Graph(deps_map_compressed, compat_map_compressed, weak_deps_map_compressed, weak_compat_map_compressed, pkg_versions_map, pkg_versions_per_registry, uuid_to_name, reqs, fixed, false, julia_version)
    Resolve.simplify_graph!(graph)
    vers = Resolve.resolve(graph)

    # Fixup jlls that got their build numbers stripped
    vers_fix = copy(vers)
    for (uuid, vers) in vers
        old_v = get(jll_fix, uuid, nothing)
        # We only fixup a JLL if the old major/minor/patch matches the new major/minor/patch
        if old_v !== nothing && Base.thispatch(old_v) == Base.thispatch(vers_fix[uuid])
            vers_fix[uuid] = old_v
            # Add old_v to pkg_versions_map so it's considered available
            # even if it was yanked (needed for sysimage compatibility)
            versions_for_pkg = get!(pkg_versions_map, uuid, VersionNumber[])
            if !(old_v in versions_for_pkg)
                push!(versions_for_pkg, old_v)
                sort!(versions_for_pkg)
            end
        end
    end
    vers = vers_fix

    # update vector of package versions
    for (uuid, ver) in vers
        idx = findfirst(p -> p.uuid == uuid, pkgs)
        if idx !== nothing
            pkg = pkgs[idx]
            # Fixed packages are not returned by resolve (they already have their version set)
            pkg.version = vers[pkg.uuid]
        else
            name = is_stdlib(uuid) ? stdlib_infos()[uuid].name : registered_name(registries, uuid)
            push!(pkgs, PackageSpec(; name = name, uuid = uuid, version = ver))
        end
    end

    # Collect all UUIDs that will be in the manifest
    pkgs_uuids = Set{UUID}(pkg.uuid for pkg in pkgs)

    final_deps_map = Dict{UUID, Dict{String, UUID}}()
    for pkg in pkgs
        load_tree_hash!(registries, pkg, julia_version)
        deps = begin
            if pkg.uuid in keys(fixed)
                deps_fixed = Dict{String, UUID}()
                for dep in keys(fixed[pkg.uuid].requires)
                    # Only include deps that are actually in the manifest
                    dep in pkgs_uuids || continue
                    deps_fixed[names[dep]] = dep
                end
                deps_fixed
            else
                d = Dict{String, UUID}()
                available_versions = get(Vector{VersionNumber}, pkg_versions_map, pkg.uuid)
                if !(pkg.version in available_versions)
                    pkgerror("version $(pkg.version) of package $(pkg.name) is not available. Available versions: $(join(available_versions, ", "))")
                end
                deps_for_version = Registry.query_deps_for_version(
                    deps_map_compressed, weak_deps_map_compressed,
                    pkg.uuid, pkg.version
                )
                for uuid in deps_for_version
                    # Only include deps that are actually in the manifest
                    uuid in pkgs_uuids || continue
                    d[names[uuid]] = uuid
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

get_or_make!(d::Dict{K, V}, k::K) where {K, V} = get!(d, k) do;
    V()
end

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
const PKGORIGIN_HAVE_VERSION = :version in fieldnames(Base.PkgOrigin)
function deps_graph(
        env::EnvCache, registries::Vector{Registry.RegistryInstance}, uuid_to_name::Dict{UUID, String},
        reqs::Resolve.Requires, fixed::Dict{UUID, Resolve.Fixed}, julia_version,
        installed_only::Bool
    )
    uuids = Set{UUID}()
    union!(uuids, keys(reqs))
    union!(uuids, keys(fixed))
    for fixed_uuids in map(fx -> keys(fx.requires), values(fixed))
        union!(uuids, fixed_uuids)
    end

    # Collect all weak dependency UUIDs from fixed packages
    all_weak_uuids = Set{UUID}()
    for fx in values(fixed)
        union!(all_weak_uuids, fx.weak)
    end

    stdlibs_for_julia_version = Types.get_last_stdlibs(julia_version)
    seen = Set{UUID}()

    # pkg -> vector of (registry data) for handling multiple registries correctly
    # Each element in the vector represents data from one registry
    all_deps_compressed = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}()
    all_compat_compressed = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}()
    weak_deps_compressed = Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}}()
    weak_compat_compressed = Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}}()

    # pkg -> list of valid versions:
    pkg_versions = Dict{UUID, Vector{VersionNumber}}()

    # pkg -> vector of (versions from each registry) - parallel to the compressed data vectors
    # This tracks which versions came from which registry to avoid cross-registry compat pollution
    pkg_versions_per_registry = Dict{UUID, Vector{Set{VersionNumber}}}()

    for (fp, fx) in fixed
        all_deps_compressed[fp] = [Dict{VersionRange, Set{UUID}}()]
        all_compat_compressed[fp] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
        weak_deps_compressed[fp] = [Dict{VersionRange, Set{UUID}}()]
        weak_compat_compressed[fp] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
        pkg_versions[fp] = [fx.version]
        pkg_versions_per_registry[fp] = [Set([fx.version])]
    end

    while true
        unseen = setdiff(uuids, seen)
        isempty(unseen) && break
        for uuid in unseen
            push!(seen, uuid)
            uuid in keys(fixed) && continue
            uuid_is_stdlib = haskey(stdlibs_for_julia_version, uuid)

            # If we're requesting resolution of a package that is an
            # unregistered stdlib we must special-case it here.  This is further
            # complicated by the fact that we can ask this question relative to
            # a Julia version.
            # CRITICAL: Never resolve stdlibs from registry for target julia_version
            if (julia_version != VERSION && is_unregistered_stdlib(uuid)) || uuid_is_stdlib
                # We use our historical stdlib versioning data to unpack the version, deps and weakdeps of this uuid
                stdlib_info = stdlibs_for_julia_version[uuid]
                v = something(stdlib_info.version, VERSION)

                # For stdlibs, create a single registry entry
                stdlib_deps = Dict{VersionRange, Set{UUID}}()
                stdlib_compat = Dict{VersionRange, Dict{UUID, VersionSpec}}()
                stdlib_weak_deps = Dict{VersionRange, Set{UUID}}()
                stdlib_weak_compat = Dict{VersionRange, Dict{UUID, VersionSpec}}()

                vrange = VersionRange(v, v)
                deps_set = Set{UUID}()
                for other_uuid in stdlib_info.deps
                    push!(uuids, other_uuid)
                    push!(deps_set, other_uuid)
                end
                stdlib_deps[vrange] = deps_set
                stdlib_compat[vrange] = Dict{UUID, VersionSpec}()

                if !isempty(stdlib_info.weakdeps)
                    weak_deps_set = Set{UUID}()
                    for other_uuid in stdlib_info.weakdeps
                        push!(uuids, other_uuid)
                        push!(weak_deps_set, other_uuid)
                    end
                    stdlib_weak_deps[vrange] = weak_deps_set
                    stdlib_weak_compat[vrange] = Dict{UUID, VersionSpec}()
                end

                all_deps_compressed[uuid] = [stdlib_deps]
                all_compat_compressed[uuid] = [stdlib_compat]
                weak_deps_compressed[uuid] = [stdlib_weak_deps]
                weak_compat_compressed[uuid] = [stdlib_weak_compat]
                pkg_versions[uuid] = [v]
                pkg_versions_per_registry[uuid] = [Set([v])]
            else
                # Accumulate valid versions from all registries
                valid_versions = VersionNumber[]
                # Store per-registry data separately - don't merge!
                pkg_deps_list = Vector{Dict{VersionRange, Set{UUID}}}()
                pkg_compat_list = Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}()
                pkg_weak_deps_list = Vector{Dict{VersionRange, Set{UUID}}}()
                pkg_weak_compat_list = Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}()
                pkg_versions_per_reg = Vector{Set{VersionNumber}}()

                for reg in registries
                    pkg = get(reg, uuid, nothing)
                    pkg === nothing && continue
                    info = Registry.registry_info(reg, pkg)

                    # Build filtered version list for this registry
                    reg_valid_versions = Set{VersionNumber}()
                    for v in keys(info.version_info)
                        # Filter yanked and if we are in offline mode also downloaded packages
                        Registry.isyanked(info, v) && continue
                        if installed_only
                            pkg_spec = PackageSpec(name = pkg.name, uuid = pkg.uuid, version = v, tree_hash = Registry.treehash(info, v))
                            is_package_downloaded(env.manifest_file, pkg_spec) || continue
                        end

                        # Skip package version that are not the same as external packages in sysimage
                        if PKGORIGIN_HAVE_VERSION && RESPECT_SYSIMAGE_VERSIONS[] && julia_version == VERSION
                            pkgid = Base.PkgId(uuid, pkg.name)
                            if Base.in_sysimage(pkgid)
                                pkgorigin = get(Base.pkgorigins, pkgid, nothing)
                                if pkgorigin !== nothing && pkgorigin.version !== nothing
                                    if v != pkgorigin.version
                                        continue
                                    end
                                end
                            end
                        end

                        push!(reg_valid_versions, v)
                        push!(valid_versions, v)
                    end

                    # Only add this registry's data if it has valid versions
                    if !isempty(reg_valid_versions)
                        # Store the full compressed data along with which versions are valid
                        # The query function will check version membership to avoid cross-registry pollution
                        push!(pkg_deps_list, info.deps)
                        push!(pkg_compat_list, info.compat)
                        push!(pkg_weak_deps_list, info.weak_deps)
                        push!(pkg_weak_compat_list, info.weak_compat)
                        push!(pkg_versions_per_reg, reg_valid_versions)
                    end

                    # Collect all dependency UUIDs for discovery
                    for deps_dict in (info.deps, info.weak_deps)
                        for (vrange, deps_set) in deps_dict
                            union!(uuids, deps_set)
                        end
                    end
                end

                # After processing all registries, sort and store the accumulated versions
                pkg_versions[uuid] = sort!(unique!(valid_versions))

                # Store the per-registry data
                all_deps_compressed[uuid] = pkg_deps_list
                all_compat_compressed[uuid] = pkg_compat_list
                weak_deps_compressed[uuid] = pkg_weak_deps_list
                weak_compat_compressed[uuid] = pkg_weak_compat_list
                pkg_versions_per_registry[uuid] = pkg_versions_per_reg
            end
        end
    end

    # Track weak dependencies that are not available in any registry
    unavailable_weak_uuids = Set{UUID}()

    for uuid in uuids
        uuid == JULIA_UUID && continue
        if !haskey(uuid_to_name, uuid)
            name = registered_name(registries, uuid)
            if name === nothing
                # Allow weak dependencies to be missing from registries
                if uuid in all_weak_uuids
                    push!(unavailable_weak_uuids, uuid)
                    continue
                end
                pkgerror("cannot find name corresponding to UUID $(uuid) in a registry")
            end
            uuid_to_name[uuid] = name
            entry = manifest_info(env.manifest, uuid)
            entry ≡ nothing && continue
            uuid_to_name[uuid] = entry.name
        end
    end

    # Filter out unavailable weak dependencies from fixed packages
    if !isempty(unavailable_weak_uuids)
        fixed_filtered = Dict{UUID, Resolve.Fixed}()
        for (uuid, fx) in fixed
            filtered_requires = Requires()
            for (req_uuid, req_spec) in fx.requires
                if !(req_uuid in unavailable_weak_uuids)
                    filtered_requires[req_uuid] = req_spec
                end
            end
            # Also filter the weak set
            filtered_weak = setdiff(fx.weak, unavailable_weak_uuids)
            fixed_filtered[uuid] = Resolve.Fixed(fx.version, filtered_requires, filtered_weak)
        end
        fixed = fixed_filtered
    end

    return all_deps_compressed, all_compat_compressed, weak_deps_compressed, weak_compat_compressed, pkg_versions, pkg_versions_per_registry, uuid_to_name, reqs, fixed
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
        urls::Vector{Pair{String, Bool}},
        hash::SHA1,
        version_path::String;
        io::IO = stderr_f()
    )::Bool
    # Because we use `mv_temp_dir_retries` which uses `rename` not `mv` it can fail if the temp
    # files are on a different fs. So use a temp dir in the same depot dir as some systems might
    # be serving different parts of the depot on different filesystems via links i.e. pkgeval does this.
    depot_temp = mkpath(joinpath(dirname(dirname(version_path)), "temp")) # .julia/packages/temp
    create_cachedir_tag(dirname(dirname(version_path)))

    tmp_objects = String[]
    url_success = false
    for (url, top) in urls
        path = tempname() * randstring(6)
        push!(tmp_objects, path) # for cleanup
        url_success = true
        try
            PlatformEngines.download(url, path; verbose = false, io = io)
        catch e
            e isa InterruptException && rethrow()
            url_success = false
        end
        url_success || continue
        # the temp dir should be in the same depot because the `rename` operation in `mv_temp_dir_retries`
        # is possible only if the source and destination are on the same filesystem
        dir = tempname(depot_temp) * randstring(6)
        push!(tmp_objects, dir) # for cleanup
        # Might fail to extract an archive (https://github.com/JuliaPackaging/PkgServer.jl/issues/126)
        try
            unpack(path, dir; verbose = false)
        catch e
            e isa ProcessFailedException || rethrow()
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
        computed_hash = GitTools.tree_hash(unpacked)
        if SHA1(computed_hash) != hash
            @warn "tarball content of url $url does not match git-tree-sha1, expected $hash, got $computed_hash"
            url_success = false
        end
        url_success || continue

        # Move content to version path
        !isdir(dirname(version_path)) && mkpath(dirname(version_path))
        mv_temp_dir_retries(unpacked, version_path; set_permissions = false)

        break # successful install
    end
    # Clean up and exit
    foreach(x -> Base.rm(x; force = true, recursive = true), tmp_objects)
    return url_success
end

const refspecs = ["+refs/*:refs/cache/*"]
function install_git(
        io::IO,
        uuid::UUID,
        name::String,
        hash::SHA1,
        urls::Set{String},
        version_path::String
    )::Nothing
    if isempty(urls)
        pkgerror(
            "Package $name [$uuid] has no repository URL available. This could happen if:\n" *
                "  - The package is not registered in any configured registry\n" *
                "  - The package exists in a registry but lacks repository information\n" *
                "  - Registry files are corrupted or incomplete\n" *
                "  - Network issues prevented registry updates\n" *
                "Please check that the package name is correct and that your registries are up to date."
        )
    end

    repo = nothing
    tree = nothing
    # TODO: Consolidate this with some of the repo handling in Types.jl
    try
        clones_dir = joinpath(depots1(), "clones")
        ispath(clones_dir) || mkpath(clones_dir)
        create_cachedir_tag(clones_dir)
        repo_path = joinpath(clones_dir, string(uuid))
        first_url = first(urls)
        repo = GitTools.ensure_clone(
            io, repo_path, first_url; isbare = true,
            header = "[$uuid] $name from $first_url", depth = 1
        )
        git_hash = LibGit2.GitHash(hash.bytes)
        for url in urls
            try
                LibGit2.with(LibGit2.GitObject, repo, git_hash) do g
                end
                break # object was found, we can stop
            catch err
                err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            end
            GitTools.fetch(io, repo, url, refspecs = refspecs, depth = LibGit2.Consts.FETCH_DEPTH_UNSHALLOW)
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
        create_cachedir_tag(dirname(dirname(version_path)))
        GitTools.checkout_tree_to_path(repo, tree, version_path)
        return
    finally
        repo !== nothing && LibGit2.close(repo)
        tree !== nothing && LibGit2.close(tree)
    end
end

function collect_artifacts(pkg_root::String; platform::AbstractPlatform = HostPlatform(), include_lazy::Bool = false)
    # Check to see if this package has an (Julia)Artifacts.toml
    artifacts_tomls = Tuple{String, Base.TOML.TOMLDict}[]
    for f in artifact_names
        artifacts_toml = joinpath(pkg_root, f)
        if isfile(artifacts_toml)
            selector_path = joinpath(pkg_root, ".pkg", "select_artifacts.jl")

            # If there is a dynamic artifact selector, run that in an appropriate sandbox to select artifacts
            if isfile(selector_path)
                # Despite the fact that we inherit the project, since the in-memory manifest
                # has not been updated yet, if we try to load any dependencies, it may fail.
                # Therefore, this project inheritance is really only for Preferences, not dependencies.
                # We only guarantee access to the `stdlib`, which is why we set `add_stdlib` here.
                select_cmd = Cmd(`$(gen_build_code(selector_path; inherit_project=true, add_stdlib=true)) --compile=min -t1 --startup-file=no $(triplet(platform))`)
                meta_toml = String(read(select_cmd))
                res = TOML.tryparse(meta_toml)
                if res isa TOML.ParserError
                    errstr = sprint(showerror, res; context = stderr)
                    pkgerror("failed to parse TOML output from running $(repr(selector_path)), got: \n$errstr")
                else
                    push!(artifacts_tomls, (artifacts_toml, TOML.parse(meta_toml)))
                end
            else
                # Otherwise, use the standard selector from `Artifacts`
                artifacts = select_downloadable_artifacts(artifacts_toml; platform, include_lazy)
                push!(artifacts_tomls, (artifacts_toml, artifacts))
            end
            break
        end
    end
    return artifacts_tomls
end

mutable struct DownloadState
    state::Symbol # is :ready, :running, :done, or :failed
    status::String
    status_update_time::UInt64 # ns
    status_lock::Base.ReentrantLock
    const bar::MiniProgressBar
end

function download_artifacts(
        ctx::Context;
        platform::AbstractPlatform = HostPlatform(),
        julia_version = VERSION,
        verbose::Bool = false,
        io::IO = stderr_f(),
        include_lazy::Bool = false
    )
    env = ctx.env
    io = ctx.io
    fancyprint = can_fancyprint(io)
    pkg_info = Tuple{String, Union{Base.UUID, Nothing}}[]
    for (uuid, pkg) in env.manifest
        pkg = manifest_info(env.manifest, uuid)
        pkg_root = source_path(env.manifest_file, pkg, julia_version)
        pkg_root === nothing || push!(pkg_info, (pkg_root, uuid))
    end
    push!(pkg_info, (dirname(env.project_file), env.pkg !== nothing ? env.pkg.uuid : nothing))
    download_jobs = Dict{SHA1, Function}()

    # Check what registries the current pkg server tracks
    # Disable if precompiling to not access internet
    server_registry_info = if Base.JLOptions().incremental == 0
        Registry.pkg_server_registry_info()
    else
        nothing
    end

    print_lock = Base.ReentrantLock() # for non-fancyprint printing

    download_states = Dict{SHA1, DownloadState}()

    errors = Channel{Any}(Inf)
    is_done = Ref{Bool}(false)
    ansi_moveup(n::Int) = string("\e[", n, "A")
    ansi_movecol1 = "\e[1G"
    ansi_cleartoend = "\e[0J"
    ansi_cleartoendofline = "\e[0K"
    ansi_enablecursor = "\e[?25h"
    ansi_disablecursor = "\e[?25l"

    all_collected_artifacts = reduce(
        vcat, map(
            ((pkg_root, pkg_uuid),) ->
            map(ca -> (ca[1], ca[2], pkg_uuid), collect_artifacts(pkg_root; platform, include_lazy)), pkg_info
        )
    )
    used_artifact_tomls = Set{String}(map(ca -> ca[1], all_collected_artifacts))
    longest_name_length = maximum(all_collected_artifacts; init = 0) do (artifacts_toml, artifacts, pkg_uuid)
        maximum(textwidth, keys(artifacts); init = 0)
    end
    for (artifacts_toml, artifacts, pkg_uuid) in all_collected_artifacts
        # For each Artifacts.toml, install each artifact we've collected from it
        for name in keys(artifacts)
            local rname = rpad(name, longest_name_length)
            local hash = SHA1(artifacts[name]["git-tree-sha1"]::String)
            local bar = MiniProgressBar(; header = rname, main = false, indent = 2, color = Base.info_color()::Symbol, mode = :data, always_reprint = true)
            local dstate = DownloadState(:ready, "", time_ns(), Base.ReentrantLock(), bar)
            function progress(total, current; status = "")
                local t = time_ns()
                if isempty(status)
                    dstate.bar.max = total
                    dstate.bar.current = current
                end
                return lock(dstate.status_lock) do
                    dstate.status = status
                    dstate.status_update_time = t
                end
            end
            # Check if the current package is eligible for PkgServer artifact downloads
            local pkg_server_eligible = pkg_uuid !== nothing && Registry.is_pkg_in_pkgserver_registry(pkg_uuid, server_registry_info, ctx.registries)

            # returns a string if exists, or function that downloads the artifact if not
            local ret = ensure_artifact_installed(
                name, artifacts[name], artifacts_toml;
                pkg_server_eligible, verbose, quiet_download = !(usable_io(io)), io, progress
            )
            if ret isa Function
                download_states[hash] = dstate
                download_jobs[hash] =
                    () -> begin
                    try
                        dstate.state = :running
                        ret()
                        if !fancyprint && dstate.bar.max > 1 # if another process downloaded, then max is never set greater than 1
                            @lock print_lock printpkgstyle(io, :Installed, "artifact $rname $(MiniProgressBars.pkg_format_bytes(dstate.bar.max; sigdigits = 1))")
                        end
                    catch
                        dstate.state = :failed
                        rethrow()
                    else
                        dstate.state = :done
                    end
                end
            end
        end
    end

    if !isempty(download_jobs)
        if fancyprint
            t_print = Threads.@spawn begin
                try
                    print(io, ansi_disablecursor)
                    first = true
                    timer = Timer(0, interval = 1 / 10)
                    # TODO: Implement as a new MiniMultiProgressBar
                    main_bar = MiniProgressBar(; indent = 2, header = "Installing artifacts", color = :green, mode = :int, always_reprint = true)
                    main_bar.max = length(download_states)
                    while !is_done[]
                        main_bar.current = count(x -> x.state == :done, values(download_states))
                        local str = sprint(context = io) do iostr
                            first || print(iostr, ansi_cleartoend)
                            n_printed = 1
                            show_progress(iostr, main_bar; carriagereturn = false)
                            println(iostr)
                            for dstate in sort!(collect(values(download_states)), by = v -> v.bar.max, rev = true)
                                local status, status_update_time = lock(() -> (dstate.status, dstate.status_update_time), dstate.status_lock)
                                # only update the bar's status message if it is stalled for at least 0.5 s.
                                # If the new status message is empty, go back to showing the bar without waiting.
                                if isempty(status) || time_ns() - status_update_time > UInt64(500_000_000)
                                    dstate.bar.status = status
                                end
                                dstate.state == :running && (dstate.bar.max > 1000 || !isempty(dstate.bar.status)) || continue
                                show_progress(iostr, dstate.bar; carriagereturn = false)
                                println(iostr)
                                n_printed += 1
                            end
                            is_done[] || print(iostr, ansi_moveup(n_printed), ansi_movecol1)
                            first = false
                        end
                        print(io, str)
                        wait(timer)
                    end
                    print(io, ansi_cleartoend)
                    main_bar.current = count(x -> x[2].state == :done, download_states)
                    show_progress(io, main_bar; carriagereturn = false)
                    println(io)
                catch e
                    e isa InterruptException || rethrow()
                finally
                    print(io, ansi_enablecursor)
                end
            end
            Base.errormonitor(t_print)
        else
            printpkgstyle(io, :Installing, "$(length(download_jobs)) artifacts")
        end
        sema = Base.Semaphore(ctx.num_concurrent_downloads)
        interrupted = Ref{Bool}(false)
        @sync for f in values(download_jobs)
            interrupted[] && break
            Base.acquire(sema)
            Threads.@spawn try
                f()
            catch e
                e isa InterruptException && (interrupted[] = true)
                put!(errors, e)
            finally
                Base.release(sema)
            end
        end
        is_done[] = true
        fancyprint && wait(t_print)
        close(errors)

        if !isempty(errors)
            all_errors = collect(errors)
            local str = sprint(context = io) do iostr
                for e in all_errors
                    Base.showerror(iostr, e)
                    length(all_errors) > 1 && println(iostr)
                end
            end
            pkgerror("Failed to install some artifacts:\n\n$(strip(str, '\n'))")
        end
    end


    return write_env_usage(used_artifact_tomls, "artifact_usage.toml")
end

function check_artifacts_downloaded(pkg_root::String; platform::AbstractPlatform = HostPlatform())
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
        info = Registry.registry_info(reg, reg_pkg)
        repo = info.repo
        repo === nothing && continue
        push!(urls, repo)
    end
    return urls
end


download_source(ctx::Context; readonly = true) = download_source(ctx, values(ctx.env.manifest); readonly)

function download_source(ctx::Context, pkgs; readonly = true)
    pidfile_stale_age = 10 # recommended value is about 3-5x an estimated normal download time (i.e. 2-3s)
    pkgs_to_install = NamedTuple{(:pkg, :urls, :path), Tuple{eltype(pkgs), Set{String}, String}}[]
    for pkg in pkgs
        tracking_registered_version(pkg, ctx.julia_version) || continue
        path = source_path(ctx.env.manifest_file, pkg, ctx.julia_version)
        path === nothing && continue
        if ispath(path) && iswritable(path)
            pidfile = path * ".pid"
        else
            # If the path is not writable, we cannot create a pidfile there so use one in the first depot.
            # (pidlocking probably isn't needed as in this case the package source logically is alredy installed
            # in the readonly depot, but keep the pidfile logic for consistency)
            dir = joinpath(depots1(), "packages", pkg.name)
            mkpath(dir)
            iswritable(dir) || pkgerror("The primary depot is not writable")
            pidfile = joinpath(dir, basename(path) * ".pid")
        end

        FileWatching.mkpidlock(() -> ispath(path), pidfile, stale_age = pidfile_stale_age) && continue
        urls = find_urls(ctx.registries, pkg.uuid)
        push!(pkgs_to_install, (; pkg, urls, path))
    end

    length(pkgs_to_install) == 0 && return Set{UUID}()

    ########################################
    # Install from archives asynchronously #
    ########################################

    missed_packages = eltype(pkgs_to_install)[]
    widths = [textwidth(pkg.name) for (pkg, _) in pkgs_to_install]
    max_name = maximum(widths; init = 0)

    # Check what registries the current pkg server tracks
    # Disable if precompiling to not access internet
    server_registry_info = if Base.JLOptions().incremental == 0
        Registry.pkg_server_registry_info()
    else
        nothing
    end

    # use eager throw version
    Base.Experimental.@sync begin
        jobs = Channel{eltype(pkgs_to_install)}(ctx.num_concurrent_downloads)
        results = Channel(ctx.num_concurrent_downloads)

        @async begin
            for pkg in pkgs_to_install
                put!(jobs, pkg)
            end
        end

        for i in 1:ctx.num_concurrent_downloads # (default 8)
            @async begin
                for (pkg, urls, path) in jobs
                    mkpath(dirname(path)) # the `packages/Package` dir needs to exist for the pidfile to be created
                    FileWatching.mkpidlock(path * ".pid", stale_age = pidfile_stale_age) do
                        if ispath(path)
                            put!(results, (pkg, nothing, (urls, path)))
                            return
                        end
                        if ctx.use_git_for_all_downloads
                            put!(results, (pkg, false, (urls, path)))
                            return
                        end
                        archive_urls = Pair{String, Bool}[]
                        # Check if the current package is available in one of the registries being tracked by the pkg server
                        # In that case, download from the package server
                        if Registry.is_pkg_in_pkgserver_registry(pkg.uuid, server_registry_info, ctx.registries)
                            server, registry_info = server_registry_info
                            url = "$server/package/$(pkg.uuid)/$(pkg.tree_hash)"
                            push!(archive_urls, url => true)
                        end
                        for repo_url in urls
                            url = get_archive_url_for_version(repo_url, pkg.tree_hash)
                            url !== nothing && push!(archive_urls, url => false)
                        end
                        try
                            success = install_archive(archive_urls, pkg.tree_hash, path, io = ctx.io)
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
        end

        bar = MiniProgressBar(;
            indent = 1, header = "Downloading packages", color = Base.info_color(),
            mode = :int, always_reprint = true
        )
        bar.max = length(pkgs_to_install)
        fancyprint = can_fancyprint(ctx.io)
        try
            for i in 1:length(pkgs_to_install)
                pkg::eltype(pkgs), exc_or_success_or_nothing, bt_or_pathurls = take!(results)
                if exc_or_success_or_nothing isa Exception
                    exc = exc_or_success_or_nothing
                    pkgerror("Error when installing package $(pkg.name):\n", sprint(Base.showerror, exc, bt_or_pathurls))
                end
                if exc_or_success_or_nothing === nothing
                    continue # represents when another process did the install
                end
                success, (urls, path) = exc_or_success_or_nothing, bt_or_pathurls
                success || push!(missed_packages, (; pkg, urls, path))
                bar.current = i
                str = sprint(; context = ctx.io) do io
                    if success
                        fancyprint && print_progress_bottom(io)
                        vstr = if pkg.version !== nothing
                            "v$(pkg.version)"
                        else
                            short_treehash = string(pkg.tree_hash)[1:16]
                            "[$short_treehash]"
                        end
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
        FileWatching.mkpidlock(path * ".pid", stale_age = pidfile_stale_age) do
            ispath(path) && return
            install_git(ctx.io, pkg.uuid, pkg.name, pkg.tree_hash, urls, path)
            readonly && set_readonly(path)
            vstr = if pkg.version !== nothing
                "v$(pkg.version)"
            else
                short_treehash = string(pkg.tree_hash)[1:16]
                "[$short_treehash]"
            end
            printpkgstyle(ctx.io, :Installed, string(rpad(pkg.name * " ", max_name + 2, "─"), " ", vstr))
        end
    end

    return Set{UUID}(entry.pkg.uuid for entry in pkgs_to_install)
end

################################
# Manifest update and pruning #
################################

function prune_manifest(env::EnvCache)
    # if project uses another manifest, only prune project entry in manifest
    if isempty(env.workspace) && dirname(env.project_file) != dirname(env.manifest_file)
        proj_entry = env.manifest[env.project.uuid]
        proj_entry.deps = env.project.deps
    else
        keep = Set(values(env.project.deps))
        if env.pkg !== nothing
            push!(keep, env.pkg.uuid)
        end
        for (_, project) in env.workspace
            keep = union(keep, collect(values(project.deps)))
            if project.uuid !== nothing
                push!(keep, project.uuid)
            end
        end
        env.manifest = prune_manifest(env.manifest, keep)
    end
    return env.manifest
end

function prune_manifest(manifest::Manifest, keep::Set{UUID})
    prune_deps(manifest, keep)
    manifest.deps = Dict(uuid => entry for (uuid, entry) in manifest if uuid in keep)
    return manifest
end

function prune_deps(iterator, keep::Set{UUID})
    while !isempty(keep)
        clean = true
        for (uuid, entry) in iterator
            uuid in keep || continue
            for dep in values(entry.deps)
                dep in keep && continue
                push!(keep, dep)
                clean = false
            end
        end
        clean && break
    end
    return
end

function record_project_hash(env::EnvCache)
    return env.manifest.other["project_hash"] = Types.workspace_resolve_hash(env)
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

# TODO: This function should be replaceable with `is_instantiated` but
# see https://github.com/JuliaLang/Pkg.jl/issues/2470
function any_package_not_installed(manifest::Manifest)
    for (uuid, entry) in manifest
        if Base.locate_package(Base.PkgId(uuid, entry.name)) === nothing
            return true
        end
    end
    return false
end

function build(ctx::Context, uuids::Set{UUID}, verbose::Bool; allow_reresolve::Bool = true)
    if any_package_not_installed(ctx.env.manifest) || !isfile(ctx.env.manifest_file)
        Pkg.instantiate(ctx, allow_build = false, allow_autoprecomp = false)
    end
    all_uuids = get_deps(ctx.env, uuids)
    return build_versions(ctx, all_uuids; verbose, allow_reresolve)
end

function dependency_order_uuids(env::EnvCache, uuids::Vector{UUID})::Dict{UUID, Int}
    order = Dict{UUID, Int}()
    seen = UUID[]
    k::Int = 0
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
        return order[uuid] = k += 1
    end
    visit(uuid::String) = visit(UUID(uuid))
    foreach(visit, uuids)
    return order
end

function gen_build_code(build_file::String; inherit_project::Bool = false, add_stdlib::Bool = false)
    code = """
    $(Base.load_path_setup_code(false))
    if $(add_stdlib)
        push!(Base.LOAD_PATH, "@stdlib")
    end
    cd($(repr(dirname(build_file))))
    include($(repr(build_file)))
    """
    # This will make it so that running Pkg.build runs the build in a session with --startup=no
    # *unless* the parent julia session is started with --startup=yes explicitly.
    startup_flag = Base.JLOptions().startupfile == 1 ? "yes" : "no"
    return ```
    $(Base.julia_cmd()) -O0 --color=no --history-file=no
    --startup-file=$startup_flag
    $(inherit_project ? `--project=$(Base.active_project())` : ``)
    --eval $code
    ```
end

with_load_path(f::Function, new_load_path::String) = with_load_path(f, [new_load_path])
function with_load_path(f::Function, new_load_path::Vector{String})
    old_load_path = copy(Base.LOAD_PATH)
    copy!(Base.LOAD_PATH, new_load_path)
    return try
        f()
    finally
        copy!(LOAD_PATH, old_load_path)
    end
end

const PkgUUID = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
pkg_scratchpath() = joinpath(depots1(), "scratchspaces", PkgUUID)

builddir(source_path::String) = joinpath(source_path, "deps")
buildfile(source_path::String) = joinpath(builddir(source_path), "build.jl")
function build_versions(ctx::Context, uuids::Set{UUID}; verbose = false, allow_reresolve::Bool = true)
    # collect builds for UUIDs with `deps/build.jl` files
    builds = Tuple{UUID, String, String, VersionNumber}[]
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
            path = source_path(ctx.env.manifest_file, entry)
            if path === nothing
                pkgerror("Failed to find path for package $name")
            end
            version = something(entry.version, v"0.0")
        end
        ispath(path) || error("Build path for $name does not exist: $path")
        ispath(buildfile(path)) && push!(builds, (uuid, name, path, version))
    end
    # toposort builds by dependencies
    order = dependency_order_uuids(ctx.env, UUID[first(build) for build in builds])
    sort!(builds, by = build -> order[first(build)])
    max_name = maximum(build -> textwidth(build[2]), builds; init = 0)

    bar = MiniProgressBar(;
        indent = 2, header = "Building packages", color = Base.info_color(),
        mode = :int, always_reprint = true
    )
    bar.max = length(builds)
    fancyprint = can_fancyprint(ctx.io)
    fancyprint && start_progress(ctx.io, bar)

    # build each package versions in a child process
    try
        for (n, (uuid, name, source_path, version)) in enumerate(builds)
            pkg = PackageSpec(; uuid = uuid, name = name, version = version)
            build_file = buildfile(source_path)
            # compatibility shim
            local build_project_override, build_project_preferences
            if isfile(projectfile_path(builddir(source_path)))
                build_project_override = nothing
                with_load_path([builddir(source_path), Base.LOAD_PATH...]) do
                    build_project_preferences = Base.get_preferences()
                end
            else
                build_project_override = gen_target_project(ctx, pkg, source_path, "build")
                with_load_path([something(projectfile_path(source_path)), Base.LOAD_PATH...]) do
                    build_project_preferences = Base.get_preferences()
                end
            end

            # Put log output in Pkg's scratchspace if the package is content addressed
            # by tree sha and in the build directory if it is tracked by path etc.
            entry = manifest_info(ctx.env.manifest, uuid)
            if entry !== nothing && entry.tree_hash !== nothing
                key = string(entry.tree_hash)
                scratch = joinpath(pkg_scratchpath(), key)
                mkpath(scratch)
                create_cachedir_tag(joinpath(depots1(), "scratchspaces"))
                log_file = joinpath(scratch, "build.log")
                # Associate the logfile with the package being built
                dict = Dict{String, Any}(
                    scratch => [
                        Dict{String, Any}("time" => Dates.now(), "parent_projects" => [projectfile_path(source_path)]),
                    ]
                )
                open(joinpath(depots1(), "logs", "scratch_usage.toml"), "a") do io
                    TOML.print(io, dict)
                end
            else
                log_file = splitext(build_file)[1] * ".log"
            end

            fancyprint && print_progress_bottom(ctx.io)

            printpkgstyle(
                ctx.io, :Building,
                rpad(name * " ", max_name + 1, "─") * "→ " * pathrepr(log_file)
            )
            bar.current = n - 1

            fancyprint && show_progress(ctx.io, bar)

            let log_file = log_file
                sandbox(ctx, pkg, builddir(source_path), build_project_override; preferences = build_project_preferences, allow_reresolve) do
                    flush(ctx.io)
                    ok = open(log_file, "w") do log
                        std = verbose ? ctx.io : log
                        success(
                            pipeline(
                                gen_build_code(buildfile(source_path)),
                                stdout = std, stderr = std
                            )
                        )
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
        name == "julia" || name in keys(ctx.env.project.deps) || name in keys(ctx.env.project.extras) || name in keys(ctx.env.project.weakdeps)
    end
    filter!(ctx.env.project.sources) do (name, _)
        name in keys(ctx.env.project.deps) || name in keys(ctx.env.project.extras)
    end
    deps_names = union(keys(ctx.env.project.deps), keys(ctx.env.project.extras))
    filter!(ctx.env.project.targets) do (target, deps)
        !isempty(filter!(in(deps_names), deps))
    end
    # only keep reachable manifest entries
    prune_manifest(ctx.env)
    record_project_hash(ctx.env)
    # update project & manifest
    write_env(ctx.env)
    return show_update(ctx.env, ctx.registries; io = ctx.io)
end

update_package_add(ctx::Context, pkg::PackageSpec, ::Nothing, is_dep::Bool) = pkg
function update_package_add(ctx::Context, pkg::PackageSpec, entry::PackageEntry, is_dep::Bool)
    if entry.pinned
        if pkg.version == VersionSpec()
            println(ctx.io, "`$(pkg.name)` is pinned at `v$(entry.version)`: maintaining pinned version")
        end
        return PackageSpec(;
            uuid = pkg.uuid, name = pkg.name, pinned = true,
            version = entry.version, tree_hash = entry.tree_hash,
            path = entry.path, repo = entry.repo
        )
    end
    if entry.path !== nothing || entry.repo.source !== nothing || pkg.repo.source !== nothing
        return pkg # overwrite everything, nothing to copy over
    end
    if is_stdlib(pkg.uuid, ctx.julia_version)
        return pkg # stdlibs are not versioned like other packages
    elseif is_dep && (
            (isa(pkg.version, VersionNumber) && entry.version == pkg.version) ||
                (!isa(pkg.version, VersionNumber) && entry.version ∈ pkg.version)
        )
        # leave the package as is at the installed version
        return PackageSpec(;
            uuid = pkg.uuid, name = pkg.name, version = entry.version,
            tree_hash = entry.tree_hash
        )
    end
    # adding a new version not compatible with the old version, so we just overwrite
    return pkg
end

# Update registries AND read them back in.
function update_registries(ctx::Context; force::Bool = true, kwargs...)
    OFFLINE_MODE[] && return
    !force && UPDATED_REGISTRY_THIS_SESSION[] && return
    Registry.update(; io = ctx.io, kwargs...)
    copy!(ctx.registries, Registry.reachable_registries())
    return UPDATED_REGISTRY_THIS_SESSION[] = true
end

function is_all_registered(registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec})
    pkgs = filter(tracking_registered_version, pkgs)
    for pkg in pkgs
        if !any(r -> haskey(r, pkg.uuid), registries)
            return pkg
        end
    end
    return true
end

function check_registered(registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec})
    if isempty(registries) && !isempty(pkgs)
        registry_pkgs = filter(tracking_registered_version, pkgs)
        if !isempty(registry_pkgs)
            pkgerror("no registries have been installed. Cannot resolve the following packages:\n$(join(map(pkg -> "  " * err_rep(pkg), registry_pkgs), "\n"))")
        end
    end
    pkg = is_all_registered(registries, pkgs)
    if pkg isa PackageSpec
        msg = "expected package $(err_rep(pkg)) to be registered"
        # check if the name exists in the registry with a different uuid
        if pkg.name !== nothing
            reg_uuid = Pair{String, Vector{UUID}}[]
            for reg in registries
                uuids = Registry.uuids_from_name(reg, pkg.name)
                if !isempty(uuids)
                    push!(reg_uuid, reg.name => uuids)
                end
            end
            if !isempty(reg_uuid)
                msg *= "\n You may have provided the wrong UUID for package $(pkg.name).\n Found the following UUIDs for that name:"
                for (reg, uuids) in reg_uuid
                    msg *= "\n  - $(join(uuids, ", ")) from registry: $reg"
                end
            end
        end
        pkgerror(msg)
    end
    return nothing
end

# Check if the package can be added without colliding/overwriting things
function assert_can_add(ctx::Context, pkgs::Vector{PackageSpec})
    for pkg in pkgs
        @assert pkg.name !== nothing && pkg.uuid !== nothing
        # package with the same name exist in the project: assert that they have the same uuid
        existing_uuid = get(ctx.env.project.deps, pkg.name, pkg.uuid)
        existing_uuid == pkg.uuid ||
            pkgerror(
            """Refusing to add package $(err_rep(pkg)).
            Package `$(pkg.name)=$(existing_uuid)` with the same name already exists as a direct dependency.
            To remove the existing package, use `$(Pkg.in_repl_mode() ? """pkg> rm $(pkg.name)""" : """import Pkg; Pkg.rm("$(pkg.name)")""")`.
            """
        )
        # package with the same uuid exist in the project: assert they have the same name
        name = findfirst(==(pkg.uuid), ctx.env.project.deps)
        name === nothing || name == pkg.name ||
            pkgerror(
            """Refusing to add package $(err_rep(pkg)).
            Package `$name=$(pkg.uuid)` with the same UUID already exists as a direct dependency.
            To remove the existing package, use `$(Pkg.in_repl_mode() ? """pkg> rm $name""" : """import Pkg; Pkg.rm("$name")""")`.
            """
        )
        # package with the same uuid exist in the manifest: assert they have the same name
        entry = get(ctx.env.manifest, pkg.uuid, nothing)
        entry === nothing || entry.name == pkg.name ||
            pkgerror(
            """Refusing to add package $(err_rep(pkg)).
            Package `$(entry.name)=$(pkg.uuid)` with the same UUID already exists in the manifest.
            To remove the existing package, use `$(Pkg.in_repl_mode() ? """pkg> rm --manifest $(entry.name)=$(pkg.uuid)""" : """import Pkg; Pkg.rm(Pkg.PackageSpec(uuid="$(pkg.uuid)"); mode=Pkg.PKGMODE_MANIFEST)""")`.
            """
        )
    end
    return
end

function tiered_resolve(
        env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, julia_version,
        try_all_installed::Bool
    )
    if try_all_installed
        try # do not modify existing subgraph and only add installed versions of the new packages
            @debug "tiered_resolve: trying PRESERVE_ALL_INSTALLED"
            return targeted_resolve(env, registries, pkgs, PRESERVE_ALL_INSTALLED, julia_version)
        catch err
            err isa Resolve.ResolverError || rethrow()
        end
    end
    try # do not modify existing subgraph
        @debug "tiered_resolve: trying PRESERVE_ALL"
        return targeted_resolve(env, registries, pkgs, PRESERVE_ALL, julia_version)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try # do not modify existing direct deps
        @debug "tiered_resolve: trying PRESERVE_DIRECT"
        return targeted_resolve(env, registries, pkgs, PRESERVE_DIRECT, julia_version)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    try
        @debug "tiered_resolve: trying PRESERVE_SEMVER"
        return targeted_resolve(env, registries, pkgs, PRESERVE_SEMVER, julia_version)
    catch err
        err isa Resolve.ResolverError || rethrow()
    end
    @debug "tiered_resolve: trying PRESERVE_NONE"
    return targeted_resolve(env, registries, pkgs, PRESERVE_NONE, julia_version)
end

function targeted_resolve(env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, preserve::PreserveLevel, julia_version)
    if preserve == PRESERVE_ALL || preserve == PRESERVE_ALL_INSTALLED
        pkgs = load_all_deps(env, pkgs; preserve)
    else
        pkgs = load_direct_deps(env, pkgs; preserve)
    end
    check_registered(registries, pkgs)

    deps_map = resolve_versions!(env, registries, pkgs, julia_version, preserve == PRESERVE_ALL_INSTALLED)
    return pkgs, deps_map
end

function _resolve(
        io::IO, env::EnvCache, registries::Vector{Registry.RegistryInstance},
        pkgs::Vector{PackageSpec}, preserve::PreserveLevel, julia_version
    )
    usingstrategy = preserve != PRESERVE_TIERED ? " using $preserve" : ""
    printpkgstyle(io, :Resolving, "package versions$(usingstrategy)...")
    return try
        if preserve == PRESERVE_TIERED_INSTALLED
            tiered_resolve(env, registries, pkgs, julia_version, true)
        elseif preserve == PRESERVE_TIERED
            tiered_resolve(env, registries, pkgs, julia_version, false)
        else
            targeted_resolve(env, registries, pkgs, preserve, julia_version)
        end
    catch err

        if err isa Resolve.ResolverError
            yanked_pkgs = filter(pkg -> is_pkgversion_yanked(pkg, registries), load_all_deps(env))
            if !isempty(yanked_pkgs)
                indent = " "^(Pkg.pkgstyle_indent)
                yanked_str = join(map(pkg -> indent * "   - " * err_rep(pkg, quotes = false) * " " * string(pkg.version), yanked_pkgs), "\n")
                printpkgstyle(io, :Warning, """The following package versions were yanked from their registry and \
                are not resolvable:\n$yanked_str""", color = Base.warn_color())
            end
        end
        rethrow()
    end
end

function can_skip_resolve_for_add(pkg::PackageSpec, entry::Union{PackageEntry, Nothing})
    # Can't skip if package not in manifest
    entry === nothing && return false

    # Can't skip if pinned (needs special handling in resolution)
    entry.pinned && return false

    # Can't skip if tracking path or repo
    (entry.path !== nothing || entry.repo.source !== nothing || pkg.repo.source !== nothing) && return false

    # Check if requested version is compatible with installed version
    version_compatible = if isa(pkg.version, VersionNumber)
        entry.version == pkg.version
    elseif pkg.version == VersionSpec()
        # No version specified, current version is acceptable
        true
    else
        # VersionSpec range specified, check if current version is in range
        entry.version ∈ pkg.version
    end

    return version_compatible
end

function add_compat_entries!(ctx::Context, pkgs::Vector{PackageSpec})
    # Only add compat entries if env is a package
    ctx.env.pkg === nothing && return

    compat_names = String[]
    for pkg in pkgs
        haskey(ctx.env.project.compat, pkg.name) && continue
        v = ctx.env.manifest[pkg.uuid].version
        v === nothing && continue
        pkgversion = string(Base.thispatch(v))
        set_compat(ctx.env.project, pkg.name, pkgversion)
        push!(compat_names, pkg.name)
    end
    if !isempty(compat_names)
        printpkgstyle(ctx.io, :Compat, "entries added for $(join(compat_names, ", "))")
    end
    return
end

function add(
        ctx::Context, pkgs::Vector{PackageSpec}, new_git = Set{UUID}();
        allow_autoprecomp::Bool = true, preserve::PreserveLevel = default_preserve(), platform::AbstractPlatform = HostPlatform(),
        target::Symbol = :deps
    )
    assert_can_add(ctx, pkgs)
    # load manifest data
    pkg_entries = Tuple{PackageSpec, Union{PackageEntry, Nothing}, Bool}[]
    for (i, pkg) in pairs(pkgs)
        delete!(ctx.env.project.weakdeps, pkg.name)
        entry = manifest_info(ctx.env.manifest, pkg.uuid)
        is_dep = any(uuid -> uuid == pkg.uuid, [uuid for (name, uuid) in ctx.env.project.deps])
        push!(pkg_entries, (pkg, entry, is_dep))
        pkgs[i] = update_package_add(ctx, pkg, entry, is_dep)
    end

    names = (p.name for p in pkgs)
    target_field = if target == :deps
        ctx.env.project.deps
    elseif target == :weakdeps
        ctx.env.project.weakdeps
    elseif target == :extras
        ctx.env.project.extras
    else
        pkgerror("Unrecognized target $(target)")
    end

    # Check if we can skip resolution for all packages
    can_skip_all = target == :deps && all(pkg_entries) do (pkg, entry, _)
        can_skip_resolve_for_add(pkg, entry)
    end

    if can_skip_all
        # All packages are already in manifest with compatible versions
        # Just promote to direct dependencies without resolving
        foreach(pkg -> target_field[pkg.name] = pkg.uuid, pkgs) # update set of deps/weakdeps/extras

        # if env is a package add compat entries
        add_compat_entries!(ctx, pkgs)

        record_project_hash(ctx.env)
        write_env(ctx.env)
        show_update(ctx.env, ctx.registries; io = ctx.io)

        return
    end

    foreach(pkg -> target_field[pkg.name] = pkg.uuid, pkgs) # update set of deps/weakdeps/extras

    if target == :deps # nothing to resolve/install if it's weak or extras
        # resolve
        man_pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, preserve, ctx.julia_version)
        update_manifest!(ctx.env, man_pkgs, deps_map, ctx.julia_version, ctx.registries)
        new_apply = download_source(ctx)
        fixups_from_projectfile!(ctx)

        # After downloading resolutionary packages, search for (Julia)Artifacts.toml files
        # and ensure they are all downloaded and unpacked as well:
        download_artifacts(ctx, platform = platform, julia_version = ctx.julia_version)

        # if env is a package add compat entries
        add_compat_entries!(ctx, pkgs)
        record_project_hash(ctx.env) # compat entries changed the hash after it was last recorded in update_manifest!

        write_env(ctx.env) # write env before building
        show_update(ctx.env, ctx.registries; io = ctx.io)
        build_versions(ctx, union(new_apply, new_git))
        allow_autoprecomp && Pkg._auto_precompile(ctx, pkgs)
    else
        record_project_hash(ctx.env)
        write_env(ctx.env)
        names_str = join(names, ", ")
        printpkgstyle(ctx.io, :Added, "$names_str to [$(target)]")
    end
    return
end

# Input: name, uuid, and path
function develop(
        ctx::Context, pkgs::Vector{PackageSpec}, new_git::Set{UUID};
        preserve::PreserveLevel = default_preserve(), platform::AbstractPlatform = HostPlatform()
    )
    assert_can_add(ctx, pkgs)
    # no need to look at manifest.. dev will just nuke whatever is there before
    for pkg in pkgs
        delete!(ctx.env.project.weakdeps, pkg.name)
        ctx.env.project.deps[pkg.name] = pkg.uuid
    end
    # resolve & apply package versions
    pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, preserve, ctx.julia_version)
    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version, ctx.registries)
    new_apply = download_source(ctx)
    fixups_from_projectfile!(ctx)
    download_artifacts(ctx; platform = platform, julia_version = ctx.julia_version)
    write_env(ctx.env) # write env before building
    show_update(ctx.env, ctx.registries; io = ctx.io)
    return build_versions(ctx, union(new_apply, new_git))
end

# load version constraint
# if version isa VersionNumber -> set tree_hash too
up_load_versions!(ctx::Context, pkg::PackageSpec, ::Nothing, source_path, source_repo, level::UpgradeLevel) = false
function up_load_versions!(ctx::Context, pkg::PackageSpec, entry::PackageEntry, source_path, source_repo, level::UpgradeLevel)
    # With [sources], `pkg` can have a path or repo here
    entry.version !== nothing || return false # no version to set
    if entry.pinned || level == UPLEVEL_FIXED
        pkg.version = entry.version
        if pkg.path === nothing
            pkg.tree_hash = entry.tree_hash
        end
    elseif source_path === nothing && pkg.path === nothing && (entry.repo.source !== nothing || source_repo.source !== nothing) # repo packages have a version but are treated specially
        if source_repo.source !== nothing
            pkg.repo = source_repo
        else
            pkg.repo = entry.repo
        end
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
    # Only restore repo from manifest if we don't already have a path set
    if pkg.repo == GitRepo() && pkg.path === nothing
        pkg.repo = entry.repo # TODO check that repo is same
    end
    # Only set path if tree_hash is not already set (to avoid invalid state where both are set)
    if pkg.path === nothing && pkg.repo == GitRepo() && pkg.tree_hash === nothing
        pkg.path = entry.path
    end
    return pkg.pinned = entry.pinned
    # `pkg.version` and `pkg.tree_hash` is set by `up_load_versions!`
end


function load_manifest_deps_up(
        env::EnvCache, pkgs::Vector{PackageSpec} = PackageSpec[];
        preserve::PreserveLevel = PRESERVE_ALL
    )
    manifest = env.manifest
    project = env.project
    explicit_upgraded = Set(pkg.uuid for pkg in pkgs)

    recursive_indirect_dependencies_of_explicitly_upgraded = Set{UUID}()
    frontier = copy(explicit_upgraded)
    new_frontier = Set{UUID}()
    while !(isempty(frontier))
        for uuid in frontier
            entry = get(env.manifest, uuid, nothing)
            entry === nothing && continue
            uuid_deps = values(entry.deps)
            for uuid_dep in uuid_deps
                if !(uuid_dep in recursive_indirect_dependencies_of_explicitly_upgraded) #
                    push!(recursive_indirect_dependencies_of_explicitly_upgraded, uuid_dep)
                    push!(new_frontier, uuid_dep)
                end
            end
        end
        copy!(frontier, new_frontier)
        empty!(new_frontier)
    end

    pkgs = copy(pkgs)
    for (uuid, entry) in manifest
        findfirst(pkg -> pkg.uuid == uuid, pkgs) === nothing || continue # do not duplicate packages
        uuid in explicit_upgraded && continue # Allow explicit upgraded packages to upgrade.
        if preserve == PRESERVE_NONE && uuid in recursive_indirect_dependencies_of_explicitly_upgraded
            continue
        elseif preserve == PRESERVE_DIRECT && uuid in recursive_indirect_dependencies_of_explicitly_upgraded && !(uuid in values(project.deps))
            continue
        end

        # The rest of the packages get fixed
        push!(
            pkgs, PackageSpec(
                uuid = uuid,
                name = entry.name,
                path = entry.path,
                pinned = entry.pinned,
                repo = entry.repo,
                tree_hash = entry.tree_hash, # TODO should tree_hash be changed too?
                version = something(entry.version, VersionSpec()),
            )
        )
    end
    return pkgs
end

function targeted_resolve_up(env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec}, preserve::PreserveLevel, julia_version)
    pkgs = load_manifest_deps_up(env, pkgs; preserve = preserve)
    check_registered(registries, pkgs)
    deps_map = resolve_versions!(env, registries, pkgs, julia_version, preserve == PRESERVE_ALL_INSTALLED)
    return pkgs, deps_map
end

function up(
        ctx::Context, pkgs::Vector{PackageSpec}, level::UpgradeLevel;
        skip_writing_project::Bool = false, preserve::Union{Nothing, PreserveLevel} = nothing
    )

    requested_pkgs = pkgs

    new_git = Set{UUID}()
    # TODO check all pkg.version == VersionSpec()
    # set version constraints according to `level`
    for pkg in pkgs
        source_path, source_repo = get_path_repo(ctx.env.project, ctx.env.project_file, ctx.env.manifest_file, pkg.name)
        entry = manifest_info(ctx.env.manifest, pkg.uuid)
        new = up_load_versions!(ctx, pkg, entry, source_path, source_repo, level)
        new && push!(new_git, pkg.uuid) #TODO put download + push! in utility function
    end
    # load rest of manifest data (except for version info)
    for pkg in pkgs
        entry = manifest_info(ctx.env.manifest, pkg.uuid)
        up_load_manifest_info!(pkg, entry)
    end
    if preserve !== nothing
        pkgs, deps_map = targeted_resolve_up(ctx.env, ctx.registries, pkgs, preserve, ctx.julia_version)
    else
        pkgs = load_direct_deps(ctx.env, pkgs; preserve = (level == UPLEVEL_FIXED ? PRESERVE_NONE : PRESERVE_DIRECT))
        check_registered(ctx.registries, pkgs)
        deps_map = resolve_versions!(ctx.env, ctx.registries, pkgs, ctx.julia_version, false)
    end
    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version, ctx.registries)
    new_apply = download_source(ctx)
    fixups_from_projectfile!(ctx)
    download_artifacts(ctx, julia_version = ctx.julia_version)
    write_env(ctx.env; skip_writing_project) # write env before building
    show_update(ctx.env, ctx.registries; io = ctx.io, hidden_upgrades_info = true)

    if length(requested_pkgs) == 1
        pkg = only(requested_pkgs)
        entry = manifest_info(ctx.env.manifest, pkg.uuid)
        if entry === nothing || (entry.path === nothing && entry.repo.source === nothing)
            # Get current version after the update
            current_version = entry !== nothing ? entry.version : nothing
            original_entry = manifest_info(ctx.env.original_manifest, pkg.uuid)
            original_version = original_entry !== nothing ? original_entry.version : nothing

            # Check if version didn't change and there's a newer version available
            if current_version == original_version && current_version !== nothing
                temp_pkg = PackageSpec(name = pkg.name, uuid = pkg.uuid, version = current_version)
                cinfo = status_compat_info(temp_pkg, ctx.env, ctx.registries)
                if cinfo !== nothing
                    packages_holding_back, max_version, max_version_compat = cinfo
                    if current_version < max_version
                        printpkgstyle(
                            ctx.io, :Info, "$(pkg.name) can be updated but at the cost of upgrading/downgrading other packages. " *
                                "To force upgrade to the latest version, try `add $(pkg.name)@$(max_version)`", color = Base.info_color()
                        )
                    end
                end
            end
        end
    end

    return build_versions(ctx, union(new_apply, new_git))
end

function update_package_pin!(ctx::Context, pkg::PackageSpec, entry::Union{Nothing, PackageEntry})
    if entry === nothing
        cmd = Pkg.in_repl_mode() ? "pkg> resolve" : "Pkg.resolve()"
        pkgerror("package $(err_rep(pkg)) not found in the manifest, run `$cmd` and retry.")
    end
    registries = ctx.registries

    #if entry.pinned && pkg.version == VersionSpec()
    #    println(ctx.io, "package $(err_rep(pkg)) already pinned")
    #end
    # update pinned package
    pkg.pinned = true
    if is_stdlib(pkg.uuid, ctx.julia_version)
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
                pkgerror("unable to pin unregistered package $(err_rep(pkg)) to an arbitrary version")
            end
        end
    end
end

is_fully_pinned(ctx::Context) = !isempty(ctx.env.manifest.deps) && all(kv -> last(kv).pinned, ctx.env.manifest.deps)

function pin(ctx::Context, pkgs::Vector{PackageSpec})
    foreach(pkg -> update_package_pin!(ctx, pkg, manifest_info(ctx.env.manifest, pkg.uuid)), pkgs)
    pkgs = load_direct_deps(ctx.env, pkgs)

    # TODO: change pin to not take a version and just have it pin on the current version. Then there is no need to resolve after a pin
    pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, PRESERVE_TIERED, ctx.julia_version)

    update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version, ctx.registries)
    new = download_source(ctx)
    fixups_from_projectfile!(ctx)
    download_artifacts(ctx; julia_version = ctx.julia_version)
    write_env(ctx.env) # write env before building
    show_update(ctx.env, ctx.registries; io = ctx.io)
    return build_versions(ctx, new)
end

function update_package_free!(registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec, entry::PackageEntry, err_if_free::Bool)
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
    if err_if_free
        pkgerror(
            "expected package $(err_rep(pkg)) to be pinned, tracking a path,",
            " or tracking a repository"
        )
    end
    return
end

# TODO: this is two technically different operations with the same name
# split into two subfunctions ...
function free(ctx::Context, pkgs::Vector{PackageSpec}; err_if_free = true)
    for pkg in pkgs
        entry = manifest_info(ctx.env.manifest, pkg.uuid)
        delete!(ctx.env.project.sources, pkg.name)
        update_package_free!(ctx.registries, pkg, entry, err_if_free)
    end

    return if any(pkg -> pkg.version == VersionSpec(), pkgs)
        pkgs = load_direct_deps(ctx.env, pkgs)
        check_registered(ctx.registries, pkgs)

        # TODO: change free to not take a version and just have it pin on the current version. Then there is no need to resolve after a pin
        pkgs, deps_map = _resolve(ctx.io, ctx.env, ctx.registries, pkgs, PRESERVE_TIERED, ctx.julia_version)

        update_manifest!(ctx.env, pkgs, deps_map, ctx.julia_version, ctx.registries)
        new = download_source(ctx)
        fixups_from_projectfile!(ctx)
        download_artifacts(ctx)
        write_env(ctx.env) # write env before building
        show_update(ctx.env, ctx.registries; io = ctx.io)
        build_versions(ctx, new)
    else
        foreach(pkg -> manifest_info(ctx.env.manifest, pkg.uuid).pinned = false, pkgs)
        write_env(ctx.env)
        show_update(ctx.env, ctx.registries; io = ctx.io)
    end
end

function gen_test_code(source_path::String; test_args::Cmd)
    test_file = testfile(source_path)
    return """
    $(Base.load_path_setup_code(false))
    cd($(repr(dirname(test_file))))
    append!(empty!(ARGS), $(repr(test_args.exec)))
    include($(repr(test_file)))
    """
end


function get_threads_spec()
    return if haskey(ENV, "JULIA_NUM_THREADS")
        if isempty(ENV["JULIA_NUM_THREADS"])
            throw(ArgumentError("JULIA_NUM_THREADS is set to an empty string. It is not clear what Pkg.test should set for `-t` on the test worker."))
        end
        # if set, prefer JULIA_NUM_THREADS because this is passed to the test worker via --threads
        # which takes precedence in the worker
        ENV["JULIA_NUM_THREADS"]
    elseif Threads.nthreads(:interactive) > 0
        "$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
    else
        "$(Threads.nthreads(:default))"
    end
end

function gen_subprocess_flags(source_path::String; coverage, julia_args::Cmd)
    coverage_arg = if coverage isa Bool
        # source_path is the package root, not "src" so "ext" etc. is included
        coverage ? string("@", source_path) : "none"
    elseif coverage isa AbstractString
        coverage
    else
        throw(ArgumentError("coverage should be a boolean or a string."))
    end
    return ```
        --code-coverage=$(coverage_arg)
        --color=$(Base.have_color === nothing ? "auto" : Base.have_color ? "yes" : "no")
        --warn-overwrite=yes
        --depwarn=$(Base.JLOptions().depwarn == 2 ? "error" : "yes")
        --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
        --startup-file=$(Base.JLOptions().startupfile == 1 ? "yes" : "no")
        --track-allocation=$(("none", "user", "all")[Base.JLOptions().malloc_log + 1])
        $(julia_args)
    ```
end

function with_temp_env(fn::Function, temp_env::String)
    load_path = copy(LOAD_PATH)
    active_project = Base.ACTIVE_PROJECT[]
    return try
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
        env.manifest[env.pkg.uuid] = PackageEntry(;
            name = env.pkg.name, path = dirname(env.project_file),
            deps = env.project.deps
        )
    end
    # if the source manifest is an old format, upgrade the manifest_format so
    # that warnings aren't thrown for the temp sandbox manifest
    if env.manifest.manifest_format < v"2.0"
        env.manifest.manifest_format = v"2.0"
    end
    # preserve important nodes
    project = read_project(test_project)
    keep = Set([target.uuid])
    union!(keep, values(project.deps))
    record_project_hash(env)
    # prune and return
    return prune_manifest(env.manifest, keep)
end

function abspath!(env::EnvCache, manifest::Manifest)
    for (uuid, entry) in manifest
        if entry.path !== nothing
            entry.path = manifest_rel_path(env, entry.path)
        end
    end
    return manifest
end

function abspath!(env::EnvCache, project::Project)
    for (key, entry) in project.sources
        if haskey(entry, "path")
            # Paths in project sources are project-relative, so join with project_file dir, not manifest_file dir
            entry["path"] = normpath(joinpath(dirname(env.project_file), entry["path"]))
        end
    end
    return project
end

# ctx + pkg used to compute parent dep graph
function sandbox(
        fn::Function, ctx::Context, target::PackageSpec,
        sandbox_path::String, sandbox_project_override;
        preferences::Union{Nothing, Dict{String, Any}} = nothing,
        force_latest_compatible_version::Bool = false,
        allow_earlier_backwards_compatible_versions::Bool = true,
        allow_reresolve::Bool = true
    )
    sandbox_project = projectfile_path(sandbox_path)

    return mktempdir() do tmp
        tmp_project = projectfile_path(tmp)
        tmp_manifest = manifestfile_path(tmp)
        tmp_preferences = joinpath(tmp, first(Base.preferences_names))

        # Copy env info over to temp env
        has_sandbox_project = false
        if sandbox_project_override === nothing
            if isfile(sandbox_project)
                sandbox_project_override = read_project(sandbox_project)
                has_sandbox_project = true
            else
                sandbox_project_override = Project()
            end
        end
        if !has_sandbox_project
            abspath!(ctx.env, sandbox_project_override)
        end
        Types.write_project(sandbox_project_override, tmp_project)

        # create merged manifest
        # - copy over active subgraph
        # - abspath! to maintain location of all deved nodes
        working_manifest = sandbox_preserve(ctx.env, target, tmp_project)
        abspath!(ctx.env, working_manifest)

        # - copy over fixed subgraphs from test subgraph
        # really only need to copy over "special" nodes
        sandbox_env = Types.EnvCache(projectfile_path(sandbox_path))
        abspath!(sandbox_env, sandbox_env.manifest)
        abspath!(sandbox_env, sandbox_env.project)
        for (uuid, entry) in sandbox_env.manifest.deps
            entry_working = get(working_manifest, uuid, nothing)
            if entry_working === nothing
                working_manifest[uuid] = entry
            else # Check for collision between the sandbox manifest and the "parent" manifest
                if entry_working != entry && (ctx.env.pkg !== nothing && ctx.env.pkg.uuid != uuid)
                    @warn "Entry in manifest at \"$sandbox_path\" for package \"$(entry_working.name)\" differs from that in \"$(ctx.env.manifest_file)\""
                else
                    working_manifest[uuid] = entry
                end
            end
        end

        Types.write_manifest(working_manifest, tmp_manifest)
        # Copy over preferences
        if preferences !== nothing
            open(tmp_preferences, "w") do io
                TOML.print(io, preferences::Dict{String, Any})
            end
        end

        # sandbox
        with_temp_env(tmp) do
            temp_ctx = Context()
            if has_sandbox_project
                abspath!(sandbox_env, temp_ctx.env.project)
            end
            temp_ctx.env.project.deps[target.name] = target.uuid

            if force_latest_compatible_version
                apply_force_latest_compatible_version!(
                    temp_ctx;
                    target_name = target.name,
                    allow_earlier_backwards_compatible_versions,
                )
            end

            try
                Pkg.resolve(temp_ctx; io = devnull, skip_writing_project = true)
                @debug "Using _parent_ dep graph"
            catch err # TODO
                err isa Resolve.ResolverError || rethrow()
                allow_reresolve || rethrow()
                @debug err
                msg = string(
                    "Could not use exact versions of packages in manifest, re-resolving. ",
                    "Note: if you do not check your manifest file into source control, ",
                    "then you can probably ignore this message. ",
                    "However, if you do check your manifest file into source control, ",
                    "then you probably want to pass the `allow_reresolve = false` kwarg ",
                    "when calling the `Pkg.test` function.",
                )
                printpkgstyle(ctx.io, :Test, msg, color = Base.warn_color())
                Pkg.update(temp_ctx; skip_writing_project = true, update_registry = false, io = ctx.io)
                printpkgstyle(ctx.io, :Test, "Successfully re-resolved")
                @debug "Using _clean_ dep graph"
            end

            reset_all_compat!(temp_ctx.env.project)
            write_env(temp_ctx.env, update_undo = false)

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
function gen_target_project(ctx::Context, pkg::PackageSpec, source_path::String, target::String)
    env = ctx.env
    registries = ctx.registries
    test_project = Types.Project()
    if projectfile_path(source_path; strict = true) === nothing
        # no project file, assuming this is an old REQUIRE package
        test_project.deps = copy(env.manifest[pkg.uuid].deps)
        if target == "test"
            test_REQUIRE_path = joinpath(source_path, "test", "REQUIRE")
            if isfile(test_REQUIRE_path)
                @warn "using test/REQUIRE files is deprecated and current support is lacking in some areas"
                test_pkgs = parse_REQUIRE(test_REQUIRE_path)
                package_specs = [PackageSpec(name = pkg) for pkg in test_pkgs]
                registry_resolve!(registries, package_specs)
                stdlib_resolve!(package_specs)
                ensure_resolved(ctx, env.manifest, package_specs, registry = true)
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
    test_project.sources = source_env.project.sources
    # collect test dependencies
    for name in get(source_env.project.targets, target, String[])
        uuid = nothing
        for list in [source_env.project.extras, source_env.project.weakdeps]
            uuid = get(list, name, nothing)
            uuid === nothing || break
        end
        if uuid === nothing
            pkgerror("`$name` declared as a `$target` dependency, but no such entry in `extras` or `weakdeps`")
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
function test(
        ctx::Context, pkgs::Vector{PackageSpec};
        coverage = false, julia_args::Cmd = ``, test_args::Cmd = ``,
        test_fn = nothing,
        force_latest_compatible_version::Bool = false,
        allow_earlier_backwards_compatible_versions::Bool = true,
        allow_reresolve::Bool = true
    )
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
    source_paths = String[] # source_path is the package root (not /src)
    for pkg in pkgs
        sourcepath = source_path(ctx.env.manifest_file, pkg, ctx.julia_version)
        !isfile(testfile(sourcepath)) && push!(missing_runtests, pkg.name)
        push!(source_paths, sourcepath)
    end
    if !isempty(missing_runtests)
        pkgerror(
            length(missing_runtests) == 1 ? "Package " : "Packages ",
            join(missing_runtests, ", "),
            " did not provide a `test/runtests.jl` file"
        )
    end

    # sandbox
    pkgs_errored = Tuple{String, Base.Process}[]
    for (pkg, source_path) in zip(pkgs, source_paths)
        # TODO: DRY with code below.
        # If the test is in the our "workspace", no need to create a temp env etc, just activate and run thests
        if testdir(source_path) in dirname.(keys(ctx.env.workspace))
            proj = Base.locate_project_file(abspath(testdir(source_path)))
            env = EnvCache(proj)
            # Instantiate test env
            Pkg.instantiate(Context(env = env); allow_autoprecomp = false)
            status(env, ctx.registries; mode = PKGMODE_COMBINED, io = ctx.io, ignore_indent = false, show_usagetips = false)
            flags = gen_subprocess_flags(source_path; coverage, julia_args)

            if should_autoprecompile()
                cacheflags = parse(CacheFlags, read(`$(Base.julia_cmd()) $(flags) --eval 'show(Base.CacheFlags())'`, String))
                # Don't warn about already loaded packages, since we are going to run tests in a new
                # subprocess anyway.
                Pkg.precompile(; io = ctx.io, warn_loaded = false, configs = flags => cacheflags)
            end

            printpkgstyle(ctx.io, :Testing, "Running tests...")
            flush(ctx.io)
            code = gen_test_code(source_path; test_args)
            cmd = `$(Base.julia_cmd()) $(flags) --eval $code`

            path_sep = Sys.iswindows() ? ';' : ':'
            p, interrupted = withenv("JULIA_LOAD_PATH" => "@$(path_sep)$(testdir(source_path))", "JULIA_PROJECT" => nothing) do
                subprocess_handler(cmd, ctx.io, "Tests interrupted. Exiting the test process")
            end
            if success(p)
                printpkgstyle(ctx.io, :Testing, pkg.name * " tests passed ")
            elseif !interrupted
                push!(pkgs_errored, (pkg.name, p))
            end
            continue
        end

        # compatibility shim between "targets" and "test/Project.toml"
        local test_project_preferences, test_project_override
        if isfile(projectfile_path(testdir(source_path)))
            test_project_override = nothing
            with_load_path([testdir(source_path), Base.LOAD_PATH...]) do
                test_project_preferences = Base.get_preferences()
            end
        else
            test_project_override = gen_target_project(ctx, pkg, source_path, "test")
            with_load_path([something(projectfile_path(source_path)), Base.LOAD_PATH...]) do
                test_project_preferences = Base.get_preferences()
            end
        end
        # now we sandbox
        printpkgstyle(ctx.io, :Testing, pkg.name)
        sandbox(ctx, pkg, testdir(source_path), test_project_override; preferences = test_project_preferences, force_latest_compatible_version, allow_earlier_backwards_compatible_versions, allow_reresolve) do
            test_fn !== nothing && test_fn()
            sandbox_ctx = Context(; io = ctx.io)
            status(sandbox_ctx.env, sandbox_ctx.registries; mode = PKGMODE_COMBINED, io = sandbox_ctx.io, ignore_indent = false, show_usagetips = false)
            flags = gen_subprocess_flags(source_path; coverage, julia_args)

            if should_autoprecompile()
                cacheflags = parse(CacheFlags, read(`$(Base.julia_cmd()) $(flags) --eval 'show(Base.CacheFlags())'`, String))
                Pkg.precompile(sandbox_ctx; io = sandbox_ctx.io, configs = flags => cacheflags)
            end

            printpkgstyle(ctx.io, :Testing, "Running tests...")
            flush(ctx.io)
            code = gen_test_code(source_path; test_args)
            cmd = `$(Base.julia_cmd()) --threads=$(get_threads_spec()) $(flags) --eval $code`
            p, interrupted = subprocess_handler(cmd, ctx.io, "Tests interrupted. Exiting the test process")
            if success(p)
                printpkgstyle(ctx.io, :Testing, pkg.name * " tests passed ")
            elseif !interrupted
                push!(pkgs_errored, (pkg.name, p))
            end
        end
    end

    # TODO: Should be included in Base
    function signal_name(signal::Integer)
        return if signal == Base.SIGHUP
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
    return if !isempty(pkgs_errored)
        function reason(p)
            return if Base.process_signaled(p)
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

# Handles the interrupting of a subprocess gracefully to avoid orphaning
function subprocess_handler(cmd::Cmd, io::IO, error_msg::String)
    stdout = io
    stderr = stderr_f()
    stdout isa IOContext{IO} && (stdout = stdout.io)
    stderr isa IOContext{IO} && (stderr = stderr.io)
    @debug "Running command" cmd
    p = run(pipeline(ignorestatus(cmd); stdout, stderr), wait = false)
    interrupted = false
    try
        wait(p)
    catch e
        if e isa InterruptException
            interrupted = true
            print("\n")
            printpkgstyle(io, :Testing, "$error_msg\n", color = Base.error_color())
            # Give some time for the child interrupt handler to print a stacktrace and exit,
            # then kill the process if still running
            if timedwait(() -> !process_running(p), 4) == :timed_out
                kill(p, Base.SIGKILL)
            end
        else
            rethrow()
        end
    end
    return p, interrupted
end

# Display

function stat_rep(x::PackageSpec; name = true)
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
    return join(filter(!isempty, [name, version, repo, path, pinned]), " ")
end

print_single(io::IO, pkg::PackageSpec) = print(io, stat_rep(pkg))

is_instantiated(::Nothing) = false
is_instantiated(x::PackageSpec) = x.version != VersionSpec() || is_stdlib(x.uuid)
# Compare an old and new node of the dependency graph and print a single line to summarize the change
function print_diff(io::IO, old::Union{Nothing, PackageSpec}, new::Union{Nothing, PackageSpec})
    return if !is_instantiated(old) && is_instantiated(new)
        printstyled(io, "+ $(stat_rep(new))"; color = :light_green)
    elseif !is_instantiated(new)
        printstyled(io, "- $(stat_rep(old))"; color = :light_red)
    elseif is_tracking_registry(old) && is_tracking_registry(new) &&
            new.version isa VersionNumber && old.version isa VersionNumber && new.version != old.version
        if new.version > old.version
            printstyled(io, "↑ $(stat_rep(old)) ⇒ $(stat_rep(new; name = false))"; color = :light_yellow)
        else
            printstyled(io, "↓ $(stat_rep(old)) ⇒ $(stat_rep(new; name = false))"; color = :light_magenta)
        end
    else
        printstyled(io, "~ $(stat_rep(old)) ⇒ $(stat_rep(new; name = false))"; color = :light_yellow)
    end
end

function status_compat_info(pkg::PackageSpec, env::EnvCache, regs::Vector{Registry.RegistryInstance})
    pkg.version isa VersionNumber || return nothing # Can happen when there is no manifest
    manifest, project = env.manifest, env.project
    packages_holding_back = String[]
    max_version, max_version_in_compat = v"0", v"0"
    for reg in regs
        reg_pkg = get(reg, pkg.uuid, nothing)
        reg_pkg === nothing && continue
        info = Registry.registry_info(reg, reg_pkg)
        # Get versions directly from version_info
        versions = keys(info.version_info)
        versions = filter(v -> !Registry.isyanked(info, v), versions)
        max_version_reg = maximum(versions; init = v"0")
        max_version = max(max_version, max_version_reg)
        compat_spec = get_compat_workspace(env, pkg.name)
        versions_in_compat = filter(in(compat_spec), versions)
        max_version_in_compat = max(max_version_in_compat, maximum(versions_in_compat; init = v"0"))
    end
    max_version == v"0" && return nothing
    pkg.version >= max_version && return nothing

    pkgid = Base.PkgId(pkg.uuid, pkg.name)
    if PKGORIGIN_HAVE_VERSION && RESPECT_SYSIMAGE_VERSIONS[] && Base.in_sysimage(pkgid)
        pkgorigin = get(Base.pkgorigins, pkgid, nothing)
        if pkgorigin !== nothing && pkg.version !== nothing && pkg.version == pkgorigin.version
            return ["sysimage"], max_version, max_version_in_compat
        end
    end

    # Check compat of project
    if pkg.version == max_version_in_compat && max_version_in_compat != max_version
        return ["compat"], max_version, max_version_in_compat
    end

    manifest_info = get(manifest, pkg.uuid, nothing)
    manifest_info === nothing && return nothing

    # Check compat of dependencies
    for (uuid, dep_pkg) in manifest
        is_stdlib(uuid) && continue
        if !(pkg.uuid in values(dep_pkg.deps))
            continue
        end
        dep_info = get(manifest, uuid, nothing)
        dep_info === nothing && continue
        for reg in regs
            reg_pkg = get(reg, uuid, nothing)
            reg_pkg === nothing && continue
            info = Registry.registry_info(reg, reg_pkg)
            # Query compressed deps and compat for the specific dependency version (optimized: only fetch this pkg's compat)
            compat_info_v_uuid = Registry.query_compat_for_version(info, dep_info.version, pkg.uuid)
            compat_info_v_uuid === nothing && continue
            if !(max_version in compat_info_v_uuid)
                push!(packages_holding_back, dep_pkg.name)
            end
        end
    end

    # Check compat with Julia itself
    julia_compatible_versions = Set{VersionNumber}()
    for reg in regs
        reg_pkg = get(reg, pkg.uuid, nothing)
        reg_pkg === nothing && continue
        info = Registry.registry_info(reg, reg_pkg)
        # Check all versions for Julia compatibility (optimized: only fetch Julia compat)
        for v in keys(info.version_info)
            julia_vspec = Registry.query_compat_for_version(info, v, JULIA_UUID)
            if julia_vspec !== nothing && VERSION in julia_vspec
                push!(julia_compatible_versions, v)
            end
        end
    end
    if !(max_version in julia_compatible_versions)
        push!(packages_holding_back, "julia")
    end

    return sort!(unique!(packages_holding_back)), max_version, max_version_in_compat
end

function diff_array(old_env::Union{EnvCache, Nothing}, new_env::EnvCache; manifest = true, workspace = false)
    function index_pkgs(pkgs, uuid)
        idx = findfirst(pkg -> pkg.uuid == uuid, pkgs)
        return idx === nothing ? nothing : pkgs[idx]
    end
    # load deps
    if workspace
        new = manifest ? load_all_deps(new_env) : load_direct_deps(new_env)
    else
        new = manifest ? load_all_deps_loadable(new_env) : load_project_deps(new_env.project, new_env.project_file, new_env.manifest, new_env.manifest_file)
    end

    T, S = Union{UUID, Nothing}, Union{PackageSpec, Nothing}
    if old_env === nothing
        return Tuple{T, S, S}[(pkg.uuid, nothing, pkg)::Tuple{T, S, S} for pkg in new]
    end
    if workspace
        old = manifest ? load_all_deps(old_env) : load_direct_deps(old_env)
    else
        old = manifest ? load_all_deps_loadable(old_env) : load_project_deps(old_env.project, old_env.project_file, old_env.manifest, old_env.manifest_file)
    end
    # merge old and new into single array
    all_uuids = union(T[pkg.uuid for pkg in old], T[pkg.uuid for pkg in new])
    return Tuple{T, S, S}[(uuid, index_pkgs(old, uuid), index_pkgs(new, uuid))::Tuple{T, S, S} for uuid in all_uuids]
end

function is_package_downloaded(manifest_file::String, pkg::PackageSpec; platform = HostPlatform())
    sourcepath = source_path(manifest_file, pkg)
    sourcepath === nothing && return false
    isdir(sourcepath) || return false
    check_artifacts_downloaded(sourcepath; platform) || return false
    return true
end

function status_ext_info(pkg::PackageSpec, env::EnvCache)
    manifest = env.manifest
    manifest_info = get(manifest, pkg.uuid, nothing)
    manifest_info === nothing && return nothing
    depses = manifest_info.deps
    weakdepses = manifest_info.weakdeps
    exts = manifest_info.exts
    if !isempty(weakdepses) && !isempty(exts)
        v = ExtInfo[]
        for (ext, extdeps) in exts
            extdeps isa String && (extdeps = String[extdeps])
            # Note: `get_extension` returns nothing for stdlibs that are loaded via `require_stdlib`
            ext_loaded = (Base.get_extension(Base.PkgId(pkg.uuid, pkg.name), Symbol(ext)) !== nothing)
            # Check if deps are loaded
            extdeps_info = Tuple{String, Bool}[]
            for extdep in extdeps
                if !(haskey(weakdepses, extdep) || haskey(depses, extdep))
                    pkgerror(
                        isnothing(pkg.name) ? "M" : "$(pkg.name) has a malformed Project.toml, ",
                        "the extension package $extdep is not listed in [weakdeps] or [deps]"
                    )
                end
                uuid = get(weakdepses, extdep, nothing)
                if uuid === nothing
                    uuid = depses[extdep]
                end
                loaded = haskey(Base.loaded_modules, Base.PkgId(uuid, extdep))
                push!(extdeps_info, (extdep, loaded))
            end
            push!(v, ExtInfo((ext, ext_loaded), extdeps_info))
        end
        return v
    end
    return nothing
end

struct ExtInfo
    ext::Tuple{String, Bool} # name, loaded
    weakdeps::Vector{Tuple{String, Bool}} # name, loaded
end
struct PackageStatusData
    uuid::UUID
    old::Union{Nothing, PackageSpec}
    new::Union{Nothing, PackageSpec}
    downloaded::Bool
    upgradable::Bool
    heldback::Bool
    compat_data::Union{Nothing, Tuple{Vector{String}, VersionNumber, VersionNumber}}
    changed::Bool
    extinfo::Union{Nothing, Vector{ExtInfo}}
    deprecation_info::Union{Nothing, Dict{String, Any}}
end

function print_status(
        env::EnvCache, old_env::Union{Nothing, EnvCache}, registries::Vector{Registry.RegistryInstance}, header::Symbol,
        uuids::Vector, names::Vector; manifest = true, diff = false, ignore_indent::Bool, workspace::Bool, outdated::Bool, deprecated::Bool, extensions::Bool, io::IO,
        mode::PackageMode, hidden_upgrades_info::Bool, show_usagetips::Bool = true
    )
    not_installed_indicator = sprint((io, args) -> printstyled(io, args...; color = Base.error_color()), "→", context = io)
    upgradable_indicator = sprint((io, args) -> printstyled(io, args...; color = :green), "⌃", context = io)
    heldback_indicator = sprint((io, args) -> printstyled(io, args...; color = Base.warn_color()), "⌅", context = io)
    filter = !isempty(uuids) || !isempty(names)
    # setup
    xs = diff_array(old_env, env; manifest, workspace)
    # filter and return early if possible
    if isempty(xs) && !diff
        printpkgstyle(
            io, header, "$(pathrepr(manifest ? env.manifest_file : env.project_file)) (empty " *
                (manifest ? "manifest" : "project") * ")", ignore_indent
        )
        return nothing
    end
    no_changes = all(p -> p[2] == p[3], xs)
    if no_changes
        if manifest
            printpkgstyle(io, :Manifest, "No packages added to or removed from $(pathrepr(env.manifest_file))", ignore_indent; color = Base.info_color())
        else
            printpkgstyle(io, :Project, "No packages added to or removed from $(pathrepr(env.project_file))", ignore_indent; color = Base.info_color())
        end
    else
        if filter
            # Find packages matching the filter
            matching_ids = Set{UUID}()
            for (id, old, new) in xs
                if (id in uuids || something(new, old).name in names)
                    push!(matching_ids, id)
                end
            end
            # In manifest mode, also include all dependencies of matching packages
            if manifest && !isempty(matching_ids)
                deps_to_add = Set{UUID}()
                for id in matching_ids
                    entry = get(env.manifest, id, nothing)
                    if entry !== nothing
                        union!(deps_to_add, values(entry.deps))
                    end
                end
                union!(matching_ids, deps_to_add)
            end
            xs = eltype(xs)[(id, old, new) for (id, old, new) in xs if id in matching_ids]
        end
        if isempty(xs)
            printpkgstyle(
                io, Symbol("No Matches"),
                "in $(diff ? "diff for " : "")$(pathrepr(manifest ? env.manifest_file : env.project_file))", ignore_indent
            )
            return nothing
        end
        # main print
        readonly_suffix = env.project.readonly ? " (readonly)" : ""
        printpkgstyle(io, header, pathrepr(manifest ? env.manifest_file : env.project_file) * readonly_suffix, ignore_indent)
        if workspace && !manifest
            for (path, _) in env.workspace
                relative_path = Types.relative_project_path(env.project_file, path)
                printpkgstyle(io, :Status, relative_path, true)
            end
        end
        # Sort stdlibs and _jlls towards the end in status output
        xs = sort!(xs, by = (x -> (is_stdlib(x[1]), endswith(something(x[3], x[2]).name, "_jll"), something(x[3], x[2]).name, x[1])))
    end

    all_packages_downloaded = true
    no_packages_upgradable = true
    no_visible_packages_heldback = true
    no_packages_heldback = true
    lpadding = 2

    package_statuses = PackageStatusData[]
    for (uuid, old, new) in xs
        if Types.is_project_uuid(env, uuid)
            continue
        end
        changed = old != new
        if diff && !changed
            continue
        end
        latest_version = true
        # Outdated info
        cinfo = nothing
        ext_info = nothing
        if !isnothing(new) && !is_stdlib(new.uuid)
            cinfo = status_compat_info(new, env, registries)
            if cinfo !== nothing
                latest_version = false
            end
        end
        # if we are running with outdated, only show packages that are upper bounded
        if outdated && latest_version
            continue
        end

        if !isnothing(new) && !is_stdlib(new.uuid)
            ext_info = status_ext_info(new, env)
        end

        if extensions && ext_info === nothing
            continue
        end

        # Deprecated info
        deprecation_info = nothing
        pkg_deprecated = false
        if !isnothing(new)
            pkg_spec = something(new, old)
            deprecation_info = get_pkg_deprecation_info(pkg_spec, registries)
            pkg_deprecated = deprecation_info !== nothing
        end

        # if we are running with deprecated, only show packages that are deprecated
        if deprecated && !pkg_deprecated
            continue
        end

        # TODO: Show extension deps for project as well?

        pkg_downloaded = !is_instantiated(new) || is_package_downloaded(env.manifest_file, new)

        new_ver_avail = !latest_version && !Operations.is_tracking_repo(new) && !Operations.is_tracking_path(new)
        pkg_upgradable = new_ver_avail && cinfo !== nothing && isempty(cinfo[1])
        pkg_heldback = new_ver_avail && cinfo !== nothing && !isempty(cinfo[1])

        if !pkg_downloaded && (pkg_upgradable || pkg_heldback)
            # allow space in the gutter for two icons on a single line
            lpadding = 3
        end
        all_packages_downloaded &= (!changed || pkg_downloaded)
        no_packages_upgradable &= (!changed || !pkg_upgradable)
        no_visible_packages_heldback &= (!changed || !pkg_heldback)
        no_packages_heldback &= !pkg_heldback

        push!(package_statuses, PackageStatusData(uuid, old, new, pkg_downloaded, pkg_upgradable, pkg_heldback, cinfo, changed, ext_info, deprecation_info))
    end

    for pkg in package_statuses
        pad = 0
        print_padding(x) = (print(io, x); pad += 1)

        if !pkg.downloaded
            print_padding(not_installed_indicator)
        elseif lpadding > 2
            print_padding(" ")
        end
        if pkg.upgradable
            print_padding(upgradable_indicator)
        elseif pkg.heldback
            print_padding(heldback_indicator)
        end

        # Fill the remaining padding with spaces
        while pad < lpadding
            print_padding(" ")
        end

        printstyled(io, "[", string(pkg.uuid)[1:8], "] "; color = :light_black)

        diff ? print_diff(io, pkg.old, pkg.new) : print_single(io, pkg.new)

        # show if package is yanked
        pkg_spec = something(pkg.new, pkg.old)
        if is_pkgversion_yanked(pkg_spec, registries)
            printstyled(io, " [yanked]"; color = :yellow)
        end

        # show if package is deprecated
        if pkg.deprecation_info !== nothing
            printstyled(io, " [deprecated]"; color = :yellow)
        end

        # show deprecation details when using --deprecated flag
        if deprecated && !diff && pkg.deprecation_info !== nothing
            reason = get(pkg.deprecation_info, "reason", nothing)
            alternative = get(pkg.deprecation_info, "alternative", nothing)
            if reason !== nothing
                printstyled(io, " (reason: ", reason, ")"; color = :yellow)
            end
            if alternative !== nothing
                printstyled(io, " (alternative: ", alternative, ")"; color = :yellow)
            end
        end

        if outdated && !diff && pkg.compat_data !== nothing
            packages_holding_back, max_version, max_version_compat = pkg.compat_data
            if pkg.new.version !== max_version_compat && max_version_compat != max_version
                printstyled(io, " [<v", max_version_compat, "]", color = :light_magenta)
                printstyled(io, ",")
            end
            printstyled(io, " (<v", max_version, ")"; color = Base.warn_color())
            if packages_holding_back == ["compat"]
                printstyled(io, " [compat]"; color = :light_magenta)
            elseif packages_holding_back == ["sysimage"]
                printstyled(io, " [sysimage]"; color = :light_magenta)
            else
                pkg_str = isempty(packages_holding_back) ? "" : string(": ", join(packages_holding_back, ", "))
                printstyled(io, pkg_str; color = Base.warn_color())
            end
        end
        # show if loaded version and version in the manifest doesn't match
        pkg_spec = something(pkg.new, pkg.old)
        pkgid = Base.PkgId(pkg.uuid, pkg_spec.name)
        m = get(Base.loaded_modules, pkgid, nothing)
        if m isa Module && pkg_spec.version !== nothing
            loaded_path = pathof(m)
            env_path = Base.locate_package(pkgid) # nothing if not installed
            if loaded_path !== nothing && env_path !== nothing &&!samefile(loaded_path, env_path)
                loaded_version = pkgversion(m)
                env_version = pkg_spec.version
                if loaded_version !== env_version
                    printstyled(io, " [loaded: v$loaded_version]"; color = :light_yellow)
                else
                    loaded_version_str = loaded_version === nothing ? "" : " (v$loaded_version)"
                    env_version_str = env_version === nothing ? "" : " (v$env_version)"
                    printstyled(io, " [loaded: `$loaded_path`$loaded_version_str expected `$env_path`$env_version_str]"; color = :light_yellow)
                end
            end
        end

        if extensions && !diff && pkg.extinfo !== nothing
            println(io)
            for (i, ext) in enumerate(pkg.extinfo)
                sym = i == length(pkg.extinfo) ? '└' : '├'
                function print_ext_entry(io, (name, installed))
                    color = installed ? :light_green : :light_black
                    return printstyled(io, name, ; color)
                end
                print(io, "              ", sym, "─ ")
                print_ext_entry(io, ext.ext)

                print(io, " [")
                join(io, sprint.(print_ext_entry, ext.weakdeps; context = io), ", ")
                print(io, "]")
                if i != length(pkg.extinfo)
                    println(io)
                end
            end
        end

        println(io)
    end

    if !no_changes && !all_packages_downloaded
        printpkgstyle(io, :Info, "Packages marked with $not_installed_indicator are not downloaded, use `instantiate` to download", color = Base.info_color(), ignore_indent)
    end
    if !outdated && (mode != PKGMODE_COMBINED || (manifest == true))
        tipend = manifest ? " -m" : ""
        tip = show_usagetips ? " To see why use `status --outdated$tipend`" : ""
        if !no_packages_upgradable && no_visible_packages_heldback
            printpkgstyle(io, :Info, "Packages marked with $upgradable_indicator have new versions available and may be upgradable.", color = Base.info_color(), ignore_indent)
        end
        if !no_visible_packages_heldback && no_packages_upgradable
            printpkgstyle(io, :Info, "Packages marked with $heldback_indicator have new versions available but compatibility constraints restrict them from upgrading.$tip", color = Base.info_color(), ignore_indent)
        end
        if !no_visible_packages_heldback && !no_packages_upgradable
            printpkgstyle(io, :Info, "Packages marked with $upgradable_indicator and $heldback_indicator have new versions available. Those with $upgradable_indicator may be upgradable, but those with $heldback_indicator are restricted by compatibility constraints from upgrading.$tip", color = Base.info_color(), ignore_indent)
        end
        if !manifest && hidden_upgrades_info && no_visible_packages_heldback && !no_packages_heldback
            # only warn if showing project and outdated indirect deps are hidden
            printpkgstyle(io, :Info, "Some packages have new versions but compatibility constraints restrict them from upgrading.$tip", color = Base.info_color(), ignore_indent)
        end
    end

    # Check if any packages are yanked for warning message
    any_yanked_packages = any(pkg -> is_pkgversion_yanked(something(pkg.new, pkg.old), registries), package_statuses)

    # Add warning for yanked packages
    if any_yanked_packages
        yanked_str = sprint((io, args) -> printstyled(io, args...; color = :yellow), "[yanked]", context = io)
        printpkgstyle(io, :Warning, """Package versions marked with $yanked_str have been pulled from their registry. \
        It is recommended to update them to resolve a valid version.""", color = Base.warn_color(), ignore_indent)
    end

    # Check if any packages are deprecated for info message
    any_deprecated_packages = any(pkg -> pkg.deprecation_info !== nothing, package_statuses)

    # Add info for deprecated packages (only if not already in deprecated mode)
    if !deprecated && any_deprecated_packages
        deprecated_str = sprint((io, args) -> printstyled(io, args...; color = :yellow), "[deprecated]", context = io)
        tipend = manifest ? " -m" : ""
        tip = show_usagetips ? " Use `status --deprecated$tipend` to see more information." : ""
        printpkgstyle(io, :Info, """Packages marked with $deprecated_str are no longer maintained.$tip""", color = Base.info_color(), ignore_indent)
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
            new_env.project = read_project(GitTools.git_file_stream(repo, "HEAD:$project_path", fakeit = true))
            new_env.manifest = read_manifest(GitTools.git_file_stream(repo, "HEAD:$manifest_path", fakeit = true))
            return new_env
        end
    catch err
        err isa PkgError || rethrow(err)
        return nothing
    end
end

function show_update(env::EnvCache, registries::Vector{Registry.RegistryInstance}; io::IO, hidden_upgrades_info = false)
    old_env = EnvCache()
    old_env.project = env.original_project
    old_env.manifest = env.original_manifest
    status(env, registries; header = :Updating, mode = PKGMODE_COMBINED, env_diff = old_env, ignore_indent = false, io = io, hidden_upgrades_info)
    return nothing
end

function status(
        env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec} = PackageSpec[];
        header = nothing, mode::PackageMode = PKGMODE_PROJECT, git_diff::Bool = false, env_diff = nothing, ignore_indent = true,
        io::IO, workspace::Bool = false, outdated::Bool = false, deprecated::Bool = false, extensions::Bool = false, hidden_upgrades_info::Bool = false, show_usagetips::Bool = true
    )
    io == Base.devnull && return
    # if a package, print header
    if header === nothing && env.pkg !== nothing
        readonly_status = env.project.readonly ? " (readonly)" : ""
        printpkgstyle(io, :Project, string(env.pkg.name, " v", env.pkg.version, readonly_status), true; color = Base.info_color())
    end
    # load old env
    old_env = nothing
    if git_diff
        project_dir = dirname(env.project_file)
        git_repo_dir = discover_repo(project_dir)
        if git_repo_dir == nothing
            @warn "diff option only available for environments in git repositories, ignoring."
        else
            old_env = git_head_env(env, git_repo_dir)
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
        print_status(env, old_env, registries, header, filter_uuids, filter_names; manifest = false, diff, ignore_indent, io, workspace, outdated, deprecated, extensions, mode, hidden_upgrades_info, show_usagetips)
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        print_status(env, old_env, registries, header, filter_uuids, filter_names; diff, ignore_indent, io, workspace, outdated, deprecated, extensions, mode, hidden_upgrades_info, show_usagetips)
    end
    return if is_manifest_current(env) === false
        tip = if show_usagetips
            if Pkg.in_repl_mode()
                " It is recommended to `pkg> resolve` or consider `pkg> update` if necessary."
            else
                " It is recommended to `Pkg.resolve()` or consider `Pkg.update()` if necessary."
            end
        else
            ""
        end
        printpkgstyle(
            io, :Warning, "The project dependencies or compat requirements have changed since the manifest was last resolved.$tip",
            ignore_indent; color = Base.warn_color()
        )
    end
end

function is_manifest_current(env::EnvCache)
    if haskey(env.manifest.other, "project_hash")
        recorded_hash = env.manifest.other["project_hash"]
        current_hash = Types.workspace_resolve_hash(env)
        return recorded_hash == current_hash
    else
        # Manifest doesn't have a hash of the source Project recorded
        return nothing
    end
end

function compat_line(io, pkg, uuid, compat_str, longest_dep_len; indent = "  ")
    iob = IOBuffer()
    ioc = IOContext(iob, :color => get(io, :color, false)::Bool)
    if isnothing(uuid)
        print(ioc, "$indent           ")
    else
        printstyled(ioc, "$indent[", string(uuid)[1:8], "] "; color = :light_black)
    end
    print(ioc, rpad(pkg, longest_dep_len))
    if isnothing(compat_str)
        printstyled(ioc, " none"; color = :light_black)
    else
        print(ioc, " ", compat_str)
    end
    return String(take!(iob))
end

function print_compat(ctx::Context, pkgs_in::Vector{PackageSpec} = PackageSpec[]; io = nothing)
    io = something(io, ctx.io)
    printpkgstyle(io, :Compat, pathrepr(ctx.env.project_file))
    names = [pkg.name for pkg in pkgs_in]
    pkgs = isempty(pkgs_in) ? ctx.env.project.deps : filter(pkg -> in(first(pkg), names), ctx.env.project.deps)
    add_julia = isempty(pkgs_in) || any(p -> p.name == "julia", pkgs_in)
    longest_dep_len = isempty(pkgs) ? length("julia") : max(reduce(max, map(length, collect(keys(pkgs)))), length("julia"))
    if add_julia
        println(io, compat_line(io, "julia", nothing, get_compat_str(ctx.env.project, "julia"), longest_dep_len))
    end
    for (dep, uuid) in pkgs
        println(io, compat_line(io, dep, uuid, get_compat_str(ctx.env.project, dep), longest_dep_len))
    end
    return
end
print_compat(pkg::String; kwargs...) = print_compat(Context(), pkg; kwargs...)
print_compat(; kwargs...) = print_compat(Context(); kwargs...)

function apply_force_latest_compatible_version!(
        ctx::Types.Context;
        target_name = nothing,
        allow_earlier_backwards_compatible_versions::Bool = true
    )
    deps_from_env = load_direct_deps(ctx.env)
    deps = [(; name = x.name, uuid = x.uuid) for x in deps_from_env]
    for dep in deps
        if !is_stdlib(dep.uuid)
            apply_force_latest_compatible_version!(
                ctx,
                dep;
                target_name,
                allow_earlier_backwards_compatible_versions,
            )
        end
    end
    return nothing
end

function apply_force_latest_compatible_version!(
        ctx::Types.Context,
        dep::NamedTuple{(:name, :uuid), Tuple{String, Base.UUID}};
        target_name = nothing,
        allow_earlier_backwards_compatible_versions::Bool = true
    )
    name, uuid = dep
    has_compat = haskey(ctx.env.project.compat, name)
    if !has_compat
        if name != target_name
            @warn(
                "Dependency does not have a [compat] entry",
                name, uuid, target_name,
            )
        end
        return nothing
    end
    old_compat_spec = ctx.env.project.compat[name].val
    latest_compatible_version = get_latest_compatible_version(
        ctx,
        uuid,
        old_compat_spec,
    )
    earliest_backwards_compatible_version = get_earliest_backwards_compatible_version(latest_compatible_version)
    if allow_earlier_backwards_compatible_versions
        version_for_intersect = only_major_minor_patch(earliest_backwards_compatible_version)
    else
        version_for_intersect = only_major_minor_patch(latest_compatible_version)
    end
    compat_for_intersect = Pkg.Types.semver_spec("≥ $(version_for_intersect)")
    new_compat_spec = Base.intersect(old_compat_spec, compat_for_intersect)
    ctx.env.project.compat[name].val = new_compat_spec
    return nothing
end

function only_major_minor_patch(ver::Base.VersionNumber)
    return Base.VersionNumber(ver.major, ver.minor, ver.patch)
end

function get_earliest_backwards_compatible_version(ver::Base.VersionNumber)
    (ver.major > 0) && return Base.VersionNumber(ver.major, 0, 0)
    (ver.minor > 0) && return Base.VersionNumber(0, ver.minor, 0)
    return Base.VersionNumber(0, 0, ver.patch)
end

function get_latest_compatible_version(
        ctx::Types.Context,
        uuid::Base.UUID,
        compat_spec::VersionSpec
    )
    all_registered_versions = get_all_registered_versions(ctx, uuid)
    compatible_versions = filter(in(compat_spec), all_registered_versions)
    latest_compatible_version = maximum(compatible_versions)
    return latest_compatible_version
end

function get_all_registered_versions(
        ctx::Types.Context,
        uuid::Base.UUID
    )
    versions = Set{VersionNumber}()
    for reg in ctx.registries
        pkg = get(reg, uuid, nothing)
        if pkg !== nothing
            info = Registry.registry_info(reg, pkg)
            union!(versions, keys(info.version_info))
        end
    end
    return versions
end

end # module
