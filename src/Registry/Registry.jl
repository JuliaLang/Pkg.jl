module Registry

import ..Pkg
using ..Pkg: depots1, printpkgstyle, stderr_f, isdir_nothrow, pathrepr, pkg_server,
             GitTools, get_bool_env
using ..Pkg.PlatformEngines: download_verify_unpack, download, download_verify, exe7z
using UUIDs, LibGit2, TOML
import FileWatching

include("registry_instance.jl")

mutable struct RegistrySpec
    name::Union{String,Nothing}
    uuid::Union{UUID,Nothing}
    url::Union{String,Nothing}
    # the path field can be a local source when adding a registry
    # otherwise it is the path where the registry is installed
    path::Union{String,Nothing}
    linked::Union{Bool,Nothing}
end
RegistrySpec(name::String) = RegistrySpec(name = name)
RegistrySpec(;name::Union{String,Nothing}=nothing, uuid::Union{String,UUID,Nothing}=nothing,
url::Union{String,Nothing}=nothing, path::Union{String,Nothing}=nothing, linked::Union{Bool,Nothing}=nothing) =
    RegistrySpec(name, isa(uuid, String) ? UUID(uuid) : uuid, url, path, linked)

"""
    Pkg.Registry.add(registry::RegistrySpec)

Add new package registries.

The no-argument `Pkg.Registry.add()` will install the default registries.

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
add(; kwargs...) = add(RegistrySpec[]; kwargs...)
function add(regs::Vector{RegistrySpec}; io::IO=stderr_f())
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

function pkg_server_registry_info()
    registry_info = Dict{UUID, Base.SHA1}()
    server = pkg_server()
    server === nothing && return nothing
    tmp_path = tempname()
    download_ok = false
    try
        download("$server/registries", tmp_path, verbose=false)
        download_ok = true
    catch err
        @warn "could not download $server/registries" exception=err
    end
    download_ok || return nothing
    open(tmp_path) do io
        for line in eachline(io)
            if (m = match(r"^/registry/([^/]+)/([^/]+)$", line)) !== nothing
                uuid = UUID(m.captures[1]::SubString{String})
                hash = Base.SHA1(m.captures[2]::SubString{String})
                registry_info[uuid] = hash
            end
        end
    end
    Base.rm(tmp_path, force=true)
    return server, registry_info
end

function pkg_server_registry_urls()
    server_registry_info = pkg_server_registry_info()
    registry_urls = Dict{UUID, String}()
    server_registry_info === nothing && return registry_urls
    server, registry_info = server_registry_info
    for (uuid, hash) in registry_info
        registry_urls[uuid] = "$server/registry/$uuid/$hash"
    end
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
                reg.path = known.path
                reg.linked = known.linked
            end
        elseif reg.name !== nothing
            if reg.name == known.name
                named_regs = filter(r -> r.name == reg.name, known_registries)
                if !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                    Pkg.Types.pkgerror("multiple registries with name `$(reg.name)`, please specify with uuid.")
                end
                reg.uuid = known.uuid
                reg.url = known.url
                reg.path = known.path
                reg.linked = known.linked
            end
        end
    end
end

function registry_use_pkg_server()
    get(ENV, "JULIA_PKG_SERVER", nothing) !== ""
end

registry_read_from_tarball() =
    registry_use_pkg_server() && !get_bool_env("JULIA_PKG_UNPACK_REGISTRY")

function check_registry_state(reg)
    reg_currently_uses_pkg_server = reg.tree_info !== nothing
    reg_should_use_pkg_server = registry_use_pkg_server()
    if reg_currently_uses_pkg_server && !reg_should_use_pkg_server
        msg = string(
            "Your registry may be outdated. We recommend that you run the ",
            "following command: ",
            "using Pkg; Pkg.Registry.rm(\"$(reg.name)\"); Pkg.Registry.add(\"$(reg.name)\")",
        )
        @warn(msg)
    end
    return nothing
end

function download_registries(io::IO, regs::Vector{RegistrySpec}, depot::String=depots1())
    populate_known_registries_with_urls!(regs)
    regdir = joinpath(depot, "registries")
    isdir(regdir) || mkpath(regdir)
    # only allow one julia process to download and install registries at a time
    FileWatching.mkpidlock(joinpath(regdir, ".pid"), stale_age = 10) do
    registry_urls = pkg_server_registry_urls()
    for reg in regs
        if reg.path !== nothing && reg.url !== nothing
            Pkg.Types.pkgerror("ambiguous registry specification; both url and path is set.")
        end
        url = get(registry_urls, reg.uuid, nothing)
        if url !== nothing && registry_read_from_tarball()
            tmp = tempname()
            try
                download_verify(url, nothing, tmp)
            catch err
                Pkg.Types.pkgerror("could not download $url \nException: $(sprint(showerror, err))")
            end
            if reg.name === nothing
                # Need to look up the registry name here
                reg_unc = uncompress_registry(tmp)
                reg.name = TOML.parse(reg_unc["Registry.toml"])["name"]::String
            end
            mv(tmp, joinpath(regdir, reg.name * ".tar.gz"); force=true)
            _hash = pkg_server_url_hash(url)
            reg_info = Dict("uuid" => string(reg.uuid), "git-tree-sha1" => string(_hash), "path" => reg.name * ".tar.gz")
            open(joinpath(regdir, reg.name * ".toml"), "w") do io
                TOML.print(io, reg_info)
            end
        else
            mktempdir() do tmp
                if reg.path !== nothing && reg.linked == true # symlink to local source
                    registry = Registry.RegistryInstance(reg.path)
                    regpath = joinpath(regdir, registry.name)
                    printpkgstyle(io, :Symlinking, "registry from `$(Base.contractuser(reg.path))`")
                    isdir(dirname(regpath)) || mkpath(dirname(regpath))
                    symlink(reg.path, regpath)
                    isfile(joinpath(regpath, "Registry.toml")) || Pkg.Types.pkgerror("no `Registry.toml` file in linked registry.")
                    registry = Registry.RegistryInstance(regpath)
                    printpkgstyle(io, :Symlinked, "registry `$(Base.contractuser(registry.name))` to `$(Base.contractuser(regpath))`")
                    return
                elseif url !== nothing && registry_use_pkg_server()
                    # download from Pkg server
                    try
                        download_verify_unpack(url, nothing, tmp, ignore_existence = true, io = io)
                    catch err
                        Pkg.Types.pkgerror("could not download $url \nException: $(sprint(showerror, err))")
                    end
                    tree_info_file = joinpath(tmp, ".tree_info.toml")
                    hash = pkg_server_url_hash(url)
                    write(tree_info_file, "git-tree-sha1 = " * repr(string(hash)))
                elseif reg.path !== nothing # copy from local source
                    printpkgstyle(io, :Copying, "registry from `$(Base.contractuser(reg.path))`")
                    isfile(joinpath(reg.path, "Registry.toml")) || Pkg.Types.pkgerror("no `Registry.toml` file in source directory.")
                    registry = Registry.RegistryInstance(reg.path)
                    regpath = joinpath(regdir, registry.name)
                    cp(reg.path, regpath; force=true) # has to be cp given we're copying
                    printpkgstyle(io, :Copied, "registry `$(Base.contractuser(registry.name))` to `$(Base.contractuser(regpath))`")
                    return
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
                registry = Registry.RegistryInstance(tmp)
                regpath = joinpath(regdir, registry.name)
                # copy to `depot`
                ispath(dirname(regpath)) || mkpath(dirname(regpath))
                if isfile(joinpath(regpath, "Registry.toml"))
                    existing_registry = Registry.RegistryInstance(regpath)
                    if registry.uuid == existing_registry.uuid
                        println(io,
                                "Registry `$(registry.name)` already exists in `$(Base.contractuser(regpath))`.")
                    else
                        throw(Pkg.Types.PkgError("registry `$(registry.name)=\"$(registry.uuid)\"` conflicts with " *
                            "existing registry `$(existing_registry.name)=\"$(existing_registry.uuid)\"`. " *
                            "To install it you can clone it manually into e.g. " *
                            "`$(Base.contractuser(joinpath(regdir, registry.name*"-2")))`."))
                    end
                elseif (url !== nothing && registry_use_pkg_server()) || reg.linked !== true
                    # if the dir doesn't exist, or exists but doesn't contain a Registry.toml
                    mv(tmp, regpath, force=true)
                    printpkgstyle(io, :Added, "registry `$(registry.name)` to `$(Base.contractuser(regpath))`")
                end
            end
        end
    end
    end # mkpidlock
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
function rm(regs::Vector{RegistrySpec}; io::IO=stderr_f())
    for registry in find_installed_registries(io, regs; depots=first(Base.DEPOT_PATH))
        printpkgstyle(io, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        if isfile(registry.path)
            d = TOML.parsefile(registry.path)
            if haskey(d, "path")
               Base.rm(joinpath(dirname(registry.path), d["path"]); force=true)
            end
        end
        Base.rm(registry.path; force=true, recursive=true)
    end
    return nothing
end

# Search for the input registries among installed ones
function find_installed_registries(io::IO,
                                   needles::Union{Vector{Registry.RegistryInstance}, Vector{RegistrySpec}};
                                   depots=Base.DEPOT_PATH)
    haystack = reachable_registries(; depots)
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
function update(regs::Vector{RegistrySpec} = RegistrySpec[]; io::IO=stderr_f(), force::Bool=true)
    depot = depots1()
    isempty(regs) && (regs = reachable_registries(; depots=depot))
    regdir = joinpath(depot, "registries")
    isdir(regdir) || mkpath(regdir)
    # only allow one julia process to update registries at a time
    FileWatching.mkpidlock(joinpath(regdir, ".pid"), stale_age = 10) do
    errors = Tuple{String, String}[]
    registry_urls = pkg_server_registry_urls()
    for reg in unique(r -> r.uuid, find_installed_registries(io, regs); seen=Set{UUID}())
        let reg=reg, errors=errors
            regpath = pathrepr(reg.path)
            let regpath=regpath
                if reg.tree_info !== nothing
                    printpkgstyle(io, :Updating, "registry at " * regpath)
                    old_hash = reg.tree_info
                    url = get(registry_urls, reg.uuid, nothing)
                    if url !== nothing
                        check_registry_state(reg)
                    end
                    if url !== nothing && (new_hash = pkg_server_url_hash(url)) != old_hash
                        # TODO: update faster by using a diff, if available
                        # TODO: DRY with the code in `download_default_registries`
                        let new_hash = new_hash, url = url
                            if registry_read_from_tarball()
                                tmp = tempname()
                                try
                                    download_verify(url, nothing, tmp)
                                catch err
                                    push!(errors, (reg.path, "failed to download from $(url). Exception: $(sprint(showerror, err))"))
                                    @goto done_tarball_read
                                end
                                # If we have an uncompressed Pkg server registry, remove it and get the compressed version
                                if isdir(reg.path)
                                    Base.rm(reg.path; recursive=true, force=true)
                                end
                                registry_path = dirname(reg.path)
                                mv(tmp, joinpath(registry_path, reg.name * ".tar.gz"); force=true)
                                hash = pkg_server_url_hash(url)
                                reg_info = Dict("uuid" => string(reg.uuid), "git-tree-sha1" => string(hash), "path" => reg.name * ".tar.gz")
                                open(joinpath(registry_path, reg.name * ".toml"), "w") do io
                                    TOML.print(io, reg_info)
                                end
                                @label done_tarball_read
                            else
                                mktempdir() do tmp
                                    try
                                        download_verify_unpack(url, nothing, tmp, ignore_existence = true, io=io)
                                    catch err
                                        push!(errors, (reg.path, "failed to download and unpack from $(url). Exception: $(sprint(showerror, err))"))
                                        @goto done_tarball_unpack
                                    end
                                    tree_info_file = joinpath(tmp, ".tree_info.toml")
                                    write(tree_info_file, "git-tree-sha1 = " * repr(string(new_hash)))
                                    mv(tmp, reg.path, force=true)
                                    @label done_tarball_unpack
                                end
                            end
                        end
                    end
                elseif isdir(joinpath(reg.path, ".git"))
                    printpkgstyle(io, :Updating, "registry at " * regpath)
                    LibGit2.with(LibGit2.GitRepo(reg.path)) do repo
                        if LibGit2.isdirty(repo)
                            push!(errors, (regpath, "registry dirty"))
                            @goto done_git
                        end
                        if !LibGit2.isattached(repo)
                            push!(errors, (regpath, "registry detached"))
                            @goto done_git
                        end
                        if !("origin" in LibGit2.remotes(repo))
                            push!(errors, (regpath, "origin not in the list of remotes"))
                            @goto done_git
                        end
                        branch = LibGit2.headname(repo)
                        try
                            GitTools.fetch(io, repo; refspecs=["+refs/heads/$branch:refs/remotes/origin/$branch"])
                        catch e
                            e isa Pkg.Types.PkgError || rethrow()
                            push!(errors, (reg.path, "failed to fetch from repo: $(e.msg)"))
                            @goto done_git
                        end
                        ff_succeeded = try
                            LibGit2.merge!(repo; branch="refs/remotes/origin/$branch", fastforward=true)
                        catch e
                            e isa LibGit2.GitError && e.code == LibGit2.Error.ENOTFOUND || rethrow()
                            push!(errors, (reg.path, "branch origin/$branch not found"))
                            @goto done_git
                        end

                        if !ff_succeeded
                            try LibGit2.rebase!(repo, "origin/$branch")
                            catch e
                                e isa LibGit2.GitError || rethrow()
                                push!(errors, (reg.path, "registry failed to rebase on origin/$branch"))
                                @goto done_git
                            end
                        end
                        @label done_git
                    end
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
    end # mkpidlock
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
function status(io::IO=stderr_f())
    regs = reachable_registries()
    regs = unique(r -> r.uuid, regs; seen=Set{Union{UUID,Nothing}}())
    printpkgstyle(io, Symbol("Registry Status"), "")
    if isempty(regs)
        println(io, "  (no registries found)")
    else
        for reg in regs
            printstyled(io, " [$(string(reg.uuid)[1:8])]"; color = :light_black)
            print(io, " $(reg.name)")
            reg.repo === nothing || print(io, " ($(reg.repo))")
            println(io)
        end
    end
end

end # module
