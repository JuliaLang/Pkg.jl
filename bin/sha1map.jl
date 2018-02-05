#!/usr/bin/env julia

using Pkg3.TOML
import Pkg3.BinaryProvider
using SHA
using Base: LibGit2

function get_archive_url_for_version(url::String, version)
    if (m = match(r"(https|git)://github.com/(.*?)/(.*?).git", url)) != nothing
        return "https://github.com/$(m.captures[2])/$(m.captures[3])/archive/v$(version).tar.gz"
    end
    return nothing
end

function sha1map(pkgs::Dict{String,Package})
    f = joinpath(@__DIR__, "sha1map.toml")
    f_archive_shas = joinpath(@__DIR__, "archiveshamap.toml")
    d = ispath(f) ? TOML.parsefile(f) : Dict()
    d_archive_shas = ispath(f_archive_shas) ? TOML.parsefile(f_archive_shas) : Dict()
    c = 1
    for (pkg, p) in pkgs
        perc = c / length(pkgs) * 100
        println("$perc % --- PKG: $pkg")
        c += 1
        isempty(p.versions) && continue
        uuid = string(p.uuid)
        haskey(d, uuid) || (d[uuid] = Dict())
        haskey(d_archive_shas, uuid) || (d_archive_shas[uuid] = Dict())
        updated = false
        repo = nothing
        mkpath(joinpath(@__DIR__, "archives", pkg))
        @sync for (ver, v) in p.versions
            @async begin
                if !haskey(d_archive_shas[uuid], v.sha1)
                    archive_url = get_archive_url_for_version(p.url, strip(string(ver), 'v'))
                    if archive_url != nothing
                            file = joinpath(@__DIR__, "archives", pkg, pkg * "_" * strip(string(ver), 'v') * ".tar.gz")
                        try
                            if !isfile(file)
                                cmd = BinaryProvider.gen_download_cmd(archive_url, file);
                                run(cmd, (DevNull, DevNull, DevNull))
                            end
                            sha = open(file, "r") do io
                                bytes2hex(sha256(io))
                            end
                            d_archive_shas[uuid][v.sha1] = Dict("url" => archive_url, "sha256-hash" => sha)
                        catch e
                            d_archive_shas[uuid][v.sha1] = Dict()
                            info("Skipping $pkg: $ver")
                        end
                    else
                        d_archive_shas[uuid][v.sha1] = Dict()
                    end
                end
                if !haskey(d[uuid], v.sha1)
                    git_commit_hash = LibGit2.GitHash(v.sha1)
                    if repo == nothing
                        repo_path = joinpath(homedir(), ".julia", "upstream", uuid)
                        repo = ispath(repo_path) ? LibGit2.GitRepo(repo_path) : begin
                            updated = true
                            info("Cloning [$uuid] $pkg")
                            LibGit2.clone(p.url, repo_path, isbare=true)
                        end
                    end
                    if !updated
                        try LibGit2.GitObject(repo, git_commit_hash)
                        catch err
                            err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
                            info("Updating $pkg from $(p.url)")
                            LibGit2.fetch(repo, remoteurl=p.url, refspecs=["+refs/*:refs/remotes/cache/*"])
                        end
                    end
                    git_commit = try LibGit2.GitObject(repo, git_commit_hash)
                    catch err
                        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
                        error("$pkg: git object $(v.sha1) could not be found")
                    end
                    git_commit isa LibGit2.GitCommit || git_commit isa LibGit2.GitTag ||
                        error("$pkg: git object $(v.sha1) not a commit – $(typeof(git_commit))")
                    git_tree = LibGit2.peel(LibGit2.GitTree, git_commit)
                    @assert git_tree isa LibGit2.GitTree
                    git_tree_hash = string(LibGit2.GitHash(git_tree))
                    d[uuid][v.sha1] = git_tree_hash
                end
            end # @async
        end
    end
    open(f, "w") do io
        TOML.print(io, d, sorted=true)
    end
    open(f_archive_shas, "w") do io
        TOML.print(io, d_archive_shas, sorted=true)
    end
    return d, d_archive_shas
end
