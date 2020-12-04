module Registry

import ..Pkg
using ..Pkg: depots1, printpkgstyle, DEFAULT_IO, isdir_nothrow, pathrepr, pkg_server,
             GitTools, OFFLINE_MODE, UPDATED_REGISTRY_THIS_SESSION
using ..Pkg.PlatformEngines: download_verify_unpack, download
using UUIDs, LibGit2

include("registry_instance.jl")

mutable struct RegistrySpec
    name::Union{String,Nothing}
    uuid::Union{UUID,Nothing}
    url::Union{String,Nothing}
    # the path field can be a local source when adding a registry
    # otherwise it is the path where the registry is installed
    path::Union{String,Nothing}
end
RegistrySpec(name::String) = RegistrySpec(name = name)
RegistrySpec(;name::Union{String,Nothing}=nothing, uuid::Union{String,UUID,Nothing}=nothing,
              url::Union{String,Nothing}=nothing, path::Union{String,Nothing}=nothing) =
    RegistrySpec(name, isa(uuid, String) ? UUID(uuid) : uuid, url, path)

"""
    Pkg.Registry.add(url::String)
    Pkg.Registry.add(registry::RegistrySpec)

Add new package registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.add("General")
Pkg.Registry.add(RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"))
Pkg.Registry.add(RegistrySpec(url = "https://github.com/JuliaRegistries/General.git"))
```
"""
add(reg::Union{String,RegistrySpec}; kwargs...) = add([reg]; kwargs...)
add(regs::Vector{String}; kwargs...) = add(RegistrySpec[RegistrySpec(name = name) for name in regs]; kwargs...)
function add(regs::Vector{RegistrySpec}; io::IO=DEFAULT_IO[])
    if isempty(regs)
        download_default_registries(io, only_if_empty = false)
    else
        download_registries(io, regs)
    end
end

const DEFAULT_REGISTRIES =
    RegistrySpec[RegistrySpec(name = "General",
                              uuid = UUID("23338594-aafe-5451-b93e-139f81909106"),
                              url = "https://github.com/JuliaRegistries/General.git")]

# Use the pattern
#
# registry_urls = nothing
# for ...
#     url, registry_urls = pkg_server_registry_url(uuid, registry_urls)
# end
#
# to query the pkg server at most once for registries.
pkg_server_registry_url(uuid::UUID, ::Nothing) =
    pkg_server_registry_url(uuid, pkg_server_registry_urls())

pkg_server_registry_url(uuid::UUID, registry_urls::Dict{UUID, String}) =
    get(registry_urls, uuid, nothing), registry_urls

pkg_server_registry_url(::Nothing, registry_urls) = nothing, registry_urls

function pkg_server_registry_urls()
    registry_urls = Dict{UUID, String}()
    server = pkg_server()
    server === nothing && return registry_urls
    tmp_path = tempname()
    download_ok = false
    try
        download("$server/registries", tmp_path, verbose=false)
        download_ok = true
    catch err
        @warn "could not download $server/registries" exception=err
    end
    download_ok || return registry_urls
    open(tmp_path) do io
        for line in eachline(io)
            if (m = match(r"^/registry/([^/]+)/([^/]+)$", line)) !== nothing
                uuid = UUID(m.captures[1])
                hash = String(m.captures[2])
                registry_urls[uuid] = "$server/registry/$uuid/$hash"
            end
        end
    end
    Base.rm(tmp_path, force=true)
    return registry_urls
end

pkg_server_url_hash(url::String) = Base.SHA1(split(url, '/')[end])

function download_default_registries(io::IO; only_if_empty::Bool = true)
    installed_registries = reachable_registries()
    # Only clone if there are no installed registries, unless called
    # with false keyword argument.
    if isempty(installed_registries) || !only_if_empty
        printpkgstyle(io, :Installing, "known registries into $(pathrepr(depots1()))")
        registries = copy(DEFAULT_REGISTRIES)
        for uuid in keys(pkg_server_registry_urls())
            if !(uuid in (reg.uuid for reg in registries))
                push!(registries, RegistrySpec(uuid = uuid))
            end
        end
        filter!(reg -> !(reg.uuid in installed_registries), registries)
        download_registries(io, registries)
        return true
    end
    return false
end

# Hacky way to make e.g. `registry add General` work.
function populate_known_registries_with_urls!(registries::Vector{RegistrySpec})
    known_registries = DEFAULT_REGISTRIES # TODO: Some way to add stuff here?
    for reg in registries, known in known_registries
        if reg.uuid !== nothing
            if reg.uuid === known.uuid
                reg.url = known.url
            end
        elseif reg.name !== nothing
            if reg.name == known.name
                named_regs = filter(r -> r.name == reg.name, known_registries)
                if !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                    Pkg.Types.pkgerror("multiple registries with name `$(reg.name)`, please specify with uuid.")
                end
                reg.url = known.url
                reg.uuid = known.uuid
            end
        end
    end
end

function download_registries(io::IO, regs::Vector{RegistrySpec}, depot::String=depots1())
    populate_known_registries_with_urls!(regs)
    registry_urls = nothing
    for reg in regs
        if reg.path !== nothing && reg.url !== nothing
            Pkg.Types.pkgerror("ambiguous registry specification; both url and path is set.")
        end
        # clone to tmpdir first
        mktempdir() do tmp
            url, registry_urls = pkg_server_registry_url(reg.uuid, registry_urls)
            # on Windows we prefer git cloning because untarring is so slow
            if !Sys.iswindows() && url !== nothing
                # download from Pkg server
                try
                    download_verify_unpack(url, nothing, tmp, ignore_existence = true)
                catch err
                    Pkg.Types.pkgerror("could not download $url")
                end
                tree_info_file = joinpath(tmp, ".tree_info.toml")
                hash = pkg_server_url_hash(url)
                write(tree_info_file, "git-tree-sha1 = " * repr(string(hash)))
            elseif reg.path !== nothing # copy from local source
                printpkgstyle(io, :Copying, "registry from `$(Base.contractuser(reg.path))`")
                mv(reg.path, tmp; force=true)
            elseif reg.url !== nothing # clone from url
                repo = GitTools.clone(io, reg.url, tmp; header = "registry from $(repr(reg.url))")
                LibGit2.close(repo)
            else
                Pkg.Types.pkgerror("no path or url specified for registry")
            end
            # verify that the clone looks like a registry
            if !isfile(joinpath(tmp, "Registry.toml"))
                Pkg.Types.pkgerror("no `Registry.toml` file in cloned registry.")
            end
            registry = Registry.RegistryInstance(tmp; parse_packages=false)
            # copy to `depot`
            regpath = joinpath(depot, "registries", registry.name)
            ispath(dirname(regpath)) || mkpath(dirname(regpath))
            if isdir_nothrow(regpath)
                existing_registry = Registry.RegistryInstance(regpath; parse_packages=false)
                if registry.uuid == existing_registry.uuid
                    println(io,
                            "registry `$(registry.name)` already exist in `$(Base.contractuser(regpath))`.")
                else
                    throw(Pkg.Types.PkgError("registry `$(registry.name)=\"$(registry.uuid)\"` conflicts with " *
                        "existing registry `$(existing_registry.name)=\"$(existing_registry.uuid)\"`. " *
                        "To install it you can clone it manually into e.g. " *
                        "`$(Base.contractuser(joinpath(depot, "registries", registry.name*"-2")))`."))
                end
            else
                mv(tmp, regpath)
                printpkgstyle(io, :Added, "registry `$(registry.name)` to `$(Base.contractuser(regpath))`")
            end
        end
    end
    return nothing
end

"""
    Pkg.Registry.rm(registry::String)
    Pkg.Registry.rm(registry::RegistrySpec)

Remove registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.rm("General")
Pkg.Registry.rm(RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"))
```
"""
rm(reg::Union{String,RegistrySpec}; kwargs...) = rm([reg]; kwargs...)
rm(regs::Vector{String}; kwargs...) = rm([RegistrySpec(name = name) for name in regs]; kwargs...)
function rm(regs::Vector{RegistrySpec}; io::IO=DEFAULT_IO[])
    for registry in find_installed_registries(io, regs)
        printpkgstyle(io, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        Base.rm(registry.path; force=true, recursive=true)
    end
    return nothing
end

# Search for the input registries among installed ones
function find_installed_registries(io::IO,
                                   needles::Union{Vector{Registry.RegistryInstance}, Vector{RegistrySpec}})
    haystack = reachable_registries(; parse_packages=false)
    output = Registry.RegistryInstance[]
    for needle in needles
        if needle.name === nothing && needle.uuid === nothing
            Pkg.Types.pkgerror("no name or uuid specified for registry.")
        end
        found = false
        for candidate in haystack
            if needle.uuid !== nothing
                if needle.uuid == candidate.uuid
                    push!(output, candidate)
                    found = true
                end
            elseif needle.name !== nothing
                if needle.name == candidate.name
                    named_regs = filter(r -> r.name == needle.name, haystack)
                    if !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                        Pkg.Types.pkgerror("multiple registries with name `$(needle.name)`, please specify with uuid.")
                    end
                    push!(output, candidate)
                    found = true
                end
            end
        end
        if !found
            println(io, "registry `$(needle.name === nothing ? needle.uuid :
                                         needle.uuid === nothing ? needle.name :
                                         "$(needle.name)=$(needle.uuid)")` not found.")
        end
    end
    return output
end


"""
    Pkg.Registry.update()
    Pkg.Registry.update(registry::RegistrySpec)
    Pkg.Registry.update(registry::Vector{RegistrySpec})

Update registries. If no registries are given, update
all available registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.update()
Pkg.Registry.update("General")
Pkg.Registry.update(RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"))
```
"""
update(reg::Union{String,RegistrySpec}; kwargs...) = update([reg]; kwargs...)
update(regs::Vector{String}; kwargs...) = update([RegistrySpec(name = name) for name in regs]; kwargs...)
function update(regs::Vector{RegistrySpec} = RegistrySpec[]; io::IO=DEFAULT_IO[], force::Bool=true)
    OFFLINE_MODE[] && return
    !force && UPDATED_REGISTRY_THIS_SESSION[] && return

    isempty(regs) && (regs = reachable_registries(; depots=depots1()))
    errors = Tuple{String, String}[]
    registry_urls = nothing
    for reg in unique(r -> r.uuid, find_installed_registries(io, regs); seen=Set{UUID}())
        let reg=reg
            regpath = pathrepr(reg.path)
            if reg.tree_info !== nothing
                printpkgstyle(io, :Updating, "registry at " * regpath)
                old_hash = reg.tree_info
                url, registry_urls = pkg_server_registry_url(reg.uuid, registry_urls)
                if url !== nothing && (new_hash = pkg_server_url_hash(url)) != old_hash
                    let new_hash = new_hash
                        # TODO: update faster by using a diff, if available
                        mktempdir() do tmp
                            try
                                download_verify_unpack(url, nothing, tmp, ignore_existence = true)
                            catch err
                                @error "could not download $url" exception=err
                            end
                            tree_info_file = joinpath(tmp, ".tree_info.toml")
                            hash = pkg_server_url_hash(url)
                            write(tree_info_file, "git-tree-sha1 = " * repr(string(new_hash)))
                            cp(tmp, reg.path, force=true)
                        end
                    end
                end
            elseif isdir(joinpath(reg.path, ".git"))
                printpkgstyle(io, :Updating, "registry at " * regpath)
                LibGit2.with(LibGit2.GitRepo(reg.path)) do repo
                    if LibGit2.isdirty(repo)
                        push!(errors, (regpath, "registry dirty"))
                        @goto done
                    end
                    if !LibGit2.isattached(repo)
                        push!(errors, (regpath, "registry detached"))
                        @goto done
                    end
                    if !("origin" in LibGit2.remotes(repo))
                        push!(errors, (regpath, "origin not in the list of remotes"))
                        @goto done
                    end
                    branch = LibGit2.headname(repo)
                    try
                        GitTools.fetch(io, repo; refspecs=["+refs/heads/$branch:refs/remotes/origin/$branch"])
                    catch e
                        e isa Pkg.PkgError || rethrow()
                        push!(errors, (reg.path, "failed to fetch from repo"))
                        @goto done
                    end
                    ff_succeeded = try
                        LibGit2.merge!(repo; branch="refs/remotes/origin/$branch", fastforward=true)
                    catch e
                        e isa LibGit2.GitError && e.code == LibGit2.Error.ENOTFOUND || rethrow()
                        push!(errors, (reg.path, "branch origin/$branch not found"))
                        @goto done
                    end

                    if !ff_succeeded
                        try LibGit2.rebase!(repo, "origin/$branch")
                        catch e
                            e isa LibGit2.GitError || rethrow()
                            push!(errors, (reg.path, "registry failed to rebase on origin/$branch"))
                            @goto done
                        end
                    end
                    @label done
                end
            end
        end
    end
    if !isempty(errors)
        warn_str = "Some registries failed to update:"
        for (reg, err) in errors
            warn_str *= "\n    — $reg — $err"
        end
        @error warn_str
    end
    UPDATED_REGISTRY_THIS_SESSION[] = true
    return
end


"""
    Pkg.Registry.status()

Display information about available registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.status()
```
"""
function status(io::IO=DEFAULT_IO[])
    regs = reachable_registries()
    regs = unique(r -> r.uuid, regs; seen=Set{Union{UUID,Nothing}}())
    printpkgstyle(io, Symbol("Registry Status"), "")
    if isempty(regs)
        println(io, "  (no registries found)")
    else
        for reg in regs
            printstyled(io, " [$(string(reg.uuid)[1:8])]"; color = :light_black)
            print(io, " $(reg.name)")
            reg.url === nothing || print(io, " ($(reg.url))")
            println(io)
        end
    end
end

end # module
