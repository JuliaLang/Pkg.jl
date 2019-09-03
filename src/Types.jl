# This file is a part of Julia. License is MIT: https://julialang.org/license

module Types

using UUIDs
using Random
using Dates
import LibGit2
import REPL
import Base.string
using REPL.TerminalMenus

using ..TOML
import ..Pkg, ..UPDATED_REGISTRY_THIS_SESSION
import Pkg: GitTools, depots, depots1, logdir
import ..BinaryPlatforms: Platform

import Base: SHA1
using SHA

export UUID, pkgID, SHA1, VersionRange, VersionSpec, empty_versionspec,
    Requires, Fixed, merge_requires!, satisfies, ResolverError,
    PackageSpec, EnvCache, Context, PackageInfo, ProjectInfo, GitRepo, Context!, get_deps,
    PkgError, pkgerror, has_name, has_uuid, is_stdlib, write_env, write_env_usage, parse_toml, find_registered!,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved, instantiate_pkg_repo!,
    manifest_info, registered_uuids, registered_paths, registered_uuid, registered_name,
    read_project, read_package, read_manifest, pathrepr, registries,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PackageSpecialAction, PKGSPEC_NOTHING, PKGSPEC_PINNED, PKGSPEC_FREED, PKGSPEC_DEVELOPED, PKGSPEC_TESTED, PKGSPEC_REPO_ADDED,
    printpkgstyle,
    projectfile_path, manifestfile_path,
    RegistrySpec,
    is_tracking_registered_version, is_tracking_unregistered, find_installed, source_path

using ..PkgErrors, ..GitRepos, ..VersionTypes, ..Manifests, ..Projects, ..PackageSpecs,
    ..Utils, ..EnvCaches, ..Contexts, ..RegistrySpecs, ..ResolverTypes, ..PackageResolve,
    ..PkgSpecUtils
import ..PkgSpecUtils: find_installed
import ..Infos: ProjectInfo, PackageInfo
import ..RegistryOps: clone_or_cp_registries, remove_registries, update_registries, find_installed_registries,
    clone_default_registries, populate_known_registries_with_urls!, find_registered!, registered_uuids,
    registered_paths, registered_names, registered_info, DEFAULT_REGISTRIES

############
# Artifact #
############
Base.@kwdef struct Artifact
    name::Union{String,Nothing} = nothing
    url::Union{String,Nothing} = nothing
    tree_hash::Union{SHA1,Nothing} = nothing
    tarball_hash::Union{Vector{UInt8},Nothing} = nothing
    extract::Bool = false
    filename::Union{String,Nothing} = nothing
    platform::Union{Platform,Nothing} = nothing
end

end # module
