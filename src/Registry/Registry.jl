"""
    Pkg.Registry

A module for managing Julia package registries.

Registries are repositories that contain metadata about available packages, including
their versions, dependencies, and locations. The most common registry is the General
registry, which hosts publicly available Julia packages.

# Main Functions

- [`Pkg.Registry.add`](@ref): Add new package registries
- [`Pkg.Registry.rm`](@ref): Remove installed registries
- [`Pkg.Registry.update`](@ref): Update installed registries
- [`Pkg.Registry.status`](@ref): Display information about available registries

# Examples

```julia
# Add the default registries (typically the General registry)
Pkg.Registry.add()

# Add a specific registry by name, UUID, or URL
Pkg.Registry.add("General")
Pkg.Registry.add(url = "https://github.com/JuliaRegistries/General.git")

# Update all registries
Pkg.Registry.update()

# Check registry status
Pkg.Registry.status()

# Remove a registry
Pkg.Registry.rm("General")
```

See also: [`RegistrySpec`](@ref)
"""
module Registry

import ..Pkg
using ..Pkg: depots, depots1, printpkgstyle, stderr_f, isdir_nothrow, pathrepr, pkg_server,
    GitTools, atomic_toml_write
using ..Pkg.PlatformEngines: download_verify_unpack, download, download_verify, exe7z, verify_archive_tree_hash
using UUIDs, LibGit2, TOML, Dates
import FileWatching

public add, rm, status, update

include("registry_instance.jl")

mutable struct RegistrySpec
    name::Union{String, Nothing}
    uuid::Union{UUID, Nothing}
    url::Union{String, Nothing}
    # the path field can be a local source when adding a registry
    # otherwise it is the path where the registry is installed
    path::Union{String, Nothing}
    linked::Union{Bool, Nothing}
end
RegistrySpec(name::String) = RegistrySpec(name = name)
RegistrySpec(;
    name::Union{String, Nothing} = nothing, uuid::Union{String, UUID, Nothing} = nothing,
    url::Union{String, Nothing} = nothing, path::Union{String, Nothing} = nothing, linked::Union{Bool, Nothing} = nothing
) =
    RegistrySpec(name, isa(uuid, String) ? UUID(uuid) : uuid, url, path, linked)

"""
    Pkg.Registry.add(registry::RegistrySpec)

Add new package registries.

The no-argument `Pkg.Registry.add()` will install the default registries.

# Examples
```julia
Pkg.Registry.add("General")
Pkg.Registry.add(uuid = "23338594-aafe-5451-b93e-139f81909106")
Pkg.Registry.add(url = "https://github.com/JuliaRegistries/General.git")
```
"""
add(reg::Union{String, RegistrySpec}; kwargs...) = add([reg]; kwargs...)
add(regs::Vector{String}; kwargs...) = add(RegistrySpec[RegistrySpec(name = name) for name in regs]; kwargs...)
function add(; name = nothing, uuid = nothing, url = nothing, path = nothing, linked = nothing, kwargs...)
    return if all(isnothing, (name, uuid, url, path, linked))
        add(RegistrySpec[]; kwargs...)
    else
        add([RegistrySpec(; name, uuid, url, path, linked)]; kwargs...)
    end
end
function add(regs::Vector{RegistrySpec}; io::IO = stderr_f(), depots::Union{String, Vector{String}} = depots())
    return if isempty(regs)
        download_default_registries(io, only_if_empty = false; depots = depots)
    else
        download_registries(io, regs, depots)
    end
end

const DEFAULT_REGISTRIES =
    RegistrySpec[
    RegistrySpec(
        name = "General",
        uuid = UUID("23338594-aafe-5451-b93e-139f81909106"),
        url = "https://github.com/JuliaRegistries/General.git"
    ),
]

function pkg_server_registry_info()
    registry_info = Dict{UUID, Base.SHA1}()
    server = pkg_server()
    server === nothing && return nothing
    tmp_path = tempname()
    download_ok = false
    try
        f = retry(delays = fill(1.0, 3)) do
            download("$server/registries", tmp_path, verbose = false)
        end
        f()
        download_ok = true
    catch err
        @warn "could not download $server/registries" exception = err
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
    Base.rm(tmp_path, force = true)
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

"""
    is_pkg_in_pkgserver_registry(pkg_uuid::Base.UUID, server_registry_info, registries)

Check if a package UUID is tracked by the PkgServer by verifying it exists in
a registry that is known to the PkgServer.
"""
function is_pkg_in_pkgserver_registry(pkg_uuid::Base.UUID, server_registry_info, registries)
    server_registry_info === nothing && return false
    registries === nothing && return false

    server, registry_info = server_registry_info
    for reg in registries
        if reg.uuid in keys(registry_info)
            if haskey(reg, pkg_uuid)
                return true
            end
        end
    end
    return false
end

function download_default_registries(io::IO; only_if_empty::Bool = true, depots::Union{String, Vector{String}} = depots())
    # Check the specified depots for installed registries
    installed_registries = reachable_registries(; depots)
    # Only clone if there are no installed registries, unless called
    # with false keyword argument.
    if isempty(installed_registries) || !only_if_empty
        # Install to the first depot in the list
        target_depot = depots1(depots)
        printpkgstyle(io, :Installing, "known registries into $(pathrepr(target_depot))")
        registries = copy(DEFAULT_REGISTRIES)
        for uuid in keys(pkg_server_registry_urls())
            if !(uuid in (reg.uuid for reg in registries))
                push!(registries, RegistrySpec(uuid = uuid))
            end
        end
        filter!(reg -> !(reg.uuid in installed_registries), registries)
        download_registries(io, registries, depots)
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
                if isempty(named_regs)
                    Pkg.Types.pkgerror("registry with name `$(reg.name)` not found in known registries.")
                elseif !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                    Pkg.Types.pkgerror("multiple registries with name `$(reg.name)`, please specify with uuid.")
                end
                reg.uuid = known.uuid
                reg.url = known.url
                reg.path = known.path
                reg.linked = known.linked
            end
        end
    end
    return
end

function registry_use_pkg_server()
    return get(ENV, "JULIA_PKG_SERVER", nothing) !== ""
end

registry_read_from_tarball() =
    registry_use_pkg_server() && !Base.get_bool_env("JULIA_PKG_UNPACK_REGISTRY", false)

function check_registry_state(reg)
    reg_currently_uses_pkg_server = reg.tree_info !== nothing
    reg_should_use_pkg_server = registry_use_pkg_server()
    if reg_currently_uses_pkg_server && !reg_should_use_pkg_server
        pkg_cmd = Pkg.in_repl_mode() ? "pkg> registry rm $(reg.name); registry add $(reg.name)" : "using Pkg; Pkg.Registry.rm(\"$(reg.name)\"); Pkg.Registry.add(\"$(reg.name)\")"
        msg = string(
            "Your registry may be outdated. We recommend that you run the ",
            "following command: ",
            pkg_cmd,
        )
        @warn(msg)
    end
    return nothing
end

function download_registries(io::IO, regs::Vector{RegistrySpec}, depots::Union{String, Vector{String}} = depots())
    # Use the first depot as the target
    target_depot = depots1(depots)
    populate_known_registries_with_urls!(regs)
    registry_update_log = get_registry_update_log()
    regdir = joinpath(target_depot, "registries")
    isdir(regdir) || mkpath(regdir)
    # only allow one julia process to download and install registries at a time
    FileWatching.mkpidlock(joinpath(regdir, ".pid"), stale_age = 10) do
        # once we're pidlocked check if another process has installed any of the registries
        reachable_uuids = map(r -> r.uuid, reachable_registries(; depots))
        filter!(r -> !in(r.uuid, reachable_uuids), regs)

        registry_urls = pkg_server_registry_urls()
        for reg in regs
            if reg.path !== nothing && reg.url !== nothing
                Pkg.Types.pkgerror(
                    """
                    ambiguous registry specification; both `url` and `path` are set:
                        url=\"$(reg.url)\"
                        path=\"$(reg.path)\"
                    """
                )
            end
            url = get(registry_urls, reg.uuid, nothing)
            if url !== nothing && registry_read_from_tarball()
                tmp = tempname()
                try
                    download_verify(url, nothing, tmp)
                catch err
                    Pkg.Types.pkgerror("could not download $url \nException: $(sprint(showerror, err))")
                end
                _hash = pkg_server_url_hash(url)
                if !verify_archive_tree_hash(tmp, _hash)
                    Pkg.Types.pkgerror("unable to verify download from $url")
                end
                if reg.name === nothing
                    # Need to look up the registry name here
                    reg_unc = uncompress_registry(tmp)
                    reg.name = TOML.parse(reg_unc["Registry.toml"])["name"]::String
                end
                mv(tmp, joinpath(regdir, reg.name * ".tar.gz"); force = true)
                reg_info = Dict("uuid" => string(reg.uuid), "git-tree-sha1" => string(_hash), "path" => reg.name * ".tar.gz")
                atomic_toml_write(joinpath(regdir, reg.name * ".toml"), reg_info)
                registry_update_log[string(reg.uuid)] = now()
                printpkgstyle(io, :Added, "`$(reg.name)` registry to $(Base.contractuser(regdir))")
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
                        registry_update_log[string(reg.uuid)] = now()
                        save_registry_update_log(registry_update_log)
                        return
                    elseif reg.url !== nothing && reg.linked == true
                        Pkg.Types.pkgerror(
                            """
                            A symlinked registry was requested but `path` was not set and `url` was set to `$url`.
                            Set only `path` and `linked = true` to use registry symlinking.
                            """
                        )
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
                        cp(reg.path, regpath; force = true) # has to be cp given we're copying
                        printpkgstyle(io, :Copied, "registry `$(Base.contractuser(registry.name))` to `$(Base.contractuser(regpath))`")
                        registry_update_log[string(reg.uuid)] = now()
                        save_registry_update_log(registry_update_log)
                        return
                    elseif reg.url !== nothing # clone from url
                        # retry to help spurious connection issues, particularly on CI
                        repo = retry(GitTools.clone, delays = fill(1.0, 5), check = (s, e) -> isa(e, LibGit2.GitError))(io, reg.url, tmp; header = "registry from $(repr(reg.url))")
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
                            println(
                                io,
                                "Registry `$(registry.name)` already exists in `$(Base.contractuser(regpath))`."
                            )
                        else
                            throw(
                                Pkg.Types.PkgError(
                                    "registry `$(registry.name)=\"$(registry.uuid)\"` conflicts with " *
                                        "existing registry `$(existing_registry.name)=\"$(existing_registry.uuid)\"`. " *
                                        "To install it you can clone it manually into e.g. " *
                                        "`$(Base.contractuser(joinpath(regdir, registry.name * "-2")))`."
                                )
                            )
                        end
                    elseif (url !== nothing && registry_use_pkg_server()) || reg.linked !== true
                        # if the dir doesn't exist, or exists but doesn't contain a Registry.toml
                        mv(tmp, regpath, force = true)
                        registry_update_log[string(reg.uuid)] = now()
                        printpkgstyle(io, :Added, "registry `$(registry.name)` to `$(Base.contractuser(regpath))`")
                    end
                end
            end
        end
    end # mkpidlock
    save_registry_update_log(registry_update_log)
    return nothing
end

"""
    Pkg.Registry.rm(registry::String)
    Pkg.Registry.rm(registry::RegistrySpec)

Remove registries.

# Examples
```julia
Pkg.Registry.rm("General")
Pkg.Registry.rm(uuid = "23338594-aafe-5451-b93e-139f81909106")
```
"""
rm(reg::Union{String, RegistrySpec}; kwargs...) = rm([reg]; kwargs...)
rm(regs::Vector{String}; kwargs...) = rm([RegistrySpec(name = name) for name in regs]; kwargs...)
function rm(; name = nothing, uuid = nothing, url = nothing, path = nothing, linked = nothing, kwargs...)
    return rm([RegistrySpec(; name, uuid, url, path, linked)]; kwargs...)
end
function rm(regs::Vector{RegistrySpec}; io::IO = stderr_f())
    for registry in find_installed_registries(io, regs; depots = first(Base.DEPOT_PATH))
        printpkgstyle(io, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        if isfile(registry.path)
            d = TOML.parsefile(registry.path)
            if haskey(d, "path")
                Base.rm(joinpath(dirname(registry.path), d["path"]); force = true)
            end
        end
        Base.rm(registry.path; force = true, recursive = true)
    end
    return nothing
end

# Search for the input registries among installed ones
function find_installed_registries(
        io::IO,
        needles::Union{Vector{Registry.RegistryInstance}, Vector{RegistrySpec}};
        depots = Base.DEPOT_PATH
    )
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
                    if isempty(named_regs)
                        Pkg.Types.pkgerror("registry with name `$(needle.name)` not found in reachable registries.")
                    elseif !all(r -> r.uuid == first(named_regs).uuid, named_regs)
                        Pkg.Types.pkgerror("multiple registries with name `$(needle.name)`, please specify with uuid.")
                    end
                    push!(output, candidate)
                    found = true
                end
            end
        end
        if !found
            println(
                io, "registry `$(
                    needle.name === nothing ? needle.uuid :
                        needle.uuid === nothing ? needle.name :
                        "$(needle.name)=$(needle.uuid)"
                )` not found."
            )
        end
    end
    return output
end

function get_registry_update_log()
    pkg_scratch_space = joinpath(DEPOT_PATH[1], "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
    pkg_reg_updated_file = joinpath(pkg_scratch_space, "registry_updates.toml")
    updated_registry_d = isfile(pkg_reg_updated_file) ? TOML.parsefile(pkg_reg_updated_file) : Dict{String, Any}()
    return updated_registry_d
end

function save_registry_update_log(d::Dict)
    pkg_scratch_space = joinpath(DEPOT_PATH[1], "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
    mkpath(pkg_scratch_space)
    pkg_reg_updated_file = joinpath(pkg_scratch_space, "registry_updates.toml")
    return atomic_toml_write(pkg_reg_updated_file, d)
end

"""
    Pkg.Registry.update()
    Pkg.Registry.update(registry::RegistrySpec)
    Pkg.Registry.update(registry::Vector{RegistrySpec})

Update registries. If no registries are given, update
all available registries.

# Examples
```julia
Pkg.Registry.update()
Pkg.Registry.update("General")
Pkg.Registry.update(uuid = "23338594-aafe-5451-b93e-139f81909106")
```
"""
update(reg::Union{String, RegistrySpec}; kwargs...) = update([reg]; kwargs...)
update(regs::Vector{String}; kwargs...) = update([RegistrySpec(name = name) for name in regs]; kwargs...)
function update(; name = nothing, uuid = nothing, url = nothing, path = nothing, linked = nothing, kwargs...)
    return if all(isnothing, (name, uuid, url, path, linked))
        update(RegistrySpec[]; kwargs...)
    else
        update([RegistrySpec(; name, uuid, url, path, linked)]; kwargs...)
    end
end
function update(regs::Vector{RegistrySpec}; io::IO = stderr_f(), force::Bool = true, depots = [depots1()], update_cooldown = Second(1))
    registry_update_log = get_registry_update_log()
    for depot in depots
        depot_regs = isempty(regs) ? reachable_registries(; depots = depot) : regs
        regdir = joinpath(depot, "registries")
        isdir(regdir) || mkpath(regdir)
        # only allow one julia process to update registries in this depot at a time
        FileWatching.mkpidlock(joinpath(regdir, ".pid"), stale_age = 10) do
            errors = Tuple{String, String}[]
            registry_urls = pkg_server_registry_urls()
            for reg in unique(r -> r.uuid, find_installed_registries(io, depot_regs; depots = [depot]); seen = Set{UUID}())
                prev_update = get(registry_update_log, string(reg.uuid), nothing)::Union{Nothing, DateTime}
                if prev_update !== nothing
                    diff = now() - prev_update
                    if diff < update_cooldown
                        @debug "Skipping updating registry $(reg.name) since it is on cooldown: $(Dates.canonicalize(Millisecond(update_cooldown) - diff)) left"
                        continue
                    end
                end
                let reg = reg, errors = errors
                    regpath = pathrepr(reg.path)
                    let regpath = regpath
                        if !iswritable(dirname(reg.path))
                            @warn "Skipping update of registry at $regpath (read-only file system)"
                            continue
                        end

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
                                        hash = pkg_server_url_hash(url)
                                        if !verify_archive_tree_hash(tmp, hash)
                                            push!(errors, (reg.path, "failed to verify download from $(url)"))
                                            @goto done_tarball_read
                                        end
                                        # If we have an uncompressed Pkg server registry, remove it and get the compressed version
                                        if isdir(reg.path)
                                            Base.rm(reg.path; recursive = true, force = true)
                                        end
                                        registry_path = dirname(reg.path)
                                        mv(tmp, joinpath(registry_path, reg.name * ".tar.gz"); force = true)
                                        reg_info = Dict("uuid" => string(reg.uuid), "git-tree-sha1" => string(hash), "path" => reg.name * ".tar.gz")
                                        atomic_toml_write(joinpath(registry_path, reg.name * ".toml"), reg_info)
                                        registry_update_log[string(reg.uuid)] = now()
                                        @label done_tarball_read
                                    else
                                        if reg.name == "General" &&
                                                Base.get_bool_env("JULIA_PKG_GEN_REG_FMT_CHECK", true) &&
                                                get(ENV, "JULIA_PKG_SERVER", nothing) != ""
                                            # warn if JULIA_PKG_SERVER is set to a non-empty string or not set
                                            @info """
                                            The General registry is installed via unpacked tarball.
                                            Consider reinstalling it via the newer faster direct from
                                            tarball format by running:
                                              pkg> registry rm General; registry add General

                                            """ maxlog = 1
                                        end
                                        mktempdir() do tmp
                                            try
                                                download_verify_unpack(url, nothing, tmp, ignore_existence = true, io = io)
                                                registry_update_log[string(reg.uuid)] = now()
                                            catch err
                                                push!(errors, (reg.path, "failed to download and unpack from $(url). Exception: $(sprint(showerror, err))"))
                                                @goto done_tarball_unpack
                                            end
                                            tree_info_file = joinpath(tmp, ".tree_info.toml")
                                            write(tree_info_file, "git-tree-sha1 = " * repr(string(new_hash)))
                                            mv(tmp, reg.path, force = true)
                                            @label done_tarball_unpack
                                        end
                                    end
                                end
                            end
                        elseif isdir(joinpath(reg.path, ".git"))
                            printpkgstyle(io, :Updating, "registry at " * regpath)
                            if reg.name == "General" &&
                                    Base.get_bool_env("JULIA_PKG_GEN_REG_FMT_CHECK", true) &&
                                    get(ENV, "JULIA_PKG_SERVER", nothing) != ""
                                # warn if JULIA_PKG_SERVER is set to a non-empty string or not set
                                @info """
                                The General registry is installed via git. Consider reinstalling it via
                                the newer faster direct from tarball format by running:
                                  pkg> registry rm General; registry add General

                                """ maxlog = 1
                            end
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
                                    GitTools.fetch(io, repo; refspecs = ["+refs/heads/$branch:refs/remotes/origin/$branch"])
                                catch e
                                    e isa Pkg.Types.PkgError || rethrow()
                                    push!(errors, (reg.path, "failed to fetch from repo: $(e.msg)"))
                                    @goto done_git
                                end
                                attempts = 0
                                @label merge
                                ff_succeeded = try
                                    LibGit2.merge!(repo; branch = "refs/remotes/origin/$branch", fastforward = true)
                                catch e
                                    attempts += 1
                                    if e isa LibGit2.GitError && e.code == LibGit2.Error.ELOCKED && attempts <= 3
                                        @warn "Registry update attempt failed because repository is locked. Resetting and retrying." e
                                        LibGit2.reset!(repo, LibGit2.head_oid(repo), LibGit2.Consts.RESET_HARD)
                                        sleep(1)
                                        @goto merge
                                    elseif e isa LibGit2.GitError && e.code == LibGit2.Error.ENOTFOUND
                                        push!(errors, (reg.path, "branch origin/$branch not found"))
                                        @goto done_git
                                    else
                                        rethrow()
                                    end

                                end

                                if !ff_succeeded
                                    try
                                        LibGit2.rebase!(repo, "origin/$branch")
                                    catch e
                                        e isa LibGit2.GitError || rethrow()
                                        push!(errors, (reg.path, "registry failed to rebase on origin/$branch"))
                                        @goto done_git
                                    end
                                end
                                registry_update_log[string(reg.uuid)] = now()
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
    end
    save_registry_update_log(registry_update_log)
    return
end


"""
    Pkg.Registry.status()

Display information about available registries.

# Examples
```julia
Pkg.Registry.status()
```
"""
function status(io::IO = stderr_f())
    regs = reachable_registries()
    regs = unique(r -> r.uuid, regs; seen = Set{Union{UUID, Nothing}}())
    printpkgstyle(io, Symbol("Registry Status"), "")
    return if isempty(regs)
        println(io, "  (no registries found)")
    else
        registry_update_log = get_registry_update_log()
        server_registry_info = Pkg.OFFLINE_MODE[] ? nothing : pkg_server_registry_info()
        flavor = get(ENV, "JULIA_PKG_SERVER_REGISTRY_PREFERENCE", "")
        for reg in regs
            printstyled(io, " [$(string(reg.uuid)[1:8])]"; color = :light_black)
            print(io, " $(reg.name)")
            reg.repo === nothing || print(io, " ($(reg.repo))")
            println(io)

            registry_type = get_registry_type(reg)
            if registry_type == :git
                print(io, "    git registry")
            elseif registry_type == :unpacked
                print(io, "    unpacked registry with hash $(reg.tree_info)")
            elseif registry_type == :packed
                print(io, "    packed registry with hash $(reg.tree_info)")
            elseif registry_type == :bare
                # We could try to detect a symlink but this is too
                # rarely used to be worth the complexity.
                print(io, "    bare registry")
            else
                print(io, "    unknown registry format")
            end
            update_time = get(registry_update_log, string(reg.uuid), nothing)
            if !isnothing(update_time)
                time_string = Dates.format(update_time, dateformat"yyyy-mm-dd HH:MM:SS")
                print(io, ", last updated $(time_string)")
            end
            println(io)

            if registry_type != :git && !isnothing(server_registry_info)
                server_url, registries = server_registry_info
                if haskey(registries, reg.uuid)
                    print(io, "    served by $(server_url)")
                    if flavor != ""
                        print(io, " ($flavor flavor)")
                    end
                    if registries[reg.uuid] != reg.tree_info
                        print(io, " - update available")
                    end
                    println(io)
                end
            end
        end
    end
end

# The registry can be installed in a number of different ways, for
# evolutionary reasons.
#
# 1. A tarball that is not unpacked. In this case Pkg handles the
# registry in memory. The tarball is distributed by a package server.
# This is the preferred option, in particular for the General
# registry.
#
# 2. A tarball that is unpacked. This only differs from above by
# having the files on disk instead of in memory. In both cases Pkg
# keeps track of the tarball's tree hash to know if it can be updated.
#
# 3. A clone of a git repository. This is characterized by the
# presence of a .git directory. All updating is handled with git.
# This is not preferred for the General registry but may be the only
# practical option for private registries.
#
# 4. A bare registry with only the registry files and no metadata.
# This can be installed by adding or symlinking from a local path but
# there is no way to update it from Pkg.
#
# It is also possible for a packed/unpacked registry to coexist on
# disk with a git/bare registry, in which case a new Julia may use the
# former and a sufficiently old Julia the latter.
function get_registry_type(reg)
    isnothing(reg.in_memory_registry) || return :packed
    isnothing(reg.tree_info) || return :unpacked
    isdir(joinpath(reg.path, ".git")) && return :git
    isfile(joinpath(reg.path, "Registry.toml")) && return :bare
    # Indicates either that the registry data is corrupt or that it
    # has been handled by a future Julia version with non-backwards
    # compatible conventions.
    return :unknown
end

end # module
