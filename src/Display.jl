# This file is a part of Julia. License is MIT: https://julialang.org/license

module Display

using UUIDs
import LibGit2

using ..Types

const PackageEntry = Types.PackageEntry

const colors = Dict(
    ' ' => :white,
    '+' => :light_green,
    '-' => :light_red,
    '↑' => :light_yellow,
    '~' => :light_yellow,
    '↓' => :light_magenta,
    '?' => :red,
)
const color_dark = :light_black

function git_file_stream(repo::LibGit2.GitRepo, spec::String; fakeit::Bool=false)::IO
    blob = try LibGit2.GitBlob(repo, spec)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
        fakeit && return devnull
    end
    iob = IOBuffer(LibGit2.content(blob))
    close(blob)
    return iob
end

function status(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[];
                diff::Bool=false, mode::PackageMode=PKGMODE_PROJECT, use_as_api=false)
    env = ctx.env
    project₀ = project₁ = env.project
    manifest₀ = manifest₁ = env.manifest
    mdiff = nothing

    pkgfilter = (entry) -> begin
        for pkg in pkgs
            if pkg.uuid == entry.uuid
                return true
            end
            if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
                # also look for pkg's deps
                info = manifest_info(ctx, pkg.uuid)
                for uuid in values(info.deps)
                    if uuid == entry.uuid
                        return true
                    end
                end
            end
        end
        return false
    end
    filter_pkgs = length(pkgs) > 0

    if !use_as_api
        pkg = ctx.env.pkg
        if pkg !== nothing
           printstyled(ctx.io, "Project "; color=Base.info_color(), bold=true)
           println(ctx.io, pkg.name, " v", pkg.version)
        end
    end
    if diff
        if env.git === nothing
            @warn "diff option only available for environments in git repositories, ignoring."
        else # env.git !== nothing
            try
                LibGit2.with(LibGit2.GitRepo(env.git)) do repo
                    git_path = LibGit2.path(repo)
                    project_path = relpath(env.project_file, git_path)
                    manifest_path = relpath(env.manifest_file, git_path)
                    project₀ = read_project(git_file_stream(repo, "HEAD:$project_path", fakeit=true))
                    manifest₀ = read_manifest(git_file_stream(repo, "HEAD:$manifest_path", fakeit=true))
                end
            catch
                @warn "could not read project from HEAD, displaying absolute status instead."
            end
        end
    end
    if mode == PKGMODE_PROJECT || mode == PKGMODE_COMBINED
        # TODO: handle project deps missing from manifest
        m₀ = Dict(uuid => entry for (uuid, entry) in manifest₀ if (uuid in values(project₀.deps)))
        m₁ = Dict(uuid => entry for (uuid, entry) in manifest₁ if (uuid in values(project₁.deps)))
        mdiff = manifest_diff(ctx, m₀, m₁)
        filter_pkgs && filter!(pkgfilter, mdiff)
        if !use_as_api
            printpkgstyle(ctx, :Status, pathrepr(env.project_file), #=ignore_indent=# true)
            print_diff(ctx, mdiff, #=status=# true)
        end
    end
    if mode == PKGMODE_MANIFEST
        mdiff = manifest_diff(ctx, manifest₀, manifest₁)
        filter_pkgs && filter!(pkgfilter, mdiff)
        if !use_as_api
            printpkgstyle(ctx, :Status, pathrepr(env.manifest_file), #=ignore_indent=# true)
            print_diff(ctx, mdiff, #=status=# true)
        end
    elseif mode == PKGMODE_COMBINED
        combined = values(merge(project₀.deps, project₁.deps))
        m₀ = Dict(uuid => entry for (uuid, entry) in manifest₀ if (uuid in combined))
        m₁ = Dict(uuid => entry for (uuid, entry) in manifest₁ if (uuid in combined))
        c_diff = filter!(x->x.old != x.new, manifest_diff(ctx, m₀, m₁))
        filter_pkgs && filter!(pkgfilter, c_diff)
        if !isempty(c_diff)
            if !use_as_api
                printpkgstyle(ctx, :Status, pathrepr(env.manifest_file), #=ignore_indent=# true)
                print_diff(ctx, c_diff, #=status=# true)
            end
            mdiff = Base.vcat(c_diff, mdiff)
        end
    end
    return mdiff
end

function print_project_diff(ctx::Context, env0::EnvCache, env1::EnvCache)
    pm0 = Dict(uuid => entry for (uuid, entry) in env0.manifest if (uuid in values(env0.project.deps)))
    pm1 = Dict(uuid => entry for (uuid, entry) in env1.manifest if (uuid in values(env1.project.deps)))
    diff = filter!(x->x.old != x.new, manifest_diff(ctx, pm0, pm1))
    if isempty(diff)
        printstyled(ctx.io, color = color_dark, " [no changes]\n")
    else
        print_diff(ctx, diff)
    end
end

function print_manifest_diff(ctx::Context, env₀::EnvCache, env₁::EnvCache)
    diff = manifest_diff(ctx, env₀.manifest, env₁.manifest)
    diff = filter!(x->x.old != x.new, diff)
    if isempty(diff)
        printstyled(ctx.io, color = color_dark, " [no changes]\n")
    else
        print_diff(ctx, diff)
    end
end

struct VerInfo
    hash::Union{SHA1,Nothing}
    path::Union{String,Nothing}
    ver::Union{VersionNumber,Nothing}
    pinned::Bool
    repo::Union{Types.GitRepo, Nothing}
end

revstring(str::String) = occursin(r"\b([a-f0-9]{40})\b", str) ? str[1:7] : str

vstring(ctx::Context, a::VerInfo) =
    string((a.ver == nothing && a.hash != nothing) ? "[$(string(a.hash)[1:16])]" : "",
           a.ver != nothing ? "v$(a.ver)" : "",
           a.path != nothing ? " [$(pathrepr(a.path))]" : "",
           a.repo != nothing ? " #$(revstring(a.repo.rev)) ($(a.repo.url))" : "",
           a.pinned == true ? " ⚲" : "",
           )

Base.:(==)(a::VerInfo, b::VerInfo) =
    a.hash == b.hash && a.ver == b.ver && a.pinned == b.pinned && a.repo == b.repo &&
    a.path == b.path

≈(a::VerInfo, b::VerInfo) = a.hash == b.hash &&
    (a.ver == nothing || b.ver == nothing || a.ver == b.ver) &&
    (a.pinned == b.pinned) &&
    (a.repo == nothing || b.repo == nothing || a.repo == b.repo) &&
    (a.path == b.path)

struct DiffEntry
    uuid::UUID
    name::String
    old::Union{VerInfo,Nothing}
    new::Union{VerInfo,Nothing}
end

function print_diff(io::IO, ctx::Context, diff::Vector{DiffEntry}, status=false)
    same = all(x.old == x.new for x in diff)
    some_packages_not_downloaded = false
    for x in diff
        pkgid = Base.PkgId(x.uuid, x.name)
        package_downloaded = pkgid in keys(Base.loaded_modules) ||
                             Base.locate_package(pkgid) !== nothing
        # Package download detection doesnt work properly when runn running targets
        ctx.currently_running_target && (package_downloaded = true)
        if x.old !== nothing && x.new !== nothing
            if x.old ≈ x.new
                verb = ' '
                vstr = vstring(ctx, x.new)
            else
                if (x.old.hash === nothing || x.new.hash === nothing || x.old.hash != x.new.hash) &&
                    x.old.ver != x.new.ver
                    verb = x.old.ver == nothing || x.new.ver == nothing ||
                           x.old.ver == x.new.ver ? '~' :
                           x.old.ver < x.new.ver  ? '↑' : '↓'
                elseif x.old.ver == x.new.ver && x.old.pinned != x.new.pinned ||
                    x.old.path != x.new.path ||
                    x.old.repo != nothing || x.new.repo != nothing
                    verb = '~'
                else
                    verb = '?'
                end
                vstr = (x.old.ver == x.new.ver && x.old.pinned == x.new.pinned &&
                        x.old.repo == x.new.repo && x.old.path == x.new.path) ?
                      vstring(ctx, x.new) :
                      vstring(ctx, x.old) * " ⇒ " * vstring(ctx, x.new)
            end
        elseif x.new != nothing
            verb = '+'
            vstr = vstring(ctx, x.new)
        elseif x.old != nothing
            verb = '-'
            vstr = vstring(ctx, x.old)
        else
            verb = '?'
            vstr = "[unknown]"
        end
        v = same ? "" : " $verb"
        if verb != '-' && status && !package_downloaded
            printstyled(io, "→", color=:red)
        else
            print(io, " ")
        end
        if verb != '-'
            package_downloaded || (some_packages_not_downloaded = true)
        end
        printstyled(io, " [$(string(x.uuid)[1:8])]"; color = color_dark)
        printstyled(io, "$v $(x.name) $vstr\n"; color = colors[verb])
    end
    if isempty(diff)
        str = ctx.env.git === nothing ? "  (empty environment)\n" : "  (no changes since last commit)\n"
        printstyled(io, str, color = color_dark)
    end
    if status && some_packages_not_downloaded
        @warn "Some packages (indicated with a red arrow) are not downloaded, use `instantiate` to instantiate the current environment"
    end
end
print_diff(ctx::Context, diff::Vector{DiffEntry}, status=false) = print_diff(ctx.io, ctx, diff, status)

function name_ver_info(entry::PackageEntry)
    entry.name, VerInfo(
        entry.tree_hash,
        entry.path,
        entry.version,
        entry.pinned,
        entry.repo.url === nothing ? nothing : entry.repo, # TODO
        )
end

function manifest_diff(ctx::Context, manifest0::Dict, manifest1::Dict)
    diff = DiffEntry[]
    for uuid in union(keys(manifest0), keys(manifest1))
        name₀ = name₁ = v₀ = v₁ = nothing
        haskey(manifest0, uuid) && ((name₀, v₀) = name_ver_info(manifest0[uuid]))
        haskey(manifest1, uuid) && ((name₁, v₁) = name_ver_info(manifest1[uuid]))
        name₀ === nothing && (name₀ = name₁)
        name₁ === nothing && (name₁ = name₀)
        if name₀ == name₁
            push!(diff, DiffEntry(uuid, name₀, v₀, v₁))
        else
            push!(diff, DiffEntry(uuid, name₀, v₀, nothing))
            push!(diff, DiffEntry(uuid, name₁, nothing, v₁))
        end
    end
    sort!(diff, by=x->(x.uuid in keys(ctx.stdlibs), x.name, x.uuid))
end

end # module
