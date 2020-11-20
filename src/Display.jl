module Display

using ..Environments: Environment

#=
function stat_rep(x::PackageSpec; name=true)
    name = name ? x.name : ""
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
=#

function print_status_header(io::IO, env::Environment)
    pkg = env.project.pkg
    if pkg !== nothing
        printstyled(io, "Project "; color=Base.info_color(), bold=true)
        print(io, pkg.name)
        if pkg.version !== nothing
            println(io, " v", pkg.version)
        end
        println(io)
    end
end

#function print_package(io, uuid, name, version::Union{VersionNumber, Nothing}
    #print(io, name

function print_status_update(io::IO, env_new::Environment, env_old::Environment)

    print_status_header(io, env_new)

    # Could diff in a few things, 
    # uuids_all = 
    
    for (uuid, pkg) in env_new.project.deps
        prefix, color = "", nothing
        if !(uuid in keys(env_old.project.deps))
            prefix = "+ ", :light_green
        end
        println(io, pkg.name)
    end
end

#=
function status(ctx::Context, pkgs::Vector{PackageSpec}=PackageSpec[];
                header=nothing, mode::PackageMode=PKGMODE_PROJECT, git_diff::Bool=false, env_diff=nothing)
    ctx.io == Base.devnull && return
    # if a package, print header
    if header === nothing && ctx.env.pkg !== nothing
       printstyled(ctx.io, "Project "; color=Base.info_color(), bold=true)
       println(ctx.io, ctx.env.pkg.name, " v", ctx.env.pkg.version)
    end
    # load old ctx
    old_ctx = nothing
    if git_diff
        project_dir = dirname(ctx.env.project_file)
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
    filter_uuids = [pkg.uuid::UUID for pkg in pkgs if pkg.uuid !== nothing]
    filter_names = [pkg.name::String for pkg in pkgs if pkg.name !== nothing]
    diff = old_ctx !== nothing
    header = something(header, diff ? :Diff : :Status)
    if mode == PKGMODE_PROJECT || mode == PKGMODE_COMBINED
        print_status(ctx, old_ctx, header, filter_uuids, filter_names; manifest=false, diff=diff)
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        print_status(ctx, old_ctx, header, filter_uuids, filter_names; diff=diff)
    end
end
=#

end # module # module
