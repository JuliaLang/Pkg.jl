module GitOps

import LibGit2
import Base: SHA1
using  UUIDs
import ..PkgSpecUtils, ..GitTools, ..depots1
using  ..Contexts, ..PackageSpecs, ..PkgErrors, ..Utils

clonedir() = joinpath(depots1(), "clones")
clonepath(url) = joinpath(clonedir(), string(hash(url)))

function gitrepo(ctx::Context, target_path::String, url::String; kwargs...)
    ispath(target_path) && return LibGit2.GitRepo(target_path)
    return clone(ctx, url, target_path; kwargs...)
end

function fresh_clone(ctx::Context, pkg::PackageSpec)
    mkpath(clonedir())
    repo_path = joinpath(clonepath(pkg.repo.url), "_full")
    # make sure you have a fresh clone
    repo = nothing
    try
        repo = gitrepo(ctx, repo_path, pkg.repo.url)
        Base.shred!(LibGit2.CachedCredentials()) do creds
            fetch(ctx, repo, pkg.repo.url; refspecs=refspecs, credentials=creds)
        end
    finally
        repo isa LibGit2.GitRepo && LibGit2.close(repo)
    end
    # Copy the repo to a temporary place and check out the rev
    temp_repo = mktempdir()
    cp(repo_path, temp_repo; force=true)
    git_checkout_latest!(ctx, temp_repo)
    return temp_repo
end

function instantiate_pkg_repo!(ctx::Context, pkg::PackageSpec, cached_repo::Union{Nothing,String}=nothing)
    pkg.special_action = PKGSPEC_REPO_ADDED
    clone = clone_path!(ctx, pkg.repo.url)
    pkg.tree_hash = tree_hash(ctx, clone, pkg.repo.rev)
    version_path = PkgSpecUtils.source_path(pkg)
    if cached_repo === nothing
        cached_repo = repo_checkout(ctx, clone, string(pkg.tree_hash))
    end
    isdir(version_path) && return false
    mkpath(version_path)
    mv(cached_repo, version_path; force=true)
    return true
end

function guess_rev(ctx::Context, repo_path::String)::String
    rev = nothing
    LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
        rev = LibGit2.isattached(repo) ?
            LibGit2.branch(repo) :
            string(LibGit2.GitHash(LibGit2.head(repo)))
        gitobject, isbranch = nothing, nothing
        Base.shred!(LibGit2.CachedCredentials()) do creds
            gitobject, isbranch = get_object_branch(ctx, repo, rev, creds)
        end
        LibGit2.with(gitobject) do object
            rev = isbranch ? rev : string(LibGit2.GitHash(gitobject))
        end
    end
    return rev
end

const refspecs = ["+refs/*:refs/remotes/cache/*"]

# TODO refactor this into `clone_to_path`
function clone_path!(ctx::Context, url::String)
    mkpath(clonedir())
    clone_path = clonepath(url)
    Base.shred!(LibGit2.CachedCredentials()) do creds
        LibGit2.with(gitrepo(ctx, clone_path, url; isbare=true, credentials=creds)) do repo
            fetch(ctx, repo; refspecs=refspecs, credentials=creds)
        end
    end
    return clone_path
end

function repo_checkout(ctx::Context, repo_path::String, rev::String)
    project_path = mktempdir()
    with_git_tree(ctx, repo_path, rev) do repo, git_tree
        _project_path = project_path # https://github.com/JuliaLang/julia/issues/30048
        GC.@preserve _project_path begin
            opts = LibGit2.CheckoutOptions(
                checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
                target_directory = Base.unsafe_convert(Cstring, _project_path),
            )
            LibGit2.checkout_tree(repo, git_tree, options=opts)
        end
    end
    return project_path
end

function with_git_tree(fn, ctx::Context, repo_path::String, rev::String)
    gitobject = nothing
    Base.shred!(LibGit2.CachedCredentials()) do creds
        LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
            gitobject, isbranch = get_object_branch(ctx, repo, rev, creds)
            LibGit2.with(LibGit2.peel(LibGit2.GitTree, gitobject)) do git_tree
                @assert git_tree isa LibGit2.GitTree
                return applicable(fn, repo, git_tree) ?
                    fn(repo, git_tree) :
                    fn(git_tree)
            end
        end
    end
end

function tree_hash(ctx::Context, repo_path::String, rev::String)
    with_git_tree(ctx, repo_path, rev) do git_tree
        return SHA1(string(LibGit2.GitHash(git_tree))) # TODO can it be just SHA1?
    end
end

function git_checkout_latest!(ctx::Context, repo_path::AbstractString)
    LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
        rev = LibGit2.isattached(repo) ?
            LibGit2.branch(repo) :
            string(LibGit2.GitHash(LibGit2.head(repo)))
        gitobject, isbranch = nothing, nothing
        Base.shred!(LibGit2.CachedCredentials()) do creds
            gitobject, isbranch = get_object_branch(ctx, repo, rev, creds)
        end
        try
            LibGit2.transact(repo) do r
                if isbranch
                    LibGit2.branch!(r, rev, track=LibGit2.Consts.REMOTE_ORIGIN)
                else
                    LibGit2.checkout!(r, string(LibGit2.GitHash(gitobject)))
                end
            end
        finally
            close(gitobject)
        end
    end
end

function get_object_branch(ctx::Context, repo::LibGit2.GitRepo, rev::String, creds)
    gitobject = nothing
    isbranch = false
    try
        gitobject = LibGit2.GitObject(repo, "remotes/cache/heads/" * rev)
        isbranch = true
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
    end
    if gitobject == nothing
        try
            gitobject = LibGit2.GitObject(repo, rev)
        catch err
            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
            fetch(ctx, repo; refspecs=refspecs, credentials=creds)
            try
                gitobject = LibGit2.GitObject(repo, rev)
            catch err
                err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
                pkgerror("Git object `$(rev)` could not be found.")
            end
        end
    end
    return gitobject, isbranch
end

function clone(ctx::Context, url::String, source_path::String; header=nothing, kwargs...)
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = GitTools.normalize_url(url)
    printpkgstyle(ctx, :Cloning, header == nothing ? "git-repo `$url`" : header)
    transfer_payload = GitTools.MiniProgressBar(header = "Fetching:", color = Base.info_color())
    callbacks = LibGit2.Callbacks(
        :transfer_progress => (
            @cfunction(GitTools.transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
            transfer_payload,
        )
    )
    print(stdout, "\e[?25l") # disable cursor
    try
        return LibGit2.clone(url, source_path; callbacks=callbacks, kwargs...)
    catch err
        rm(source_path; force=true, recursive=true)
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Net && err.code == LibGit2.Error.EINVALIDSPEC) ||
           (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ENOTFOUND)
            pkgerror("Git repository not found at '$(url)'")
        else
            pkgerror("failed to clone from $(url), error: $err")
        end
    finally
        print(stdout, "\033[2K") # clear line
        print(stdout, "\e[?25h") # put back cursor
    end
end

function fetch(ctx::Context, repo::LibGit2.GitRepo, remoteurl=nothing; header=nothing, kwargs...)
    if remoteurl === nothing
        remoteurl = LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, "origin")) do remote
            LibGit2.url(remote)
        end
    end
    remoteurl = GitTools.normalize_url(remoteurl)
    printpkgstyle(ctx, :Updating, header == nothing ? "git-repo `$remoteurl`" : header)
    transfer_payload = GitTools.MiniProgressBar(header = "Fetching:", color = Base.info_color())
    callbacks = LibGit2.Callbacks(
        :transfer_progress => (
            @cfunction(GitTools.transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
            transfer_payload,
        )
    )
    print(stdout, "\e[?25l") # disable cursor
    try
        return LibGit2.fetch(repo; remoteurl=remoteurl, callbacks=callbacks, kwargs...)
    catch err
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ERROR)
            pkgerror("Git repository not found at '$(remoteurl)'")
        else
            pkgerror("failed to fetch from $(remoteurl), error: $err")
        end
    finally
        print(stdout, "\033[2K") # clear line
        print(stdout, "\e[?25h") # put back cursor
    end
end

end #module
