module RegistryOps

export find_registered!, registered_paths

import LibGit2
using  UUIDs
import ..UPDATED_REGISTRY_THIS_SESSION, ..depots1, ..GitOps
using  ..Contexts, ..RegistrySpecs, ..PkgErrors, ..Utils

###
### Constants
###
const DEFAULT_REGISTRIES =
    RegistrySpec[RegistrySpec(name = "General",
                              uuid = UUID("23338594-aafe-5451-b93e-139f81909106"),
                              url = "https://github.com/JuliaRegistries/General.git")]

###
### entry point for `registry add`
###
clone_or_cp_registries(regs::Vector{RegistrySpec}, depot::String=depots1()) =
    clone_or_cp_registries(Context(), regs, depot)
function clone_or_cp_registries(ctx::Context, regs::Vector{RegistrySpec}, depot::String=depots1())
    if ctx.preview
        println(ctx.io, "Skipping adding registries in preview mode")
        return nothing
    end
    populate_known_registries_with_urls!(regs)
    for reg in regs
        if reg.path !== nothing && reg.url !== nothing
            pkgerror("ambiguous registry specification; both url and path is set.")
        end
        # clone to tmpdir first
        tmp = mktempdir()
        if reg.path !== nothing # copy from local source
            printpkgstyle(ctx, :Copying, "registry from `$(Base.contractuser(reg.path))`")
            cp(reg.path, tmp; force=true)
        elseif reg.url !== nothing # clone from url
            Base.shred!(LibGit2.CachedCredentials()) do creds
                LibGit2.with(GitOps.clone(ctx, reg.url, tmp; header = "registry from $(repr(reg.url))",
                    credentials = creds)) do repo
                end
            end
        else
            pkgerror("no path or url specified for registry")
        end
        # verify that the clone looks like a registry
        if !isfile(joinpath(tmp, "Registry.toml"))
            pkgerror("no `Registry.toml` file in cloned registry.")
        end
        registry = read_registry(joinpath(tmp, "Registry.toml"); cache=false) # don't cache this tmp registry
        verify_registry(registry)
        # copy to `depot`
        # slug = Base.package_slug(UUID(registry["uuid"]))
        regpath = joinpath(depot, "registries", registry["name"]#=, slug=#)
        ispath(dirname(regpath)) || mkpath(dirname(regpath))
        if isdir_windows_workaround(regpath)
            existing_registry = read_registry(joinpath(regpath, "Registry.toml"))
            if registry["uuid"] == existing_registry["uuid"]
                println(ctx.io,
                        "registry `$(registry["name"])` already exist in `$(Base.contractuser(regpath))`.")
            else
                throw(PkgError("registry `$(registry["name"])=\"$(registry["uuid"])\"` conflicts with " *
                    "existing registry `$(existing_registry["name"])=\"$(existing_registry["uuid"])\"`. " *
                    "To install it you can clone it manually into e.g. " *
                    "`$(Base.contractuser(joinpath(depot, "registries", registry["name"]*"-2")))`."))
            end
        else
            cp(tmp, regpath)
            printpkgstyle(ctx, :Added, "registry `$(registry["name"])` to `$(Base.contractuser(regpath))`")
        end
        # Clean up
        Base.rm(tmp; recursive=true, force=true)
    end
    return nothing
end

###
### entry point for `registry rm`
###
function remove_registries(ctx::Context, regs::Vector{RegistrySpec})
    if ctx.preview
        println(ctx.io, "skipping removing registries in preview mode")
        return nothing
    end
    for registry in find_installed_registries(ctx, regs)
        printpkgstyle(ctx, :Removing, "registry `$(registry.name)` from $(Base.contractuser(registry.path))")
        rm(registry.path; force=true, recursive=true)
    end
    return nothing
end

###
### entry point for `registry up`
###
function update_registries(ctx::Context, regs::Vector{RegistrySpec} = collect_registries(depots1());
                           force::Bool=false)
    !force && UPDATED_REGISTRY_THIS_SESSION[] && return
    errors = Tuple{String, String}[]
    if ctx.preview
        println(ctx.io, "skipping updating registries in preview mode")
        return nothing
    end
    for reg in unique(r -> r.uuid, find_installed_registries(ctx, regs))
        if isdir(joinpath(reg.path, ".git"))
            regpath = pathrepr(reg.path)
            printpkgstyle(ctx, :Updating, "registry at " * regpath)
            # Using LibGit2.with here crashes julia when running the
            # tests for PkgDev wiht "Unreachable reached".
            # This seems to work around it.
            repo = nothing
            try
                repo = LibGit2.GitRepo(reg.path)
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
                    GitOps.fetch(ctx, repo; refspecs=["+refs/heads/$branch:refs/remotes/origin/$branch"])
                catch e
                    e isa PkgError || rethrow()
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
            finally
                if repo isa LibGit2.GitRepo
                    close(repo)
                end
            end
        end
    end
    if !isempty(errors)
        warn_str = "Some registries failed to update:"
        for (reg, err) in errors
            warn_str *= "\n    — $reg — $err"
        end
        @warn warn_str
    end
    UPDATED_REGISTRY_THIS_SESSION[] = true
    return
end

# Search for the input registries among installed ones
function find_installed_registries(ctx::Context,
                                   needles::Vector{RegistrySpec},
                                   haystack::Vector{RegistrySpec}=collect_registries())
    output = RegistrySpec[]
    for needle in needles
        if needle.name === nothing && needle.uuid === nothing
            pkgerror("no name or uuid specified for registry.")
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
                        pkgerror("multiple registries with name `$(needle.name)`, please specify with uuid.")
                    end
                    push!(output, candidate)
                    found = true
                end
            end
        end
        if !found
            println(ctx.io, "registry `$(needle.name === nothing ? needle.uuid :
                                         needle.uuid === nothing ? needle.name :
                                         "$(needle.name)=$(needle.uuid)")` not found.")
        end
    end
    return output
end

function clone_default_registries(ctx::Context)
    if isempty(collect_registries()) # only clone if there are no installed registries
        printpkgstyle(ctx, :Cloning, "default registries into $(pathrepr(depots1()))")
        clone_or_cp_registries(DEFAULT_REGISTRIES)
    end
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
                    pkgerror("multiple registries with name `$(reg.name)`, please specify with uuid.")
                end
                reg.url = known.url
            end
        end
    end
end

###
### Registry Queries
###
find_registered!(ctx::Context, uuid::UUID) = find_registered!(ctx, [uuid])
find_registered!(ctx::Context, name::String) = find_registered!(ctx, [name])
find_registered!(ctx::Context, uuids::Vector{UUID}) = find_registered!(ctx, String[], uuids)
find_registered!(ctx::Context, names::Vector{String}) = find_registered!(ctx, names, UUID[])
# Lookup package names & uuids in a single pass through registries
function find_registered!(ctx::Context,
    names::Vector{String},
    uuids::Vector{UUID},
)::Nothing
    # only look if there's something new to see
    names = filter(name -> !haskey(ctx.reg.uuids, name), names)
    uuids = filter(uuid -> !haskey(ctx.reg.paths, uuid), uuids)
    isempty(names) && isempty(uuids) && return

    # since we're looking anyway, look for everything
    save(name::String) =
        name in names || haskey(ctx.reg.uuids, name) || push!(names, name)
    save(uuid::UUID) =
        uuid in uuids || haskey(ctx.reg.paths, uuid) || push!(uuids, uuid)

    # lookup any dependency in the project file
    for (name, uuid) in ctx.env.project.deps
        save(name); save(uuid)
    end
    # lookup anything mentioned in the manifest file
    for (uuid, entry) in ctx.env.manifest
        save(uuid)
        save(entry.name)
    end
    # if there's still nothing to look for, return early
    isempty(names) && isempty(uuids) && return

    # initialize env entries for names and uuids
    for name in names; ctx.reg.uuids[name] = UUID[]; end
    for uuid in uuids; ctx.reg.paths[uuid] = String[]; end
    for uuid in uuids; ctx.reg.names[uuid] = String[]; end

    # note: empty vectors will be left for names & uuids that aren't found
    clone_default_registries(ctx)
    for registry in collect_registries()
        data = read_registry(joinpath(registry.path, "Registry.toml"))
        for (_uuid, pkgdata) in data["packages"]
              uuid = UUID(_uuid)
              name = pkgdata["name"]
              path = abspath(registry.path, pkgdata["path"])
              push!(get!(ctx.reg.uuids, name, UUID[]), uuid)
              push!(get!(ctx.reg.paths, uuid, String[]), path)
              push!(get!(ctx.reg.names, uuid, String[]), name)
        end
    end
    for d in (ctx.reg.uuids, ctx.reg.paths, ctx.reg.names)
        for (k, v) in d
            unique!(v)
        end
    end
end

# Get registered uuids associated with a package name
function registered_uuids(ctx::Context, name::String)::Vector{UUID}
    find_registered!(ctx, name)
    return unique(ctx.reg.uuids[name])
end

# Get registered paths associated with a package uuid
function registered_paths(ctx::Context, uuid::UUID)::Vector{String}
    find_registered!(ctx, uuid)
    return ctx.reg.paths[uuid]
end

#Get registered names associated with a package uuid
function registered_names(ctx::Context, uuid::UUID)::Vector{String}
    find_registered!(ctx, uuid)
    return ctx.reg.names[uuid]
end

# Return most current package info for a registered UUID
function registered_info(ctx::Context, uuid::UUID, key::String)
    haskey(ctx.reg.paths, uuid) || find_registered!(ctx, uuid)
    paths = ctx.reg.paths[uuid]
    isempty(paths) && pkgerror("`$uuid` is not registered")
    values = []
    for path in paths
        info = parse_toml(path, "Package.toml")
        value = get(info, key, nothing)
        push!(values, path => value)
    end
    return values
end

end #module
