module GitOps

import LibGit2
import Base: SHA1
using  UUIDs
import ..GitRepos, ..PackageResolve, ..RegistryOps, ..GitTools, ..depots1, ..devdir
using  ..PackageSpecs, ..Contexts, ..PkgErrors, ..Utils
import ..PkgSpecUtils: find_installed # TODO use `source_path` instead

function fresh_clone(ctx::Context, pkg::PackageSpec)
    clone_path = joinpath(depots1(), "clones")
    mkpath(clone_path)
    repo_path = joinpath(clone_path, string(hash(pkg.repo.url), "_full"))
    # make sure you have a fresh clone
    repo = nothing
    try
        repo = GitTools.ensure_clone(ctx, repo_path, pkg.repo.url)
        Base.shred!(LibGit2.CachedCredentials()) do creds
            GitTools.fetch(ctx, repo, pkg.repo.url; refspecs=refspecs, credentials=creds)
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
    # TODO change to `source_path`
    version_path = find_installed(pkg.name, pkg.uuid, pkg.tree_hash)
    if cached_repo === nothing
        cached_repo = repo_checkout(ctx, clone, string(pkg.tree_hash))
    end
    isdir(version_path) && return false
    mkpath(version_path)
    mv(cached_repo, version_path; force=true)
    return true
end

function guess_rev(ctx::Context, repo_path)::String
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

clone_path(url) = joinpath(depots1(), "clones", string(hash(url)))
# TODO refactor this into `clone_to_path`
function clone_path!(ctx::Context, url)
    clone = clone_path(url)
    mkpath(dirname(clone))
    Base.shred!(LibGit2.CachedCredentials()) do creds
        LibGit2.with(GitTools.ensure_clone(ctx, clone, url; isbare=true, credentials=creds)) do repo
            GitTools.fetch(ctx, repo; refspecs=refspecs, credentials=creds)
        end
    end
    return clone
end

function repo_checkout(ctx::Context, repo_path, rev)
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

function tree_hash(ctx::Context, repo_path, rev)
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

get_object_branch(ctx::Context, repo, rev::SHA1, creds) =
    get_object_branch(ctx, repo, string(rev), creds)

function get_object_branch(ctx::Context, repo, rev, creds)
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
            GitTools.fetch(ctx, repo; refspecs=refspecs, credentials=creds)
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

end #module
