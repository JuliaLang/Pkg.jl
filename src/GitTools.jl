# This file is a part of Julia. License is MIT: https://julialang.org/license

module GitTools

using ..Pkg
import LibGit2
using Printf

Base.@kwdef mutable struct MiniProgressBar
    max::Float64 = 1.0
    header::String = ""
    color::Symbol = :white
    width::Int = 40
    current::Float64 = 0.0
    prev::Float64 = 0.0
    has_shown::Bool = false
    time_shown::Float64 = 0.0
end

const NONINTERACTIVE_TIME_GRANULARITY = Ref(2.0)
const PROGRESS_BAR_PERCENTAGE_GRANULARITY = Ref(0.1)

function showprogress(io::IO, p::MiniProgressBar)
    perc = p.current / p.max * 100
    prev_perc = p.prev / p.max * 100
    # Bail early if we are not updating the progress bar,
    # Saves printing to the terminal
    if p.has_shown && !((perc - prev_perc) > PROGRESS_BAR_PERCENTAGE_GRANULARITY[])
        return
    end
    if !isinteractive()
        t = time()
        if p.has_shown && (t - p.time_shown) < NONINTERACTIVE_TIME_GRANULARITY[]
            return
        end
        p.time_shown = t
    end
    p.prev = p.current
    p.has_shown = true
    n_filled = ceil(Int, p.width * perc / 100)
    n_left = p.width - n_filled
    print(io, "    ")
    printstyled(io, p.header, color=p.color, bold=true)
    print(io, " [")
    print(io, "="^n_filled, ">")
    print(io, " "^n_left, "]  ", )
    @printf io "%2.1f %%" perc
    print(io, "\r")
end

function transfer_progress(progress::Ptr{LibGit2.TransferProgress}, p::Any)
    progress = unsafe_load(progress)
    @assert haskey(p, :transfer_progress)
    bar = p[:transfer_progress]
    @assert typeof(bar) == MiniProgressBar
    if progress.total_deltas != 0
        bar.header = "Resolving Deltas:"
        bar.max = progress.total_deltas
        bar.current = progress.indexed_deltas
    else
        bar.max = progress.total_objects
        bar.current = progress.received_objects
    end
    showprogress(stdout, bar)
    return Cint(0)
end

const GIT_REGEX =
    r"^(?:(?<proto>git|ssh|https)://)?(?:[\w\.\+\-:]+@)?(?<hostname>.+?)(?(<proto>)/|:)(?<path>.+?)(?:\.git)?$"
const GIT_PROTOCOLS = Dict{String, Union{Nothing, String}}()
const GIT_USERS = Dict{String, Union{Nothing, String}}()

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

function setprotocol!(;
    domain::AbstractString="github.com",
    protocol::Union{Nothing, AbstractString}=nothing,
    user::Union{Nothing, AbstractString}=(protocol == "ssh" ? "git" : nothing)
)
    domain = lowercase(domain)
    GIT_PROTOCOLS[domain] = protocol
    GIT_USERS[domain] = user
end

function normalize_url(url::AbstractString)
    m = match(GIT_REGEX, url)
    m === nothing && return url

    host = m[:hostname]
    path = "$(m[:path]).git"

    proto = get(GIT_PROTOCOLS, lowercase(host), nothing)

    if proto === nothing
        url
    else
        user = get(GIT_USERS, lowercase(host), nothing)
        user = user === nothing ? "" : "$user@"

        "$proto://$user$host/$path"
    end
end

ensure_clone(target_path, url; kwargs...) =
    ispath(target_path) ? LibGit2.GitRepo(target_path) : GitTools.clone(url, target_path; kwargs...)

function clone(url, source_path; header=nothing, kwargs...)
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = normalize_url(url)
    Pkg.Types.printpkgstyle(stdout, :Cloning, header == nothing ? "git-repo `$url`" : header)
    transfer_payload = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    callbacks = LibGit2.Callbacks(
        :transfer_progress => (
            @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
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
            Pkg.Types.pkgerror("Git repository not found at '$(url)'")
        else
            Pkg.Types.pkgerror("failed to clone from $(url), error: $err")
        end
    finally
        print(stdout, "\033[2K") # clear line
        print(stdout, "\e[?25h") # put back cursor
    end
end

function fetch(repo::LibGit2.GitRepo, remoteurl=nothing; header=nothing, kwargs...)
    if remoteurl === nothing
        remoteurl = LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, "origin")) do remote
            LibGit2.url(remote)
        end
    end
    remoteurl = normalize_url(remoteurl)
    Pkg.Types.printpkgstyle(stdout, :Updating, header == nothing ? "git-repo `$remoteurl`" : header)
    transfer_payload = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    callbacks = LibGit2.Callbacks(
        :transfer_progress => (
            @cfunction(transfer_progress, Cint, (Ptr{LibGit2.TransferProgress}, Any)),
            transfer_payload,
        )
    )
    print(stdout, "\e[?25l") # disable cursor
    try
        return LibGit2.fetch(repo; remoteurl=remoteurl, callbacks=callbacks, kwargs...)
    catch err
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ERROR)
            Pkg.Types.pkgerror("Git repository not found at '$(remoteurl)'")
        else
            Pkg.Types.pkgerror("failed to fetch from $(remoteurl), error: $err")
        end
    finally
        print(stdout, "\033[2K") # clear line
        print(stdout, "\e[?25h") # put back cursor
    end
end

end # module
