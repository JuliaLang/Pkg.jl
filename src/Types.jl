# This file is a part of Julia. License is MIT: https://julialang.org/license

module Types

using UUIDs
using Random
using Dates
import LibGit2
import Base.string

using TOML
import ..Pkg, ..Registry
import ..Pkg: GitTools, depots, depots1, logdir, set_readonly, safe_realpath, pkg_server, stdlib_dir, stdlib_path, isurl, stderr_f, RESPECT_SYSIMAGE_VERSIONS, atomic_toml_write, create_cachedir_tag, normalize_path_for_toml
import Base.BinaryPlatforms: Platform
using ..Pkg.Versions
import FileWatching

import Base: SHA1
using SHA

export UUID, SHA1, VersionRange, VersionSpec,
    PackageSpec, PackageEntry, EnvCache, Context, GitRepo, Context!, Manifest, ManifestRegistryEntry, Project, err_rep,
    PkgError, pkgerror,
    has_name, has_uuid, is_stdlib, is_or_was_stdlib, stdlib_version, is_unregistered_stdlib, stdlibs, stdlib_infos, write_env, write_env_usage, parse_toml,
    project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!, stdlib_resolve!, handle_repos_develop!, handle_repos_add!, ensure_resolved,
    registered_name,
    manifest_info,
    read_project, read_package, read_manifest, get_path_repo,
    PackageMode, PKGMODE_MANIFEST, PKGMODE_PROJECT, PKGMODE_COMBINED,
    UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
    PreserveLevel, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED,
    PRESERVE_TIERED_INSTALLED, PRESERVE_NONE,
    projectfile_path, manifestfile_path

# Load in data about historical stdlibs
include("HistoricalStdlibs.jl")

deepcopy_toml(x) = x
function deepcopy_toml(@nospecialize(x::Vector))
    d = similar(x)
    for (i, v) in enumerate(x)
        d[i] = deepcopy_toml(v)
    end
    return d
end
function deepcopy_toml(x::Dict{String, Any})
    d = Dict{String, Any}()
    sizehint!(d, length(x))
    for (k, v) in x
        d[k] = deepcopy_toml(v)
    end
    return d
end

# See loading.jl
const TOML_CACHE = Base.TOMLCache(Base.TOML.Parser{Dates}())
const TOML_LOCK = ReentrantLock()
# Some functions mutate the returning Dict so return a copy of the cached value here
parse_toml(toml_file::AbstractString; manifest::Bool=false, project::Bool=!manifest) =
    Base.invokelatest(deepcopy_toml, Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK; manifest, project))::Dict{String, Any}

#################
# Pkg Error #
#################
struct PkgError <: Exception
    msg::String
end
pkgerror(msg::String...) = throw(PkgError(join(msg)))
Base.showerror(io::IO, err::PkgError) = print(io, err.msg)

#################################
# Portable script functionality #
#################################
function _render_inline_block(kind::Symbol, toml::String, newline::String, format::Symbol)
    kind_str = kind === :project ? "project" : "manifest"
    buf = IOBuffer()
    function emit(line)
        write(buf, line)
        write(buf, newline)
    end
    emit("#region " * kind_str)
    emit("#!" * kind_str * " begin")

    if format === :multiline
        # Use multi-line comment format: #= ... =#
        write(buf, "#=" * newline)
        write(buf, toml)
        if !endswith(toml, newline)
            write(buf, newline)
        end
        write(buf, "=#" * newline)
    else
        # Use line-by-line format with # prefix
        lines = split(toml, '\n'; keepempty = true)
        # Remove trailing empty line if toml ends with newline
        if !isempty(lines) && isempty(lines[end])
            pop!(lines)
        end
        for raw_line in lines
            if isempty(raw_line)
                emit("#")
            else
                emit("# " * raw_line)
            end
        end
    end

    emit("#!" * kind_str * " end")
    emit("#endregion " * kind_str)
    return String(take!(buf))
end

function _find_inline_section(source::String, kind::Symbol)
    kind_str = kind === :project ? "project" : "manifest"
    begin_marker = "#!$(kind_str) begin"
    end_marker = "#!$(kind_str) end"

    # Find begin marker
    begin_idx = findfirst(begin_marker, source)
    begin_idx === nothing && return nothing

    # Find end marker after begin
    end_idx = findnext(end_marker, source, last(begin_idx) + 1)
    end_idx === nothing && return nothing

    # Determine newline style
    newline = contains(source, "\r\n") ? "\r\n" : "\n"

    # Find the start of the line containing begin marker
    line_start = findprev(isequal('\n'), source, first(begin_idx))
    line_start = line_start === nothing ? 1 : line_start + 1

    # Check if there's a #region marker on the line before
    region_marker = "#region $(kind_str)"
    if line_start > 1
        prev_line_end = line_start - 1  # This is the newline character
        prev_line_start = findprev(isequal('\n'), source, prev_line_end - 1)
        prev_line_start = prev_line_start === nothing ? 1 : prev_line_start + 1
        prev_line = source[prev_line_start:prev_line_end-1]
        if strip(prev_line) == region_marker
            line_start = prev_line_start
        end
    end

    # Determine format by checking if there's a #= after the begin marker
    # Look at content between begin and end markers
    content_start = last(begin_idx) + 1
    content_end = first(end_idx) - 1
    content_between = source[content_start:content_end]
    format = contains(content_between, "#=") ? :multiline : :line

    # Find the newline after the end marker
    char_after_end = last(end_idx) < lastindex(source) ? source[nextind(source, last(end_idx))] : nothing
    included_newline = false
    span_end_pos = if char_after_end == '\n' || (char_after_end == '\r' && last(end_idx) + 1 < lastindex(source) && source[last(end_idx) + 2] == '\n')
        # Include the newline in the span
        included_newline = true
        char_after_end == '\r' ? last(end_idx) + 2 : last(end_idx) + 1
    else
        last(end_idx)
    end

    # Check if there's a #endregion marker on the next line after end marker
    endregion_marker = "#endregion $(kind_str)"
    if included_newline && span_end_pos < lastindex(source)
        # If we included a newline, start looking at the next character
        next_line_start = span_end_pos + 1
        next_line_end = findnext(isequal('\n'), source, next_line_start)
        if next_line_end !== nothing
            next_line = source[next_line_start:next_line_end-1]
            if strip(next_line) == endregion_marker
                # Include the #endregion line and its newline in the span
                span_end_pos = next_line_end + 1
            end
        elseif next_line_start <= lastindex(source)
            # No newline found, check if rest of file is the endregion marker
            next_line = source[next_line_start:end]
            if strip(next_line) == endregion_marker
                span_end_pos = lastindex(source)
            end
        end
    end

    return (
        span_start = line_start,
        span_end = span_end_pos,
        newline = newline,
        format = format
    )
end

function _update_inline_section!(path::AbstractString, kind::Symbol, toml::String)
    source = read(path, String)
    section = _find_inline_section(source, kind)

    if section === nothing
        # No existing section, add appropriately
        newline = contains(source, "\r\n") ? "\r\n" : "\n"
        replacement = _render_inline_block(kind, toml, newline, :line)

        if kind === :project
            # Project goes at the beginning
            new_source = isempty(source) ? replacement : replacement * newline * source
        else
            # Manifest goes at the bottom
            project_section = _find_inline_section(source, :project)
            if project_section === nothing
                # No project section either, add empty project at top and manifest at bottom
                project_block = _render_inline_block(:project, "", newline, :line)
                if isempty(source)
                    new_source = project_block * newline * replacement
                else
                    new_source = project_block * newline * source * newline * replacement
                end
            else
                # Add manifest at the bottom of the file
                replacement = _render_inline_block(kind, toml, project_section.newline, project_section.format)
                new_source = source * project_section.newline * replacement
            end
        end
    else
        # Replace existing section
        replacement = _render_inline_block(kind, toml, section.newline, section.format)
        prefix = section.span_start == firstindex(source) ? "" : source[firstindex(source):prevind(source, section.span_start)]
        suffix = section.span_end == lastindex(source) ? "" : source[nextind(source, section.span_end):lastindex(source)]
        # Add a blank line after the section if there's content after it
        separator = !isempty(suffix) && !startswith(suffix, section.newline) ? section.newline : ""
        new_source = prefix * replacement * separator * suffix
    end

    open(path, "w") do io
        write(io, new_source)
    end
    return nothing
end

function remove_inline_section!(path::AbstractString, kind::Symbol)
    source = read(path, String)
    section = _find_inline_section(source, kind)

    if section !== nothing
        prefix = section.span_start == firstindex(source) ? "" : source[firstindex(source):prevind(source, section.span_start)]
        suffix = section.span_end >= lastindex(source) ? "" : source[nextind(source, section.span_end):lastindex(source)]
        new_source = prefix * suffix
        open(path, "w") do io
            write(io, new_source)
        end
    end
    return nothing
end

function update_inline_project!(path::AbstractString, toml::String)
    return _update_inline_section!(path, :project, toml)
end

function update_inline_manifest!(path::AbstractString, toml::String)
    return _update_inline_section!(path, :manifest, toml)
end

###############
# PackageSpec #
###############
@enum(UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR)
@enum(PreserveLevel, PRESERVE_ALL_INSTALLED, PRESERVE_ALL, PRESERVE_DIRECT, PRESERVE_SEMVER, PRESERVE_TIERED, PRESERVE_TIERED_INSTALLED, PRESERVE_NONE)
@enum(PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST, PKGMODE_COMBINED)

const VersionTypes = Union{VersionNumber, VersionSpec, UpgradeLevel}

Base.@kwdef mutable struct GitRepo
    source::Union{Nothing, String} = nothing
    rev::Union{Nothing, String} = nothing
    subdir::Union{String, Nothing} = nothing
end

Base.:(==)(r1::GitRepo, r2::GitRepo) =
    r1.source == r2.source && r1.rev == r2.rev && r1.subdir == r2.subdir
Base.hash(r::GitRepo, h::UInt) =
    foldr(hash, [r.source, r.rev, r.subdir], init = h)

mutable struct PackageSpec
    name::Union{Nothing, String}
    uuid::Union{Nothing, UUID}
    version::Union{Nothing, VersionTypes, String}
    tree_hash::Union{Nothing, SHA1}
    repo::GitRepo # private
    path::Union{Nothing, String}
    pinned::Bool
    # used for input only
    url::Union{Nothing, String}
    rev::Union{Nothing, String}
    subdir::Union{Nothing, String}
end
function PackageSpec(;
        name::Union{Nothing, AbstractString} = nothing,
        uuid::Union{Nothing, UUID, AbstractString} = nothing,
        version::Union{Nothing, VersionTypes, AbstractString} = VersionSpec(),
        tree_hash::Union{Nothing, SHA1} = nothing,
        repo::GitRepo = GitRepo(),
        path::Union{Nothing, AbstractString} = nothing,
        pinned::Bool = false,
        url = nothing,
        rev = nothing,
        subdir = nothing,
    )
    uuid = uuid === nothing ? nothing : UUID(uuid)
    return PackageSpec(name, uuid, version, tree_hash, repo, path, pinned, url, rev, subdir)
end
PackageSpec(name::AbstractString) = PackageSpec(; name = name)::PackageSpec
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(; name = name, uuid = uuid)::PackageSpec
PackageSpec(name::AbstractString, version::VersionTypes) = PackageSpec(; name = name, version = version)::PackageSpec
PackageSpec(n::AbstractString, u::UUID, v::VersionTypes) = PackageSpec(; name = n, uuid = u, version = v)::PackageSpec

# XXX: These definitions are a bit fishy. It seems to be used in an `==` call in status printing
function Base.:(==)(a::PackageSpec, b::PackageSpec)
    return a.name == b.name && a.uuid == b.uuid && a.version == b.version &&
        a.tree_hash == b.tree_hash && a.repo == b.repo && a.path == b.path &&
        a.pinned == b.pinned
end
function Base.hash(a::PackageSpec, h::UInt)
    return foldr(hash, [a.name, a.uuid, a.version, a.tree_hash, a.repo, a.path, a.pinned], init = h)
end

function err_rep(pkg::PackageSpec; quotes::Bool = true)
    x = pkg.name !== nothing && pkg.uuid !== nothing ? x = "$(pkg.name) [$(string(pkg.uuid)[1:8])]" :
        pkg.name !== nothing ? pkg.name :
        pkg.uuid !== nothing ? string(pkg.uuid)[1:8] :
        pkg.repo.source
    return quotes ? "`$x`" : x
end

has_name(pkg::PackageSpec) = pkg.name !== nothing
has_uuid(pkg::PackageSpec) = pkg.uuid !== nothing
isresolved(pkg::PackageSpec) = pkg.uuid !== nothing && pkg.name !== nothing

function Base.show(io::IO, pkg::PackageSpec)
    vstr = repr(pkg.version)
    f = Pair{String, Any}[]

    pkg.name !== nothing && push!(f, "name" => pkg.name)
    pkg.uuid !== nothing && push!(f, "uuid" => pkg.uuid)
    pkg.tree_hash !== nothing && push!(f, "tree_hash" => pkg.tree_hash)
    pkg.path !== nothing && push!(f, "path" => pkg.path)
    pkg.url !== nothing && push!(f, "url" => pkg.url)
    pkg.rev !== nothing && push!(f, "rev" => pkg.rev)
    pkg.subdir !== nothing && push!(f, "subdir" => pkg.subdir)
    pkg.pinned && push!(f, "pinned" => pkg.pinned)
    push!(f, "version" => (vstr == "VersionSpec(\"*\")" ? "*" : vstr))
    if pkg.repo.source !== nothing
        push!(f, "repo/source" => string("\"", pkg.repo.source::String, "\""))
    end
    if pkg.repo.rev !== nothing
        push!(f, "repo/rev" => pkg.repo.rev)
    end
    if pkg.repo.subdir !== nothing
        push!(f, "repo/subdir" => pkg.repo.subdir)
    end
    print(io, "PackageSpec(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", string(value)::String, "\n")
    end
    return print(io, ")")
end

############
# EnvCache #
############

function projectfile_path(env_path::String; strict = false)
    for name in Base.project_names
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    return strict ? nothing : joinpath(env_path, "Project.toml")
end

function manifestfile_path(env_path::String; strict = false)
    for name in (Base.manifest_names..., "AppManifest.toml")
        maybe_file = joinpath(env_path, name)
        isfile(maybe_file) && return maybe_file
    end
    if strict
        return nothing
    else
        # given no matching manifest exists, if JuliaProject.toml is used,
        # prefer to create JuliaManifest.toml, otherwise Manifest.toml
        project, _ = splitext(basename(projectfile_path(env_path)::String))
        if project == "JuliaProject"
            return joinpath(env_path, "JuliaManifest.toml")
        else
            return joinpath(env_path, "Manifest.toml")
        end
    end
end

function find_project_file(env::Union{Nothing, String} = nothing)
    project_file = nothing
    if env isa Nothing
        project_file = Base.active_project()
        project_file === nothing && pkgerror("no active project")
    elseif startswith(env, '@')
        project_file = Base.load_path_expand(env)
        project_file === nothing && pkgerror("package environment does not exist: $env")
    elseif env isa String
        if isfile(env)
            project_file = abspath(env)
        elseif isdir(env)
            isempty(readdir(env)) || pkgerror("environment is a package directory: $env")
            project_file = joinpath(env, Base.project_names[end])
        else
            project_file = endswith(env, ".toml") ? abspath(env) :
                abspath(env, Base.project_names[end])
        end
    end
    if isfile(project_file) && !contains(basename(project_file), "Project") && !endswith(project_file, ".jl")
        pkgerror(
            """
            The active project has been set to a file that isn't a Project file: $project_file
            The project path must be to a Project file or directory or a julia file.
            """
        )
    end
    @assert project_file isa String &&
        (
        isfile(project_file) || !ispath(project_file) ||
            isdir(project_file) && isempty(readdir(project_file))
    )
    return Pkg.safe_realpath(project_file)
end

Base.@kwdef mutable struct Compat
    val::VersionSpec
    str::String
end
Base.:(==)(t1::Compat, t2::Compat) = t1.val == t2.val
Base.hash(t::Compat, h::UInt) = hash(t.val, h)

struct AppInfo
    name::String
    julia_command::Union{String, Nothing}
    submodule::Union{String, Nothing}
    julia_flags::Vector{String}
    other::Dict{String, Any}
end
Base.@kwdef mutable struct Project
    other::Dict{String, Any} = Dict{String, Any}()
    # Fields
    name::Union{String, Nothing} = nothing
    uuid::Union{UUID, Nothing} = nothing
    version::Union{VersionTypes, Nothing} = nothing
    manifest::Union{String, Nothing} = nothing
    entryfile::Union{String, Nothing} = nothing
    # Sections
    deps::Dict{String, UUID} = Dict{String, UUID}()
    # deps that are also in weakdeps for backwards compat
    # we do not store them in deps because we want to ignore them
    # but for writing out the project file we need to remember them:
    _deps_weak::Dict{String, UUID} = Dict{String, UUID}()
    weakdeps::Dict{String, UUID} = Dict{String, UUID}()
    exts::Dict{String, Union{Vector{String}, String}} = Dict{String, String}()
    extras::Dict{String, UUID} = Dict{String, UUID}()
    targets::Dict{String, Vector{String}} = Dict{String, Vector{String}}()
    apps::Dict{String, AppInfo} = Dict{String, AppInfo}()
    compat::Dict{String, Compat} = Dict{String, Compat}()
    sources::Dict{String, Dict{String, String}} = Dict{String, Dict{String, String}}()
    workspace::Dict{String, Any} = Dict{String, Any}()
    readonly::Bool = false
end
Base.:(==)(t1::Project, t2::Project) = all(x -> (getfield(t1, x) == getfield(t2, x))::Bool, fieldnames(Project))
Base.hash(t::Project, h::UInt) = foldr(hash, [getfield(t, x) for x in fieldnames(Project)], init = h)


Base.@kwdef mutable struct PackageEntry
    name::Union{String, Nothing} = nothing
    version::Union{VersionNumber, Nothing} = nothing
    path::Union{String, Nothing} = nothing
    entryfile::Union{String, Nothing} = nothing
    pinned::Bool = false
    repo::GitRepo = GitRepo()
    tree_hash::Union{Nothing, SHA1} = nothing
    deps::Dict{String, UUID} = Dict{String, UUID}()
    weakdeps::Dict{String, UUID} = Dict{String, UUID}()
    exts::Dict{String, Union{Vector{String}, String}} = Dict{String, String}()
    uuid::Union{Nothing, UUID} = nothing
    apps::Dict{String, AppInfo} = Dict{String, AppInfo}() # used by AppManifest.toml
    registries::Vector{String} = String[]
    other::Union{Dict, Nothing} = nothing
end
Base.:(==)(t1::PackageEntry, t2::PackageEntry) = t1.name == t2.name &&
    t1.version == t2.version &&
    t1.path == t2.path &&
    t1.entryfile == t2.entryfile &&
    t1.pinned == t2.pinned &&
    t1.repo == t2.repo &&
    t1.tree_hash == t2.tree_hash &&
    t1.deps == t2.deps &&
    t1.weakdeps == t2.weakdeps &&
    t1.exts == t2.exts &&
    t1.uuid == t2.uuid &&
    t1.apps == t2.apps &&
    t1.registries == t2.registries
# omits `other`
Base.hash(x::PackageEntry, h::UInt) = foldr(hash, [x.name, x.version, x.path, x.entryfile, x.pinned, x.repo, x.tree_hash, x.deps, x.weakdeps, x.exts, x.uuid, x.registries], init = h)  # omits `other`

"""
    ManifestRegistryEntry

Metadata about a registry referenced from a manifest. `id` is the stable key written
to the manifest (typically the registry name, falling back to UUID on collision).
Only `uuid` and `url` are written to the manifest file.
"""
Base.@kwdef mutable struct ManifestRegistryEntry
    id::String
    uuid::UUID
    url::Union{Nothing, String} = nothing
end
Base.:(==)(t1::ManifestRegistryEntry, t2::ManifestRegistryEntry) =
    t1.id == t2.id &&
    t1.uuid == t2.uuid &&
    t1.url == t2.url
Base.hash(x::ManifestRegistryEntry, h::UInt) =
    foldr(hash, (x.id, x.uuid, x.url), init = h)


Base.@kwdef mutable struct Manifest
    julia_version::Union{Nothing, VersionNumber} = nothing # only set to VERSION when resolving
    project_hash::Union{Nothing, SHA1} = nothing
    manifest_format::VersionNumber = v"2.0.0"
    deps::Dict{UUID, PackageEntry} = Dict{UUID, PackageEntry}()
    registries::Dict{String, ManifestRegistryEntry} = Dict{String, ManifestRegistryEntry}()
    other::Dict{String, Any} = Dict{String, Any}()
end
Base.:(==)(t1::Manifest, t2::Manifest) = all(x -> (getfield(t1, x) == getfield(t2, x))::Bool, fieldnames(Manifest))
Base.hash(m::Manifest, h::UInt) = foldr(hash, [getfield(m, x) for x in fieldnames(Manifest)], init = h)
Base.getindex(m::Manifest, i_or_key) = getindex(m.deps, i_or_key)
Base.get(m::Manifest, key, default) = get(m.deps, key, default)
Base.setindex!(m::Manifest, i_or_key, value) = setindex!(m.deps, i_or_key, value)
Base.iterate(m::Manifest) = iterate(m.deps)
Base.iterate(m::Manifest, i::Int) = iterate(m.deps, i)
Base.length(m::Manifest) = length(m.deps)
Base.empty!(m::Manifest) = empty!(m.deps)
Base.values(m::Manifest) = values(m.deps)
Base.keys(m::Manifest) = keys(m.deps)
Base.haskey(m::Manifest, key) = haskey(m.deps, key)


function Base.show(io::IO, pkg::PackageEntry)
    f = []
    pkg.name !== nothing && push!(f, "name" => pkg.name)
    pkg.version !== nothing && push!(f, "version" => pkg.version)
    pkg.tree_hash !== nothing && push!(f, "tree_hash" => pkg.tree_hash)
    pkg.path !== nothing && push!(f, "dev/path" => pkg.path)
    pkg.pinned                  && push!(f, "pinned" => pkg.pinned)
    pkg.repo.source !== nothing && push!(f, "url/path" => "`$(pkg.repo.source)`")
    pkg.repo.rev !== nothing && push!(f, "rev" => pkg.repo.rev)
    pkg.repo.subdir !== nothing && push!(f, "subdir" => pkg.repo.subdir)
    !isempty(pkg.registries) && push!(f, "registries" => pkg.registries)
    print(io, "PackageEntry(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", value, "\n")
    end
    return print(io, ")")
end

function find_root_base_project(start_project::String)
    project_file = start_project
    while true
        base_project_file = Base.base_project(project_file)
        base_project_file === nothing && return project_file
        project_file = base_project_file
    end
    return
end

function collect_workspace(base_project_file::String, d::Dict{String, Project} = Dict{String, Project}())
    base_project = read_project(base_project_file)
    d[base_project_file] = base_project
    base_project_file_dir = dirname(base_project_file)

    projects = get(base_project.workspace, "projects", nothing)::Union{Nothing, Vector{String}}
    projects === nothing && return d
    project_paths = [abspath(base_project_file_dir, project) for project in projects]
    for project_path in project_paths
        project_file = Base.locate_project_file(abspath(project_path))
        if project_file isa String
            collect_workspace(project_file, d)
        end
    end
    return d
end

mutable struct EnvCache
    # environment info:
    env::Union{Nothing, String}
    # paths for files:
    project_file::String
    manifest_file::String
    # name / uuid of the project
    pkg::Union{PackageSpec, Nothing}
    # cache of metadata:
    project::Project
    workspace::Dict{String, Project} # paths relative to base
    manifest::Manifest
    # What these where at creation of the EnvCache
    original_project::Project
    original_manifest::Manifest
end

function EnvCache(env::Union{Nothing, String} = nothing)
    # @show env
    project_file = find_project_file(env)
    # @show project_file
    project_dir = dirname(project_file)
    # read project file
    project = read_project(project_file)
    # initialize project package
    if project.name !== nothing && project.uuid !== nothing
        project_package = PackageSpec(
            name = project.name,
            uuid = project.uuid,
            version = something(project.version, VersionNumber("0.0")),
            path = project_dir,
        )
    else
        project_package = nothing
    end

    manifest_file = project.manifest
    root_base_proj_file = find_root_base_project(project_file)
    workspace = Dict{String, Project}()
    if isfile(root_base_proj_file)
        if root_base_proj_file !== project_file
            manifest_file = manifestfile_path(dirname(root_base_proj_file))
        end
        workspace = collect_workspace(root_base_proj_file)
        delete!(workspace, abspath(project_file))
    end

    dir = abspath(project_dir)

    # Save the original project before any modifications
    original_project = deepcopy(project)

    # For .jl files, handle inline_manifest flag and fix inconsistent states
    if endswith(project_file, ".jl")
        inline_manifest = get(project.other, "inline_manifest", true)::Bool

        # Case 1: inline_manifest=false but no manifest path
        # User wants external manifest but hasn't set it up yet
        if !inline_manifest && project.manifest === nothing
            # Generate a new UUID and set manifest path
            script_uuid = string(uuid4())
            script_name = splitext(basename(project_file))[1]
            manifest_file = joinpath(depots1(), "environments", "scripts", "$(script_name)_$(script_uuid)", "Manifest.toml")
            project.manifest = manifest_file
        # Case 2: inline_manifest=true (or default) but has manifest path
        # User wants inline manifest but still has external path set
        elseif inline_manifest && project.manifest !== nothing
            # Load from external path for reading this time
            manifest_file = isabspath(project.manifest) ? project.manifest : abspath(dir, project.manifest)
            # But clear the path so it gets written inline later
            # (We'll clean up the external file in write_env)
        # Case 3: inline_manifest=false and has manifest path (consistent state)
        elseif !inline_manifest && project.manifest !== nothing
            manifest_file = isabspath(project.manifest) ? project.manifest : abspath(dir, project.manifest)
        # Case 4: inline_manifest=true and no manifest path (consistent state, default)
        else
            manifest_file = project_file
        end
    else
        # For regular .toml files, use standard logic
        manifest_file = manifest_file !== nothing ?
            (isabspath(manifest_file) ? manifest_file : abspath(dir, manifest_file)) :
            manifestfile_path(dir)::String
    end
    write_env_usage(manifest_file, "manifest_usage.toml")
    manifest = read_manifest(manifest_file)

    env′ = EnvCache(
        env,
        project_file,
        manifest_file,
        project_package,
        project,
        workspace,
        manifest,
        original_project,
        deepcopy(manifest),
    )

    return env′
end

# Convert a path from project-relative to manifest-relative
# If path is absolute, returns it as-is
function project_path_to_manifest_path(project_file::String, manifest_file::String, path::String)
    isabspath(path) && return path
    abs_path = Pkg.safe_realpath(joinpath(dirname(project_file), path))
    return relpath(abs_path, Pkg.safe_realpath(dirname(manifest_file)))
end

# Convert a path from manifest-relative to project-relative
# If path is absolute, returns it as-is
function manifest_path_to_project_path(project_file::String, manifest_file::String, path::String)
    isabspath(path) && return path
    abs_path = Pkg.safe_realpath(joinpath(dirname(manifest_file), path))
    return relpath(abs_path, Pkg.safe_realpath(dirname(project_file)))
end

include("project.jl")
include("manifest.jl")

function num_concurrent_downloads()
    val = get(ENV, "JULIA_PKG_CONCURRENT_DOWNLOADS", "8")
    num = tryparse(Int, val)
    isnothing(num) && error("Environment variable `JULIA_PKG_CONCURRENT_DOWNLOADS` expects an integer, instead found $(val)")
    if num < 1
        error("Number of concurrent downloads must be greater than 0")
    end
    return num
end
# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    io::IO = stderr_f()
    use_git_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    num_concurrent_downloads::Int = num_concurrent_downloads()

    # Registris
    registries::Vector{Registry.RegistryInstance} = Registry.reachable_registries()

    # The Julia Version to resolve with respect to
    julia_version::Union{VersionNumber, Nothing} = VERSION
end

project_uuid(env::EnvCache) = project_uuid(env.project, env.project_file)
project_uuid(project::Project, project_file::String) = @something(project.uuid, Base.dummy_uuid(project_file))
collides_with_project(env::EnvCache, pkg::PackageSpec) =
    is_project_name(env, pkg.name) || is_project_uuid(env, pkg.uuid)
is_project(env::EnvCache, pkg::PackageSpec) = is_project_uuid(env, pkg.uuid)
is_project_name(env::EnvCache, name::String) =
    env.pkg !== nothing && env.pkg.name == name
is_project_name(env::EnvCache, name::Nothing) = false
is_project_uuid(env::EnvCache, uuid::UUID) = project_uuid(env) == uuid

###########
# Context #
###########

const UPGRADABLE_STDLIBS = ["DelimitedFiles", "Statistics"]
const UPGRADABLE_STDLIBS_UUIDS = Set{UUID}()
const STDLIB = Ref{Union{DictStdLibs, Nothing}}(nothing)
function load_stdlib()
    stdlib = DictStdLibs()
    for name in readdir(stdlib_dir())
        projfile = projectfile_path(stdlib_path(name); strict = true)
        nothing === projfile && continue
        project = parse_toml(projfile)
        uuid = get(project, "uuid", nothing)::Union{String, Nothing}
        v_str = get(project, "version", nothing)::Union{String, Nothing}
        version = isnothing(v_str) ? nothing : VersionNumber(v_str)
        nothing === uuid && continue
        if name in UPGRADABLE_STDLIBS
            push!(UPGRADABLE_STDLIBS_UUIDS, UUID(uuid))
            continue
        end
        deps = UUID.(values(get(project, "deps", Dict{String, Any}())))
        weakdeps = UUID.(values(get(project, "weakdeps", Dict{String, Any}())))
        stdlib[UUID(uuid)] = StdlibInfo(name, Base.UUID(uuid), version, deps, weakdeps)
    end
    return stdlib
end

function stdlibs()
    # This maintains a compatible format for `stdlibs()`, but new code should always
    # prefer `stdlib_infos` as it is more future-proofed, by returning a structure
    # rather than a tuple of elements.
    return Dict(uuid => (info.name, info.version) for (uuid, info) in stdlib_infos())
end
function stdlib_infos()
    if STDLIB[] === nothing
        STDLIB[] = load_stdlib()
    end
    return STDLIB[]
end
is_stdlib(uuid::UUID) = uuid in keys(stdlib_infos())
# Includes former stdlibs
function is_or_was_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    return is_stdlib(uuid, julia_version) || uuid in UPGRADABLE_STDLIBS_UUIDS
end


function historical_stdlibs_check()
    return if isempty(STDLIBS_BY_VERSION)
        pkgerror("If you want to set `julia_version`, you must first populate the `STDLIBS_BY_VERSION` global constant.  Try `using HistoricalStdlibVersions`")
    end
end

# Find the entry in `STDLIBS_BY_VERSION`
# that corresponds to the requested version, and use that.
# If we can't find one, defaults to `UNREGISTERED_STDLIBS`
function get_last_stdlibs(julia_version::VersionNumber; use_historical_for_current_version = false)
    if !use_historical_for_current_version && julia_version == VERSION
        return stdlib_infos()
    end
    historical_stdlibs_check()
    last_stdlibs = UNREGISTERED_STDLIBS
    last_version = nothing

    for (version, stdlibs) in STDLIBS_BY_VERSION
        if !isnothing(last_version) && last_version > version
            pkgerror("STDLIBS_BY_VERSION must be sorted by version number")
        end
        if VersionNumber(julia_version.major, julia_version.minor, julia_version.patch) < version
            break
        end
        last_stdlibs = stdlibs
        last_version = version
    end
    # Serving different patches is safe-ish, but different majors or minors is most likely not.
    if last_version !== nothing && (last_version.major != julia_version.major || last_version.minor != julia_version.minor)
        pkgerror("Could not find a julia version in STDLIBS_BY_VERSION that matches the major & minor version of requested julia_version v$(julia_version)")
    end

    return last_stdlibs
end
# If `julia_version` is set to `nothing`, that means (essentially) treat all registered
# stdlibs as normal packages so that we get the latest versions of everything, ignoring
# julia compat.  So we set the list of stdlibs to that of only the unregistered stdlibs.
function get_last_stdlibs(::Nothing)
    historical_stdlibs_check()
    return UNREGISTERED_STDLIBS
end

# Allow asking if something is an stdlib for a particular version of Julia
function is_stdlib(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    # Only use the cache if we are asking for stdlibs in a custom Julia version
    if julia_version == VERSION
        return is_stdlib(uuid)
    end

    last_stdlibs = get_last_stdlibs(julia_version)
    # Note that if the user asks for something like `julia_version = 0.7.0`, we'll
    # fall through with an empty `last_stdlibs`, which will always return `false`.
    return uuid in keys(last_stdlibs)
end

# Return the version of a stdlib with respect to a particular Julia version, or
# `nothing` if that stdlib is not versioned.  We only store version numbers for
# stdlibs that are external and thus could be installed from their repositories,
# e.g. things like `GMP_jll`, `Tar`, etc...
function stdlib_version(uuid::UUID, julia_version::Union{VersionNumber, Nothing})
    last_stdlibs = get_last_stdlibs(julia_version)
    if !(uuid in keys(last_stdlibs))
        return nothing
    end
    return last_stdlibs[uuid].version
end

function is_unregistered_stdlib(uuid::UUID)
    historical_stdlibs_check()
    return haskey(UNREGISTERED_STDLIBS, uuid)
end

Context!(kw_context::Vector{Pair{Symbol, Any}})::Context =
    Context!(Context(); kw_context...)
function Context!(ctx::Context; kwargs...)
    for (k, v) in kwargs
        setfield!(ctx, k, v)
    end

    # Highlight for logging purposes if julia_version is set to a different version than current VERSION
    if haskey(kwargs, :julia_version) && ctx.julia_version !== nothing && ctx.julia_version != VERSION
        Pkg.printpkgstyle(
            ctx.io, :Context,
            "Pkg is operating with julia_version set to `$(ctx.julia_version)`",
            color = Base.warn_color()
        )
    end

    return ctx
end

function load_workspace_weak_deps(env::EnvCache)
    # TODO: Possible name collision between projects in a workspace?
    weakdeps = Dict{String, UUID}()
    merge!(weakdeps, env.project.weakdeps)
    for (_, proj) in env.workspace
        merge!(weakdeps, proj.weakdeps)
    end
    return weakdeps
end

# only hash the deps and compat fields as they are the only fields that affect a resolve
function workspace_resolve_hash(env::EnvCache)
    # Handle deps in both [deps] and [weakdeps]
    deps = Dict(pkg.name => pkg.uuid for pkg in Pkg.Operations.load_direct_deps(env))
    weakdeps = load_workspace_weak_deps(env)
    alldeps = merge(deps, weakdeps)
    compats = Dict(name => Pkg.Operations.get_compat_workspace(env, name) for (name, uuid) in alldeps)
    iob = IOBuffer()
    for (name, uuid) in sort!(collect(deps); by = first)
        println(iob, name, "=", uuid)
    end
    println(iob)
    for (name, uuid) in sort!(collect(weakdeps); by = first)
        println(iob, name, "=", uuid)
    end
    println(iob)
    for (name, compat) in sort!(collect(compats); by = first)
        println(iob, name, "=", compat)
    end
    str = String(take!(iob))
    return bytes2hex(sha1(str))
end


write_env_usage(source_file::AbstractString, usage_filepath::AbstractString) =
    write_env_usage([source_file], usage_filepath)

function write_env_usage(source_files, usage_filepath::AbstractString)
    # Don't record ghost usage
    source_files = filter(isfile, source_files)
    isempty(source_files) && return

    # Ensure that log dir exists
    !ispath(logdir()) && mkpath(logdir())

    usage_file = joinpath(logdir(), usage_filepath)
    timestamp = now()

    ## Atomically write usage file using process id locking
    FileWatching.mkpidlock(usage_file * ".pid", stale_age = 3) do
        usage = if isfile(usage_file)
            try
                TOML.parsefile(usage_file)
            catch err
                @warn "Failed to parse usage file `$usage_file`, ignoring." err
                Dict{String, Any}()
            end
        else
            Dict{String, Any}()
        end

        # record new usage
        for source_file in source_files
            usage[source_file] = [Dict("time" => timestamp)]
        end

        # keep only latest usage info
        for k in keys(usage)
            times = map(usage[k]) do d
                if haskey(d, "time")
                    Dates.DateTime(d["time"])
                else
                    # if there's no time entry because of a write failure be conservative and mark it as being used now
                    @debug "Usage file `$usage_filepath` has a missing `time` entry for `$k`. Marking as used `now()`"
                    Dates.now()
                end
            end
            usage[k] = [Dict("time" => maximum(times))]
        end

        try
            atomic_toml_write(usage_file, usage, sorted = true)
        catch err
            @error "Failed to write valid usage file `$usage_file`" exception = err
        end
    end
    return
end

function read_package(path::String)
    project = read_project(path)
    if project.name === nothing
        pkgerror("expected a `name` entry in project file at `$(abspath(path))`")
    end
    if project.uuid === nothing
        pkgerror("expected a `uuid` entry in project file at `$(abspath(path))`")
    end
    name = project.name
    entry_point = something(project.entryfile, joinpath("src", "$(name).jl"))
    pkgpath = joinpath(dirname(path), entry_point)
    if !isfile(pkgpath)
        pkgerror("expected the file `$pkgpath` to exist for package `$name` at `$(dirname(path))`")
    end
    return project
end

const refspecs = ["+refs/heads/*:refs/cache/heads/*"]
const refspecs_fallback = ["+refs/*:refs/cache/*"]

function looks_like_commit_hash(rev::AbstractString)
    # Commit hashes are 7-40 hex characters
    return occursin(r"^[0-9a-f]{7,40}$"i, rev)
end

function relative_project_path(project_file::String, path::String)
    # compute path relative the project
    # realpath needed to expand symlinks before taking the relative path
    return relpath(
        Pkg.safe_realpath(abspath(path)),
        Pkg.safe_realpath(dirname(project_file))
    )
end

function devpath(env::EnvCache, name::AbstractString, shared::Bool)
    @assert name != ""
    dev_dir = shared ? abspath(Pkg.devdir()) : joinpath(dirname(env.project_file), "dev")
    return joinpath(dev_dir, name)
end

function error_if_in_sysimage(pkg::PackageSpec)
    RESPECT_SYSIMAGE_VERSIONS[] || return false
    if pkg.uuid === nothing
        @error "Expected package $(pkg.name) to have a set UUID, please file a bug report."
        return false
    end
    pkgid = Base.PkgId(pkg.uuid, pkg.name)
    return if Base.in_sysimage(pkgid)
        pkgerror("Tried to develop or add by URL package $(pkgid) which is already in the sysimage, use `Pkg.respect_sysimage_versions(false)` to disable this check.")
    end
end

function handle_repo_develop!(ctx::Context, pkg::PackageSpec, shared::Bool)
    # First, check if we can compute the path easily (which requires a given local path or name)
    is_local_path = pkg.repo.source !== nothing && !isurl(pkg.repo.source)
    # Preserve whether the original source was an absolute path - needed later to decide how to store the path
    original_source_was_absolute = is_local_path && isabspath(pkg.repo.source)

    if is_local_path || pkg.name !== nothing
        # Resolve manifest-relative paths to absolute paths for file system operations
        dev_path = if is_local_path
            isabspath(pkg.repo.source) ? pkg.repo.source :
                Pkg.manifest_rel_path(ctx.env, pkg.repo.source)
        else
            devpath(ctx.env, pkg.name, shared)
        end
        if pkg.repo.subdir !== nothing
            dev_path = joinpath(dev_path, pkg.repo.subdir)
        end
        # If given an explicit local path, that needs to exist
        if is_local_path && !isdir(dev_path)
            if isfile(dev_path)
                pkgerror("Dev path `$(dev_path)` is a file, but a directory is required.")
            else
                pkgerror("Dev path `$(dev_path)` does not exist.")
            end
        end
        if isdir(dev_path)
            resolve_projectfile!(pkg, dev_path)
            error_if_in_sysimage(pkg)
            if is_local_path
                pkg.path = original_source_was_absolute ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
            else
                pkg.path = shared ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
            end
            return false
        end
    end
    # If we dev by name and it is in the Project + tracking a repo in the source we can get the repo from the Manifest
    if pkg.name !== nothing && pkg.uuid === nothing
        uuid = get(ctx.env.project.deps, pkg.name, nothing)
        if uuid !== nothing
            entry = manifest_info(ctx.env.manifest, uuid)
            if entry !== nothing
                pkg.repo.source = entry.repo.source
                pkg.repo.subdir = entry.repo.subdir
            end
        end
    end

    # Still haven't found the source, try get it from the registry
    if pkg.repo.source === nothing
        set_repo_source_from_registry!(ctx, pkg)
    end
    @assert pkg.repo.source !== nothing

    repo_path = tempname()
    cloned = false
    package_path = pkg.repo.subdir === nothing ? repo_path : joinpath(repo_path, pkg.repo.subdir)
    if !has_name(pkg)
        # Resolve manifest-relative path to absolute before passing to git
        repo_source_resolved = !isurl(pkg.repo.source) && !isabspath(pkg.repo.source) ?
            Pkg.manifest_rel_path(ctx.env, pkg.repo.source) :
            pkg.repo.source
        LibGit2.close(GitTools.ensure_clone(ctx.io, repo_path, repo_source_resolved))
        cloned = true
        resolve_projectfile!(pkg, package_path)
    end
    if pkg.repo.subdir !== nothing
        repo_name = split(pkg.repo.source, '/', keepempty = false)[end]
        # Make the develop path prettier.
        if endswith(repo_name, ".git")
            repo_name = chop(repo_name, tail = 4)
        end
        if endswith(repo_name, ".jl")
            repo_name = chop(repo_name, tail = 3)
        end
        dev_path = devpath(ctx.env, repo_name, shared)
    else
        dev_path = devpath(ctx.env, pkg.name, shared)
    end
    if isdir(dev_path)
        println(ctx.io, "Path `$(dev_path)` exists and looks like the correct repo. Using existing path.")
        new = false
    else
        mkpath(dirname(dev_path))
        if !cloned
            # Resolve manifest-relative path to absolute before passing to git
            repo_source_resolved = !isurl(pkg.repo.source) && !isabspath(pkg.repo.source) ?
                Pkg.manifest_rel_path(ctx.env, pkg.repo.source) :
                pkg.repo.source
            LibGit2.close(GitTools.ensure_clone(ctx.io, dev_path, repo_source_resolved))
        else
            mv(repo_path, dev_path)
        end
        new = true
    end
    if !has_uuid(pkg)
        resolve_projectfile!(pkg, joinpath(dev_path, pkg.repo.subdir === nothing ? "" : pkg.repo.subdir))
    end
    error_if_in_sysimage(pkg)
    # When an explicit local path was given, preserve whether it was absolute or relative
    # Otherwise, use shared flag to determine if path should be absolute (shared) or relative (local)
    if is_local_path
        pkg.path = original_source_was_absolute ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
    else
        pkg.path = shared ? dev_path : relative_project_path(ctx.env.manifest_file, dev_path)
    end
    if pkg.repo.subdir !== nothing
        pkg.path = joinpath(pkg.path, pkg.repo.subdir)
    end

    return new
end

function handle_repos_develop!(ctx::Context, pkgs::AbstractVector{PackageSpec}, shared::Bool)
    new_uuids = Set{UUID}()
    for pkg in pkgs
        new = handle_repo_develop!(ctx, pkg, shared)
        new && push!(new_uuids, pkg.uuid)
        @assert pkg.path !== nothing
        @assert has_uuid(pkg)
        pkg.repo = GitRepo() # clear repo field, no longer needed
    end
    return new_uuids
end

add_repo_cache_path(url::String) = joinpath(depots1(), "clones", string(hash(url)))

function set_repo_source_from_registry!(ctx, pkg)
    registry_resolve!(ctx.registries, pkg)
    # Didn't find the package in the registry, but maybe it exists in the updated registry
    if !isresolved(pkg)
        Pkg.Operations.update_registries(ctx; force = false)
        registry_resolve!(ctx.registries, pkg)
    end
    ensure_resolved(ctx, ctx.env.manifest, [pkg]; registry = true)
    # We might have been given a name / uuid combo that does not have an entry in the registry
    for reg in ctx.registries
        regpkg = get(reg, pkg.uuid, nothing)
        regpkg === nothing && continue
        info = Pkg.Registry.registry_info(regpkg)
        url = info.repo
        url === nothing && continue
        pkg.repo.source = url
        if info.subdir !== nothing
            pkg.repo.subdir = info.subdir
        end
        return
    end
    pkgerror("Repository for package with UUID `$(pkg.uuid)` could not be found in a registry.")
end


function handle_repo_add!(ctx::Context, pkg::PackageSpec)
    # The first goal is to populate pkg.repo.source if that wasn't given explicitly
    if pkg.repo.source === nothing
        @assert pkg.repo.rev !== nothing
        # First, we try resolving against the manifest and current registry to avoid updating registries if at all possible.
        # This also handles the case where we _only_ wish to switch the tracking branch for a package.
        manifest_resolve!(ctx.env.manifest, [pkg]; force = true)
        if isresolved(pkg)
            entry = manifest_info(ctx.env.manifest, pkg.uuid)
            if entry !== nothing
                pkg.repo.source = entry.repo.source
                pkg.repo.subdir = entry.repo.subdir
            end
        end
        if pkg.repo.source === nothing
            set_repo_source_from_registry!(ctx, pkg)
        end
    end
    @assert pkg.repo.source !== nothing

    # We now have the source of the package repo, check if it is a local path and if that exists
    repo_source = !isurl(pkg.repo.source) && !isabspath(pkg.repo.source) ?
        normpath(joinpath(dirname(ctx.env.manifest_file), pkg.repo.source)) :
        pkg.repo.source
    if !isurl(pkg.repo.source)
        if isdir(repo_source)
            git_path = joinpath(repo_source, ".git")
            if isfile(git_path)
                # Git submodule: .git is a file containing path to actual git directory
                git_ref_content = readline(git_path)
                git_info_path = joinpath(dirname(git_path), last(split(git_ref_content)))
            else
                # Regular git repo: .git is a directory
                git_info_path = git_path
            end
            if !isdir(git_info_path)
                msg = "Did not find a git repository at `$(repo_source)`"
                if isfile(joinpath(repo_source, "Project.toml")) || isfile(joinpath(repo_source, "JuliaProject.toml"))
                    msg *= ", perhaps you meant `Pkg.develop`?"
                end
                pkgerror(msg)
            end
            LibGit2.with(GitTools.check_valid_HEAD, LibGit2.GitRepo(repo_source)) # check for valid git HEAD
            LibGit2.with(LibGit2.GitRepo(repo_source)) do repo
                if LibGit2.isdirty(repo)
                    @warn "The repository at `$(repo_source)` has uncommitted changes. Consider using `Pkg.develop` instead of `Pkg.add` if you want to work with the current state of the repository."
                end
            end
            # Store the path: use the original path format (absolute vs relative) as the user provided
            # Canonicalize repo_source for consistent hashing in cache paths
            repo_source = safe_realpath(repo_source)
            pkg.repo.source = isabspath(pkg.repo.source) ? repo_source : relative_project_path(ctx.env.manifest_file, repo_source)
        else
            # For error messages, show the absolute path which is more informative than manifest-relative
            pkgerror("Path `$(repo_source)` does not exist.")
        end
    end

    return let repo_source = repo_source
        # The type-assertions below are necessary presumably due to julia#36454
        LibGit2.with(GitTools.ensure_clone(ctx.io, add_repo_cache_path(repo_source::Union{Nothing, String}), repo_source::Union{Nothing, String}; isbare = true)) do repo
            repo_source_typed = repo_source::Union{Nothing, String}
            GitTools.check_valid_HEAD(repo)
            create_cachedir_tag(dirname(add_repo_cache_path(repo_source)))
            # If the user didn't specify rev, assume they want the default (master) branch if on a branch, otherwise the current commit
            if pkg.repo.rev === nothing
                pkg.repo.rev = LibGit2.isattached(repo) ? LibGit2.branch(repo) : string(LibGit2.GitHash(LibGit2.head(repo)))
            end
            rev_or_hash = pkg.tree_hash === nothing ? pkg.repo.rev : pkg.tree_hash
            obj_branch = get_object_or_branch(repo, rev_or_hash)
            fetched = false
            if obj_branch === nothing
                fetched = true
                # For pull requests, fetch the specific PR ref
                if startswith(rev_or_hash, "pull/") && endswith(rev_or_hash, "/head")
                    pr_number = rev_or_hash[6:(end - 5)]  # Extract number from "pull/X/head"
                    pr_refspecs = ["+refs/pull/$(pr_number)/head:refs/cache/pull/$(pr_number)/head"]
                    GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs = pr_refspecs)
                    # For branch names, fetch only the specific branch
                elseif !looks_like_commit_hash(string(rev_or_hash))
                    specific_refspec = ["+refs/heads/$(rev_or_hash):refs/cache/heads/$(rev_or_hash)"]
                    GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs = specific_refspec)
                else
                    # For commit hashes, fetch all branches
                    GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs = refspecs)
                end
                obj_branch = get_object_or_branch(repo, rev_or_hash)
                # If still not found, try with broader refspec as fallback
                if obj_branch === nothing
                    GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs = refspecs_fallback)
                    obj_branch = get_object_or_branch(repo, rev_or_hash)
                end
                if obj_branch === nothing
                    pkgerror("Did not find rev $(rev_or_hash) in repository")
                end
            end
            gitobject, isbranch = obj_branch

            # If we are tracking a branch and are not pinned we want to update the repo if we haven't done that yet
            innerentry = manifest_info(ctx.env.manifest, pkg.uuid)
            ispinned = innerentry !== nothing && innerentry.pinned
            if isbranch && !fetched && !ispinned
                # Fetch only the specific branch being tracked
                specific_refspec = ["+refs/heads/$(rev_or_hash):refs/cache/heads/$(rev_or_hash)"]
                GitTools.fetch(ctx.io, repo, repo_source_typed; refspecs = specific_refspec)
                gitobject, isbranch = get_object_or_branch(repo, rev_or_hash)
            end

            # Now we have the gitobject for our ref, time to find the tree hash for it
            tree_hash_object = LibGit2.peel(LibGit2.GitTree, gitobject)
            if pkg.repo.subdir !== nothing
                try
                    tree_hash_object = tree_hash_object[pkg.repo.subdir]
                catch e
                    e isa KeyError || rethrow()
                    pkgerror("Did not find subdirectory `$(pkg.repo.subdir)`")
                end
            end
            @assert pkg.path === nothing
            pkg.tree_hash = SHA1(string(LibGit2.GitHash(tree_hash_object)))

            # If we already resolved a uuid, we can bail early if this package is already installed at the current tree_hash
            if has_uuid(pkg)
                error_if_in_sysimage(pkg)
                version_path = Pkg.Operations.source_path(ctx.env.project_file, pkg, ctx.julia_version)
                isdir(version_path) && return false
            end

            temp_path = mktempdir()
            GitTools.checkout_tree_to_path(repo, tree_hash_object, temp_path)
            resolve_projectfile!(pkg, temp_path)
            error_if_in_sysimage(pkg)

            # Now that we are fully resolved (name, UUID, tree_hash, repo.source, repo.rev), we can finally
            # check to see if the package exists at its canonical path.
            version_path = Pkg.Operations.source_path(ctx.env.project_file, pkg, ctx.julia_version)
            isdir(version_path) && return false

            # Otherwise, move the temporary path into its correct place and set read only
            mkpath(version_path)
            mv(temp_path, version_path; force = true)
            create_cachedir_tag(dirname(dirname(version_path)))
            set_readonly(version_path)
            return true
        end
    end
end

function handle_repos_add!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    new_uuids = Set{UUID}()
    for pkg in pkgs
        handle_repo_add!(ctx, pkg) && push!(new_uuids, pkg.uuid)
        @assert pkg.name !== nothing && pkg.uuid !== nothing && pkg.tree_hash !== nothing
    end
    return new_uuids
end

function resolve_projectfile!(pkg, project_path)
    project_file = projectfile_path(project_path; strict = true)
    project_file === nothing && pkgerror(
        string(
            "could not find project file (Project.toml or JuliaProject.toml) in package at `",
            something(pkg.repo.source, pkg.path, project_path), "` maybe `subdir` needs to be specified"
        )
    )
    project_data = read_package(project_file)
    if pkg.uuid === nothing || pkg.uuid == project_data.uuid
        pkg.uuid = project_data.uuid
    else
        pkgerror("UUID `$(project_data.uuid)` given by project file `$project_file` does not match given UUID `$(pkg.uuid)`")
    end
    return if pkg.name === nothing || pkg.name == project_data.name
        pkg.name = project_data.name
    else
        pkgerror("name `$(project_data.name)` given by project file `$project_file` does not match given name `$(pkg.name)`")
    end
end

get_object_or_branch(repo, rev::SHA1) =
    get_object_or_branch(repo, string(rev))

# Returns nothing if rev could not be found in repo
function get_object_or_branch(repo, rev)
    # Handle pull request references
    if startswith(rev, "pull/") && endswith(rev, "/head")
        try
            gitobject = LibGit2.GitObject(repo, "cache/" * rev)
            return gitobject, true
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
        end
    end

    try
        gitobject = LibGit2.GitObject(repo, "cache/heads/" * rev)
        return gitobject, true
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    try
        gitobject = LibGit2.GitObject(repo, "remotes/origin/" * rev)
        return gitobject, true
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    try
        gitobject = LibGit2.GitObject(repo, rev)
        return gitobject, false
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    return nothing
end

########################################
# Resolving packages from name or uuid #
########################################

function project_resolve!(env::EnvCache, pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        if has_uuid(pkg) && !has_name(pkg) && Types.is_project_uuid(env, pkg.uuid)
            pkg.name = env.pkg.name
        end
        if has_name(pkg) && !has_uuid(pkg) && Types.is_project_name(env, pkg.name)
            pkg.uuid = env.pkg.uuid
        end
    end
    return
end

# Disambiguate name/uuid package specifications using project info.
function project_deps_resolve!(env::EnvCache, pkgs::AbstractVector{PackageSpec})
    uuids = copy(env.project.deps)
    for (_, project) in env.workspace
        merge!(uuids, project.deps)
    end
    names = Dict(uuid => name for (name, uuid) in uuids)
    for pkg in pkgs
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            pkg.uuid = uuids[pkg.name]
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
    return
end

# Disambiguate name/uuid package specifications using manifest info.
function manifest_resolve!(manifest::Manifest, pkgs::AbstractVector{PackageSpec}; force = false)
    uuids = Dict{String, Vector{UUID}}()
    names = Dict{UUID, String}()
    for (uuid, entry) in manifest
        push!(get!(uuids, entry.name, UUID[]), uuid)
        names[uuid] = entry.name # can be duplicate but doesn't matter
    end
    for pkg in pkgs
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            length(uuids[pkg.name]) == 1 && (pkg.uuid = uuids[pkg.name][1])
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
    return
end

# Disambiguate name/uuid package specifications using registry info.
registry_resolve!(registries::Vector{Registry.RegistryInstance}, pkg::PackageSpec) = registry_resolve!(registries, [pkg])
function registry_resolve!(registries::Vector{Registry.RegistryInstance}, pkgs::AbstractVector{PackageSpec})
    # if there are no half-specified packages, return early
    any(pkg -> has_name(pkg) ⊻ has_uuid(pkg), pkgs) || return
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            pkg.uuid = registered_uuid(registries, pkg.name)
        end
        if has_uuid(pkg) && !has_name(pkg)
            pkg.name = registered_name(registries, pkg.uuid)
        end
    end
    return pkgs
end

function stdlib_resolve!(pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            for (uuid, info) in stdlib_infos()
                if info.name == pkg.name
                    pkg.uuid = uuid
                end
            end
        end
        if !has_name(pkg) && has_uuid(pkg)
            info = get(stdlib_infos(), pkg.uuid, nothing)
            if info !== nothing
                pkg.name = info.name
            end
        end
    end
    return
end

include("fuzzysorting.jl")

# Ensure that all packages are fully resolved
function ensure_resolved(
        ctx::Context, manifest::Manifest,
        pkgs::AbstractVector{PackageSpec};
        registry::Bool = false,
    )::Nothing
    unresolved_uuids = Dict{String, Vector{UUID}}()
    for pkg in pkgs
        has_uuid(pkg) && continue
        !has_name(pkg) && pkgerror("Package $pkg has neither name nor uuid")
        uuids = [uuid for (uuid, entry) in manifest if entry.name == pkg.name]
        sort!(uuids, by = uuid -> uuid.value)
        unresolved_uuids[pkg.name] = uuids
    end
    unresolved_names = UUID[]
    for pkg in pkgs
        has_name(pkg) && continue
        push!(unresolved_names, pkg.uuid)
    end
    isempty(unresolved_uuids) && isempty(unresolved_names) && return
    msg = sprint(context = ctx.io) do io
        if !isempty(unresolved_uuids)
            print(io, "The following package names could not be resolved:")
            for (name, uuids) in sort!(collect(unresolved_uuids), by = lowercase ∘ first)
                print(io, "\n * $name (")
                if length(uuids) == 0
                    what = ["project", "manifest"]
                    registry && push!(what, "registry")
                    print(io, "not found in ")
                    join(io, what, ", ", " or ")
                    print(io, ")")
                    all_names = available_names(ctx; manifest, include_registries = registry)
                    all_names_ranked, any_score_gt_thresh = FuzzySorting.fuzzysort(name, all_names)
                    if any_score_gt_thresh
                        println(io)
                        prefix = "   Suggestions:"
                        printstyled(io, prefix, color = Base.info_color())
                        FuzzySorting.printmatches(io, name, all_names_ranked; cols = FuzzySorting._displaysize(ctx.io)[2] - length(prefix))
                    end
                else
                    join(io, uuids, ", ", " or ")
                    print(io, " in manifest but not in project)")
                end
            end
        end
        if !isempty(unresolved_names)
            println(io, "The following package uuids could not be resolved:")
            for uuid in unresolved_names
                println(io, " * $uuid")
            end
        end
    end
    pkgerror(msg)
end

function available_names(ctx::Context = Context(); manifest::Manifest = ctx.env.manifest, include_registries::Bool = true)
    all_names = String[]
    for (_, pkgentry) in manifest
        push!(all_names, pkgentry.name)
    end
    if include_registries
        for reg in ctx.registries
            for (_, pkgentry) in reg.pkgs
                push!(all_names, pkgentry.name)
            end
        end
    end
    return unique(all_names)
end

function registered_uuids(registries::Vector{Registry.RegistryInstance}, name::String)
    uuids = Set{UUID}()
    for reg in registries
        union!(uuids, Registry.uuids_from_name(reg, name))
    end
    return uuids
end
# Determine a single UUID for a given name, prompting if needed
function registered_uuid(registries::Vector{Registry.RegistryInstance}, name::String)::Union{Nothing, UUID}
    uuids = registered_uuids(registries, name)
    length(uuids) == 0 && return nothing
    length(uuids) == 1 && return first(uuids)
    repo_infos = Tuple{String, String, UUID}[]
    for uuid in uuids
        for reg in registries
            pkg = get(reg, uuid, nothing)
            pkg === nothing && continue
            info = Pkg.Registry.registry_info(pkg)
            repo = info.repo
            repo === nothing && continue
            push!(repo_infos, (reg.name, repo, uuid))
        end
    end
    pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
end

# Determine current name for a given package UUID

function registered_name(registries::Vector{Registry.RegistryInstance}, uuid::UUID)::Union{Nothing, String}
    name = nothing
    for reg in registries
        regpkg = get(reg, uuid, nothing)
        regpkg === nothing && continue
        name′ = regpkg.name
        if name !== nothing
            name′ == name || pkgerror("package `$uuid` has multiple registered name values: $name, $name′")
        end
        name = name′
    end
    return name
end

# Find package by UUID in the manifest file
manifest_info(::Manifest, uuid::Nothing) = nothing
function manifest_info(manifest::Manifest, uuid::UUID)::Union{PackageEntry, Nothing}
    return get(manifest, uuid, nothing)
end
function write_env(
        env::EnvCache; update_undo = true,
        skip_writing_project::Bool = false,
        skip_readonly_check::Bool = false
    )
    # Verify that the generated manifest is consistent with `sources`
    for (pkg, uuid) in env.project.deps
        path, repo = get_path_repo(env.project, env.project_file, env.manifest_file, pkg)
        entry = manifest_info(env.manifest, uuid)
        if path !== nothing
            @assert normpath(entry.path) == normpath(path)
        end
        if repo != GitRepo()
            if repo.rev !== nothing
                @assert entry.repo.rev == repo.rev
            end
            if entry.repo.subdir !== nothing
                @assert entry.repo.subdir == repo.subdir
            end
        end
        if entry !== nothing
            if entry.path !== nothing
                # Convert path from manifest-relative to project-relative before writing
                project_relative_path = manifest_path_to_project_path(env.project_file, env.manifest_file, entry.path)
                env.project.sources[pkg] = Dict("path" => project_relative_path)
            elseif entry.repo != GitRepo()
                d = Dict{String, String}()
                entry.repo.source !== nothing && (d["url"] = entry.repo.source)
                entry.repo.rev !== nothing && (d["rev"] = entry.repo.rev)
                entry.repo.subdir !== nothing && (d["subdir"] = entry.repo.subdir)
                env.project.sources[pkg] = d
            end
        end
    end

    # Check if the environment is readonly before attempting to write
    if env.project.readonly && !skip_readonly_check
        pkgerror("Cannot modify a readonly environment. The project at $(env.project_file) is marked as readonly.")
    end

    # Handle transitions for portable scripts
    transitioning_to_inline = false
    if endswith(env.project_file, ".jl")
        inline_manifest = get(env.project.other, "inline_manifest", true)::Bool

        # If transitioning to inline and we had an external manifest, clean it up
        if inline_manifest && env.project.manifest !== nothing
            transitioning_to_inline = true
            external_manifest_path = isabspath(env.project.manifest) ? env.project.manifest :
                abspath(dirname(env.project_file), env.project.manifest)
            # Clear the manifest path so it writes inline
            env.project.manifest = nothing
            # Update manifest_file to point to the script file for inline writing
            env.manifest_file = env.project_file
            # Clean up external manifest directory
            external_dir = dirname(external_manifest_path)
            if isdir(external_dir)
                rm(external_dir; recursive=true, force=true)
            end
        end
    end

    if (env.project != env.original_project) && (!skip_writing_project)
        write_project(env, skip_readonly_check)
    end
    # Force manifest write when transitioning to inline, even if manifest hasn't changed
    if env.manifest != env.original_manifest || transitioning_to_inline
        write_manifest(env)
    end

    # Remove inline manifest section if we have external manifest
    if endswith(env.project_file, ".jl")
        inline_manifest = get(env.project.other, "inline_manifest", true)::Bool
        if !inline_manifest
            # Remove the inline manifest section since we're using external
            remove_inline_section!(env.project_file, :manifest)
        end
    end

    return update_undo && Pkg.API.add_snapshot_to_undo(env)
end


end # module
