module GitTools

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

function transfer_progress(progress::Ptr{LibGit2.GitTransferProgress}, p::Any)
    progress = unsafe_load(progress)
    if progress.total_deltas != 0
        p.header = "Resolving Deltas:"
        p.max = progress.total_deltas
        p.current = progress.indexed_deltas
    else
        p.max = progress.total_objects
        p.current = progress.received_objects
    end
    showprogress(stdout, p)
    return Cint(0)
end

function clone(url, source_path; isbare::Bool=false, header = nothing, branch = nothing, credentials = nothing)
    isdir(source_path) && error("$source_path already exists")
    printstyled(stdout, "Cloning "; color = :green, bold=true)
    if header == nothing
        println(stdout, "from git repo: ", url, ".")
    else
        println(stdout, header)
    end
    transfer_payload = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    cred_payload = LibGit2.CredentialPayload(credentials)
    print(stdout, "\e[?25l")
    try
        GC.@preserve p branch begin
            callbacks = LibGit2.RemoteCallbacks(
                credentials=(LibGit2.credential_cb(), pointer_from_objref(cred_payload)),
                transfer_progress=(cfunction(transfer_progress, Cint, Tuple{Ptr{LibGit2.GitTransferProgress}, Any}), pointer_from_objref(transfer_payload)),
            )
            fetch_opts = LibGit2.FetchOptions(callbacks = callbacks)
            if branch == nothing
                clone_opts = LibGit2.CloneOptions(fetch_opts=fetch_opts, bare=isbare)
            else
                clone_opts = LibGit2.CloneOptions(fetch_opts=fetch_opts, bare=isbare, checkout_branch=Cstring(pointer(branch)))
            end
            return LibGit2.clone(url, source_path, clone_opts)
        end
    catch e
        if isa(e, LibGit2.GitError) && e.code == LibGit2.Error.EAUTH
            LibGit2.reject(cred_payload)
        end

        rm(source_path; force=true, recursive=true)
        rethrow(e)
    finally
        print(stdout, "\e[?25h")
        println(stdout)
    end
    LibGit2.approve(cred_payload)
end

end # module
