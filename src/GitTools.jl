# This file is a part of Julia. License is MIT: https://julialang.org/license

module GitTools

using ..Pkg
using SHA
import Base: SHA1
import LibGit2
using Printf
export set_readonly

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

ensure_clone(ctx, target_path, url; kwargs...) =
    ispath(target_path) ? LibGit2.GitRepo(target_path) : GitTools.clone(ctx, url, target_path; kwargs...)

function clone(ctx, url, source_path; header=nothing, kwargs...)
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = normalize_url(url)
    Pkg.Types.printpkgstyle(ctx, :Cloning, header == nothing ? "git-repo `$url`" : header)
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

function fetch(ctx, repo::LibGit2.GitRepo, remoteurl=nothing; header=nothing, kwargs...)
    if remoteurl === nothing
        remoteurl = LibGit2.with(LibGit2.get(LibGit2.GitRemote, repo, "origin")) do remote
            LibGit2.url(remote)
        end
    end
    remoteurl = normalize_url(remoteurl)
    Pkg.Types.printpkgstyle(ctx, :Updating, header == nothing ? "git-repo `$remoteurl`" : header)
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


# This code gratefully adapted from https://github.com/simonbyrne/GitX.jl
@enum GitMode mode_dir=0o040000 mode_normal=0o100644 mode_executable=0o100755 mode_symlink=0o120000 mode_submodule=0o160000
Base.string(mode::GitMode) = string(UInt32(mode); base=8)
Base.print(io::IO, mode::GitMode) = print(io, string(mode))

function gitmode(path::AbstractString)
    if islink(path)
        return mode_symlink
    elseif isdir(path)
        return mode_dir
    # We cannot use `Sys.isexecutable()` because on Windows, that simply calls `isfile()`
    elseif filemode(path) & 0o010 == 0o010
        return mode_executable
    else
        return mode_normal
    end
end

"""
    blob_hash(path::AbstractString)

Calculate the git blob hash of a given path.
"""
function blob_hash(path::AbstractString, HashType = SHA.SHA1_CTX)
    ctx = HashType()
    if islink(path)
        datalen = length(readlink(path))
    else
        datalen = filesize(path)
    end

    # First, the header
    SHA.update!(ctx, Vector{UInt8}("blob $(datalen)\0"))

    # Next, read data in in chunks of 4KB
    buff = Vector{UInt8}(undef, 4*1024)

    try
        if islink(path)
            update!(ctx, Vector{UInt8}(readlink(path)))
        else
            open(path, "r") do io
                while !eof(io)
                    num_read = readbytes!(io, buff)
                    update!(ctx, buff, num_read)
                end
            end
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @warn("Unable to open $(path) for hashing; git-tree-sha1 likely suspect")
    end

    # Finish it off and return the digest!
    return SHA.digest!(ctx)
end

"""
    tree_hash(root::AbstractString)

Calculate the git tree hash of a given path.  Note that attempting to take the
tree hash of an empty directory will throw an error.
"""
function tree_hash(root::AbstractString, HashType = SHA.SHA1_CTX)
    entries = Tuple{String, Vector{UInt8}, GitMode}[]
    for f in readdir(root)
        # Skip `.git` directories
        if f == ".git"
            continue
        end

        filepath = abspath(root, f)
        mode = gitmode(filepath)
        if mode == mode_dir
            try
                hash = tree_hash(filepath)
            catch e
                if isa(e, ArgumentError)
                    continue
                end
                rethrow(e)
            end
        else
            hash = blob_hash(filepath)
        end
        push!(entries, (f, hash, gitmode(filepath)))
    end

    # Sort entries by name (with trailing slashes for directories)
    sort!(entries, by = ((name, hash, mode),) -> mode == mode_dir ? name*"/" : name)

    if isempty(entries)
        ArgumentError("Invalid to calculate tree hash of empty directory")
    end
    content_size = sum(((n, h, m),) -> ndigits(UInt32(m); base=8) + 1 + sizeof(n) + 1 + 20, entries)

    # Return the hash of these entries
    ctx = HashType()
    SHA.update!(ctx, Vector{UInt8}("tree $(content_size)\0"))
    for (name, hash, mode) in entries
        SHA.update!(ctx, Vector{UInt8}("$(mode) $(name)\0"))
        SHA.update!(ctx, hash)
    end
    return SHA.digest!(ctx)
end

function set_readonly(path)
    for (root, dirs, files) in walkdir(path)
        for file in files
            filepath = joinpath(root, file)
            fmode = filemode(filepath)
            try
                chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
            catch
            end
        end
    end
    return nothing
end

end # module
