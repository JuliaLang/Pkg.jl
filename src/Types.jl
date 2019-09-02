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

## ordering of UUIDs ##

if VERSION < v"1.2.0-DEV.269"  # Defined in Base as of #30947
    Base.isless(a::UUID, b::UUID) = a.value < b.value
end

## Computing UUID5 values from (namespace, key) pairs ##
function uuid5(namespace::UUID, key::String)
    data = [reinterpret(UInt8, [namespace.value]); codeunits(key)]
    u = reinterpret(UInt128, sha1(data)[1:16])[1]
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end
uuid5(namespace::UUID, key::AbstractString) = uuid5(namespace, String(key))

const uuid_dns = UUID(0x6ba7b810_9dad_11d1_80b4_00c04fd430c8)
const uuid_julia_project = uuid5(uuid_dns, "julialang.org")
const uuid_package = uuid5(uuid_julia_project, "package")
const uuid_registry = uuid5(uuid_julia_project, "registry")
const uuid_julia = uuid5(uuid_package, "julia")

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

project_uuid(ctx::Context) = ctx.env.pkg === nothing ? nothing : ctx.env.pkg.uuid
collides_with_project(ctx::Context, pkg::PackageSpec) =
    is_project_name(ctx, pkg.name) || is_project_uuid(ctx, pkg.uuid)
is_project(ctx::Context, pkg::PackageSpec) = is_project_uuid(ctx, pkg.uuid)
is_project_name(ctx::Context, name::String) =
    ctx.env.pkg !== nothing && ctx.env.pkg.name == name
is_project_uuid(ctx::Context, uuid::UUID) = project_uuid(ctx) == uuid
Utils.is_stdlib(ctx::Context, uuid::UUID) = uuid in keys(ctx.stdlibs)

# target === nothing : main dependencies
# target === "*"     : main + all extras
# target === "name"  : named target deps
function deps_names(project::Project, target::Union{Nothing,String}=nothing)::Vector{String}
    deps = collect(keys(project.deps))
    if target === nothing
        x = String[]
    elseif target == "*"
        x = collect(keys(project.extras))
    else
        x = haskey(project.targets, target) ?
            collect(values(project.targets[target])) :
            String[]
    end
    return sort!(union!(deps, x))
end

function get_deps(project::Project, target::Union{Nothing,String}=nothing)
    names = deps_names(project, target)
    deps = filter(((dep, _),) -> dep in names, project.deps)
    extras = project.extras
    for name in names
        haskey(deps, name) && continue
        haskey(extras, name) ||
            pkgerror("target `$target` has unlisted dependency `$name`")
        deps[name] = extras[name]
    end
    return deps
end
get_deps(env::EnvCache, target::Union{Nothing,String}=nothing) =
    get_deps(env.project, target)
get_deps(ctx::Context, target::Union{Nothing,String}=nothing) =
    get_deps(ctx.env, target)

function project_compatibility(ctx::Context, name::String)
    compat = get(ctx.env.project.compat, name, nothing)
    return compat === nothing ? VersionSpec() : VersionSpec(semver_spec(compat))
end

function Projects.write_project(project::Project, env, old_env, ctx::Context; display_diff=true)
    project = Projects.destructure(ctx.env.project)
    if !isempty(project) || ispath(env.project_file)
        if display_diff && !(ctx.currently_running_target)
            printpkgstyle(ctx, :Updating, pathrepr(env.project_file))
            Pkg.Display.print_project_diff(ctx, old_env, env)
        end
        if !ctx.preview
            mkpath(dirname(env.project_file))
            write_project(project, env.project_file)
        end
    end
end

function Manifests.write_manifest(manifest::Manifest, env, old_env, ctx::Context; display_diff=true)
    isempty(manifest) && !ispath(env.manifest_file) && return

    if display_diff && !(ctx.currently_running_target)
        printpkgstyle(ctx, :Updating, pathrepr(env.manifest_file))
        Pkg.Display.print_manifest_diff(ctx, old_env, env)
    end
    !ctx.preview && write_manifest(manifest, env.manifest_file)
end

function write_env(ctx::Context; display_diff=true)
    env = ctx.env
    old_env = EnvCache(env.env) # load old environment for comparison
    write_project(env.project, env, old_env, ctx; display_diff=display_diff)
    write_manifest(env.manifest, env, old_env, ctx; display_diff=display_diff)
end

end # module
