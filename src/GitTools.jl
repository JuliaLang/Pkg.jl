# This file is a part of Julia. License is MIT: https://julialang.org/license

module GitTools

using ..Pkg
using ..MiniProgressBars
import ..can_fancyprint, ..printpkgstyle, ..stdout_f
using SHA
import Base: SHA1
import LibGit2
using Printf
using ArtifactDownloads.GitTreeHashTools: GitMode, gitmode, blob_hash, contains_files, tree_hash

use_cli_git() = Base.get_bool_env("JULIA_PKG_USE_CLI_GIT", false)
const RESOLVING_DELTAS_HEADER = "Resolving Deltas:"

# Check if LibGit2 supports shallow clones (requires LibGit2 >= 1.7.0)
# We check both the LibGit2 version and the existence of `isshallow` to ensure
# the shallow clone functionality is available
function supports_shallow_clone()
    # This seems buggy on Windows? Get some weird CI errors with it.
    if Sys.iswindows()
        return false
    end
    has_version = @static if isdefined(LibGit2, :VERSION)
        LibGit2.VERSION >= v"1.7.0"
    else
        false
    end
    has_isshallow = isdefined(LibGit2, :isshallow)
    return has_version && has_isshallow
end

# Check if a URL is a local path or file:// URL
# Shallow clones are only supported for network protocols (HTTP, HTTPS, Git, SSH)
function is_local_repo(url::AbstractString)
    # Check if it's a local filesystem path
    ispath(url) && return true
    # Check if it uses file:// protocol
    startswith(url, "file://") && return true
    return false
end

# Check if a repository is a shallow clone
function isshallow(repo::LibGit2.GitRepo)
    if supports_shallow_clone() && isdefined(LibGit2, :isshallow)
        return LibGit2.isshallow(repo)
    else
        # Fallback: check for .git/shallow file
        repo_path = LibGit2.path(repo)
        shallow_file = joinpath(repo_path, "shallow")
        return isfile(shallow_file)
    end
end

function transfer_progress(progress::Ptr{LibGit2.TransferProgress}, p::Any)
    progress = unsafe_load(progress)
    @assert haskey(p, :transfer_progress)
    bar = p[:transfer_progress]
    @assert typeof(bar) == MiniProgressBar
    if progress.total_deltas != 0
        if bar.header != RESOLVING_DELTAS_HEADER
            bar.header = RESOLVING_DELTAS_HEADER
            bar.prev = 0
        end
        bar.max = progress.total_deltas
        bar.current = progress.indexed_deltas
    else
        bar.max = progress.total_objects
        bar.current = progress.received_objects
    end
    show_progress(stdout_f(), bar)
    return Cint(0)
end

const GIT_REGEX =
    r"^(?:(?<proto>git|ssh|https)://)?(?:[\w\.\+\-:]+@)?(?<hostname>.+?)(?(<proto>)/|:)(?<path>.+?)(?:\.git)?$"
const GIT_PROTOCOLS = Dict{String, Union{Nothing, String}}()
const GIT_USERS = Dict{String, Union{Nothing, String}}()

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

function setprotocol!(;
        domain::AbstractString = "github.com",
        protocol::Union{Nothing, AbstractString} = nothing,
        user::Union{Nothing, AbstractString} = (protocol == "ssh" ? "git" : nothing)
    )
    domain = lowercase(domain)
    GIT_PROTOCOLS[domain] = protocol
    return GIT_USERS[domain] = user
end

function normalize_url(url::AbstractString)
    # LibGit2 is fussy about trailing slash. Make sure there is none.
    url = rstrip(url, '/')
    m = match(GIT_REGEX, url)
    m === nothing && return url

    host = m[:hostname]
    path = "$(m[:path]).git"

    proto = get(GIT_PROTOCOLS, lowercase(host), nothing)

    return if proto === nothing
        url
    else
        user = get(GIT_USERS, lowercase(host), nothing)
        user = user === nothing ? "" : "$user@"

        "$proto://$user$host/$path"
    end
end

function ensure_clone(io::IO, target_path, url; kwargs...)
    if ispath(target_path)
        return LibGit2.GitRepo(target_path)
    else
        return GitTools.clone(io, url, target_path; kwargs...)
    end
end

function checkout_tree_to_path(repo::LibGit2.GitRepo, tree::LibGit2.GitObject, path::String)
    return GC.@preserve path begin
        opts = LibGit2.CheckoutOptions(
            checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
            target_directory = Base.unsafe_convert(Cstring, path)
        )
        LibGit2.checkout_tree(repo, tree, options = opts)
    end
end

function clone(io::IO, url, source_path; header = nothing, credentials = nothing, isbare = false, depth::Integer = 0, kwargs...)
    url = String(url)::String
    source_path = String(source_path)::String
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = normalize_url(url)

    # Disable shallow clones for local repos (not supported) or if LibGit2 doesn't support it
    if depth > 0 && (is_local_repo(url) || !supports_shallow_clone())
        depth = 0
    end

    printpkgstyle(io, :Cloning, header === nothing ? "git-repo `$url`" : header)
    bar = MiniProgressBar(header = "Cloning:", color = Base.info_color())
    fancyprint = can_fancyprint(io)
    fancyprint && start_progress(io, bar)
    if credentials === nothing
        credentials = LibGit2.CachedCredentials()
    end
    return try
        if use_cli_git()
            args = ["--quiet"]
            depth > 0 && push!(args, "--depth=$depth")
            isbare && push!(args, "--bare")
            push!(args, url, source_path)
            cmd = `git clone $args`
            try
                run(pipeline(cmd; stdout = devnull))
            catch err
                Pkg.Types.pkgerror("The command $(cmd) failed, error: $err")
            end
            return LibGit2.GitRepo(source_path)
        else
            callbacks = if fancyprint
                LibGit2.Callbacks(
                    :transfer_progress => (
                        @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
                        bar,
                    )
                )
            else
                LibGit2.Callbacks()
            end
            mkpath(source_path)
            # Only pass depth if shallow clones are supported and depth > 0
            if depth > 0
                return LibGit2.clone(url, source_path; callbacks, credentials, isbare, depth, kwargs...)
            else
                return LibGit2.clone(url, source_path; callbacks, credentials, isbare, kwargs...)
            end
        end
    catch err
        rm(source_path; force = true, recursive = true)
        err isa LibGit2.GitError || err isa InterruptException || rethrow()
        if err isa InterruptException
            Pkg.Types.pkgerror("git clone of `$url` interrupted")
        elseif (err.class == LibGit2.Error.Net && err.code == LibGit2.Error.EINVALIDSPEC) ||
                (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ENOTFOUND)
            Pkg.Types.pkgerror("git repository not found at `$(url)`: ($(err.msg))")
        else
            Pkg.Types.pkgerror("failed to clone from $(url): ($(err.msg))")
        end
    finally
        Base.shred!(credentials)
        fancyprint && end_progress(io, bar)
    end
end

function geturl(repo)
    return LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, "origin")) do remote
        LibGit2.url(remote)
    end
end

function fetch(io::IO, repo::LibGit2.GitRepo, remoteurl = nothing; header = nothing, credentials = nothing, refspecs::Vector{String} = [""], depth::Integer = 0, kwargs...)
    if remoteurl === nothing
        remoteurl = geturl(repo)
    end

    # Disable shallow fetches for local repos (not supported) or if LibGit2 doesn't support it
    if depth > 0 && (is_local_repo(remoteurl) || !supports_shallow_clone())
        depth = 0
    end

    fancyprint = can_fancyprint(io)
    remoteurl = normalize_url(remoteurl)
    printpkgstyle(io, :Updating, header === nothing ? "git-repo `$remoteurl`" : header)
    bar = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    callbacks = if fancyprint
        LibGit2.Callbacks(
            :transfer_progress => (
                @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
                bar,
            )
        )
    else
        LibGit2.Callbacks()
    end
    fancyprint && start_progress(io, bar)
    if credentials === nothing
        credentials = LibGit2.CachedCredentials()
    end
    return try
        if use_cli_git()
            let remoteurl = remoteurl
                args = ["-C", LibGit2.path(repo), "fetch", "-q"]
                depth > 0 && push!(args, "--depth=$depth")
                push!(args, remoteurl, only(refspecs))
                cmd = `git $args`
                try
                    run(pipeline(cmd; stdout = devnull))
                catch err
                    Pkg.Types.pkgerror("The command $(cmd) failed, error: $err")
                end
            end
        else
            # Only pass depth if shallow clones are supported and depth > 0
            if depth > 0
                return LibGit2.fetch(repo; remoteurl, callbacks, credentials, refspecs, depth, kwargs...)
            else
                return LibGit2.fetch(repo; remoteurl, callbacks, credentials, refspecs, kwargs...)
            end
        end
    catch err
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ERROR)
            Pkg.Types.pkgerror("Git repository not found at '$(remoteurl)': ($(err.msg))")
        else
            Pkg.Types.pkgerror("failed to fetch from $(remoteurl): ($(err.msg))")
        end
    finally
        Base.shred!(credentials)
        fancyprint && end_progress(io, bar)
    end
end


function check_valid_HEAD(repo)
    return try
        LibGit2.head(repo)
    catch err
        url = try
            geturl(repo)
        catch
            "(unknown url)"
        end
        Pkg.Types.pkgerror("invalid git HEAD in $url ($(err.msg))")
    end
end

function git_file_stream(repo::LibGit2.GitRepo, spec::String; fakeit::Bool = false)::IO
    blob = try
        LibGit2.GitBlob(repo, spec)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
        fakeit && return devnull
    end
    iob = IOBuffer(LibGit2.content(blob))
    close(blob)
    return iob
end

end # module
