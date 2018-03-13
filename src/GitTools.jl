module GitTools

using ..Pkg3
import LibGit2
using Printf

Base.@kwdef mutable struct MiniProgressBar
    max::Float64 = 1
    header::String = ""
    color::Symbol = :white
    width::Int = 40
    current::Float64 = 0.0
    prev::Float64 = 0.0
    has_shown::Bool = false
end

function showprogress(io::IO, p::MiniProgressBar)
    perc = p.current / p.max * 100
    prev_perc = p.prev / p.max * 100
    # Bail early if we are not updating the progress bar,
    # Saves printing to the terminal
    if p.has_shown && !(perc - prev_perc > 0.1)
        return
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

Base.@kwdef struct GitTransferProgress
    total_objects::Cuint
    indexed_objects::Cuint
    received_objects::Cuint
    local_objects::Cuint
    total_deltas::Cuint
    indexed_deltas::Cuint
received_bytes::Csize_t
end

function transfer_progress(progress::Ptr{GitTransferProgress}, p::Any)

    progress = unsafe_load(progress)
    @assert p.transfer_progress != C_NULL
    bar = unsafe_pointer_to_objref(p.transfer_progress)
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

function clone(url, source_path; isbare::Bool=false, header = nothing, branch = nothing, credentials = nothing)
    Pkg3.Types.printpkgstyle(stdout, :Cloning, header == nothing ? string("git-repo `", url, "`") : header)
    transfer_payload = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    cred_payload = LibGit2.CredentialPayload(credentials)
    print(stdout, "\e[?25l") # disable cursor
    try
        GC.@preserve transfer_payload branch begin
            callbacks = LibGit2.RemoteCallbacks(
                credentials=(LibGit2.credentials_cb(), pointer_from_objref(cred_payload)),
                transfer_progress=(cfunction(transfer_progress, Cint, Tuple{Ptr{GitTransferProgress}, Any}), pointer_from_objref(transfer_payload)),
            )
            fetch_opts = LibGit2.FetchOptions(callbacks = callbacks)
            clone_opts = LibGit2.CloneOptions(fetch_opts=fetch_opts, bare=isbare, checkout_branch= branch == nothing ? C_NULL : Cstring(pointer(branch)))
            return LibGit2.clone(url, source_path, clone_opts)
        end
    catch e
        if isa(e, LibGit2.GitError) && e.code == LibGit2.Error.EAUTH
            LibGit2.reject(cred_payload)
        end

        rm(source_path; force=true, recursive=true)
        rethrow(e)
    finally
        print(stdout, "\033[2K") # clear line
        print(stdout, "\e[?25h") # put back cursor
    end
    LibGit2.approve(cred_payload)
end

function fetch(repo::LibGit2.GitRepo, remoteurl=nothing; header = nothing, refspecs=String[], credentials=nothing)
    remote = if remoteurl == nothing
        LibGit2.get(LibGit2.GitRemote, repo, "origin")
    else
        LibGit2.GitRemoteAnon(repo, remoteurl)
    end
    Pkg3.Types.printpkgstyle(stdout, :Updating, header == nothing ? string("git-repo `", LibGit2.url(remote), "`") : header)
    transfer_payload = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    cred_payload = LibGit2.CredentialPayload(credentials)
    print(stdout, "\e[?25l") # disable cursor
    try
        GC.@preserve transfer_payload begin
            callbacks = LibGit2.RemoteCallbacks(
                credentials=(LibGit2.credentials_cb(), pointer_from_objref(cred_payload)),
                transfer_progress=(cfunction(transfer_progress, Cint, Tuple{Ptr{GitTransferProgress}, Any}), pointer_from_objref(transfer_payload)),
            )
            fetch_opts = LibGit2.FetchOptions(callbacks = callbacks)
            return LibGit2.fetch(remote, refspecs; options=fetch_opts)
        end
    catch e
        if isa(e, LibGit2.GitError) && e.code == LibGit2.Error.EAUTH
            LibGit2.reject(cred_payload)
        end
        rethrow(e)
    finally
        close(remote)
        print(stdout, "\033[2K") # clear line
        print(stdout, "\e[?25h") # put back cursor
    end
    LibGit2.approve(cred_payload)
end

end # module