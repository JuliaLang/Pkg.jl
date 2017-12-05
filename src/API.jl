module API

import Pkg3
using Pkg3.Types
using Base.Random.UUID

previewmode_info() = info("In preview mode")

add(pkg::String; kwargs...)               = add([pkg]; kwargs...)
add(pkgs::Vector{String}; kwargs...)      = add([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
add(pkgs::Vector{PackageSpec}; kwargs...) = add(EnvCache(), pkgs; kwargs...)

function add(env::EnvCache, pkgs::Vector{PackageSpec}; preview::Bool=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    registry_resolve!(env, pkgs)
    ensure_resolved(env, pkgs, true)
    Pkg3.Operations.add(env, pkgs)
end


rm(pkg::String; kwargs...)               = rm([pkg]; kwargs...)
rm(pkgs::Vector{String}; kwargs...)      = rm([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
rm(pkgs::Vector{PackageSpec}; kwargs...) = rm(EnvCache(), pkgs; kwargs...)

function rm(env::EnvCache, pkgs::Vector{PackageSpec}; preview::Bool=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    manifest_resolve!(env, pkgs)
    Pkg3.Operations.rm(env, pkgs)
end


up(;kwargs...)                           = up(PackageSpec[], kwargs...)
up(pkg::String; kwargs...)               = up([pkg]; kwargs...)
up(pkgs::Vector{String}; kwargs...)      = up([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
up(pkgs::Vector{PackageSpec}; kwargs...) = up(EnvCache(), pkgs; kwargs...)

function up(env::EnvCache, pkgs::Vector{PackageSpec};
            level::UpgradeLevel=UpgradeLevel(:major), mode::Symbol=:project, preview::Bool=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()

    # Update the registry
    errors = Tuple{String, String}[]
    if env.preview[]
        info("Skipping updating registry in preview mode")
    else
        for reg in registries()
            if !isdir(joinpath(reg, ".git"))
                info("Registry at $reg is not a git repo, skipping update")
            end
            info("Updating registry at $reg")
            LibGit2.with(LibGit2.GitRepo, reg) do repo
                if LibGit2.isdirty(repo)
                    push!(errors, (reg, "registry dirty"))
                    return
                end
                if !LibGit2.isattached(repo)
                    push!(errors, (reg, "registry detached"))
                    return
                end
                branch = LibGit2.headname(repo)
                LibGit2.fetch(repo)
                ff_succeeded = try
                    LibGit2.merge!(repo; branch="refs/remotes/origin/$branch", fastforward=true)
                catch e
                    e isa LibGit2.GitError && e.code == LibGit2.Error.ENOTFOUND || rethrow(e)
                    push!(errors, (reg, "branch origin/$branch not found"))
                    return
                end

                if !ff_succeeded
                    try LibGit2.rebase!(repo, "origin/$branch")
                    catch e
                        e isa LibGit2.GitError || rethrow(e)
                        push!(errors, (reg, "registry failed to rebase on origin/$branch"))
                        return
                    end
                end
            end
        end
    end

    if !isempty(errors)
        warn_str = "Some registries failed to update:"
        for (reg, err) in errors
            warn_str *= "\n    — $reg — $err"
        end
        warn(warn_str)
    end

    if isempty(pkgs)
        if mode == :project
            for (name::String, uuid::UUID) in env.project["deps"]
                push!(pkgs, PackageSpec(name, uuid, level))
            end
        elseif mode == :manifest
            for (name, infos) in env.manifest, info in infos
                uuid = UUID(info["uuid"])
                push!(pkgs, PackageSpec(name, uuid, level))
            end
        end
    else
        project_resolve!(env, pkgs)
        manifest_resolve!(env, pkgs)
        ensure_resolved(env, pkgs)
    end
    Pkg3.Operations.up(env, pkgs)
end

test(;kwargs...)                           = test(PackageSpec[], kwargs...)
test(pkg::String; kwargs...)               = test([pkg]; kwargs...)
test(pkgs::Vector{String}; kwargs...)      = test([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
test(pkgs::Vector{PackageSpec}; kwargs...) = test(EnvCache(), pkgs; kwargs...)

function test(env::EnvCache, pkgs::Vector{PackageSpec}; coverage=false, preview=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    manifest_resolve!(env, pkgs)
    ensure_resolved(env, pkgs)
    Pkg3.Operations.test(env, pkgs; coverage=coverage)
end

end # module

