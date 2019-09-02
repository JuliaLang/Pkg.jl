module PackageResolve

export project_resolve!, project_deps_resolve!, manifest_resolve!, registry_resolve!,
    stdlib_resolve!, ensure_resolved, registered_name

using UUIDs, REPL.TerminalMenus
using ..Contexts, ..PackageSpecs, ..RegistryOps, ..PkgErrors

###
### Resolving packages from name or uuid
###
function project_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    ctx.env.pkg === nothing && return # no project to resolve against
    for pkg in pkgs
        if has_uuid(pkg) && !has_name(pkg) && ctx.env.pkg.uuid == pkg.uuid
            pkg.name = ctx.env.pkg.name
        end
        if has_name(pkg) && !has_uuid(pkg) && ctx.env.pkg.name == pkg.name
            pkg.uuid = ctx.env.pkg.uuid
        end
    end
end

# Disambiguate name/uuid package specifications using project info.
function project_deps_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    uuids = ctx.env.project.deps
    names = Dict(uuid => name for (name, uuid) in uuids)
    for pkg in pkgs
        pkg.mode == PKGMODE_PROJECT || continue
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            pkg.uuid = uuids[pkg.name]
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
end

# Disambiguate name/uuid package specifications using manifest info.
function manifest_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    uuids = Dict{String,Vector{UUID}}()
    names = Dict{UUID,String}()
    for (uuid, entry) in ctx.env.manifest
        push!(get!(uuids, entry.name, UUID[]), uuid)
        names[uuid] = entry.name # can be duplicate but doesn't matter
    end
    for pkg in pkgs
        pkg.mode == PKGMODE_MANIFEST || continue
        if has_name(pkg) && !has_uuid(pkg) && pkg.name in keys(uuids)
            length(uuids[pkg.name]) == 1 && (pkg.uuid = uuids[pkg.name][1])
        end
        if has_uuid(pkg) && !has_name(pkg) && pkg.uuid in keys(names)
            pkg.name = names[pkg.uuid]
        end
    end
end

function stdlib_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            for (uuid, name) in ctx.stdlibs
                name == pkg.name && (pkg.uuid = uuid)
            end
        end
        if !has_name(pkg) && has_uuid(pkg)
            name = get(ctx.stdlibs, pkg.uuid, nothing)
            nothing !== name && (pkg.name = name)
        end
    end
end

###
### Disambiguate name/uuid package specifications using registry info.
###
registry_resolve!(ctx::Context, pkg::PackageSpec) = registry_resolve!(ctx, [pkg])
function registry_resolve!(ctx::Context, pkgs::AbstractVector{PackageSpec})
    # if there are no half-specified packages, return early
    any(pkg -> has_name(pkg) ⊻ has_uuid(pkg), pkgs) || return
    # collect all names and uuids since we're looking anyway
    names = String[pkg.name for pkg in pkgs if has_name(pkg)]
    uuids = UUID[pkg.uuid for pkg in pkgs if has_uuid(pkg)]
    RegistryOps.find_registered!(ctx, names, uuids)
    for pkg in pkgs
        @assert has_name(pkg) || has_uuid(pkg)
        if has_name(pkg) && !has_uuid(pkg)
            pkg.uuid = registered_uuid(ctx, pkg.name)
        end
        if has_uuid(pkg) && !has_name(pkg)
            pkg.name = registered_name(ctx, pkg.uuid)
        end
    end
    return pkgs
end

# Determine a single UUID for a given name, prompting if needed
function registered_uuid(ctx::Context, name::String)::Union{Nothing,UUID}
    uuids = RegistryOps.registered_uuids(ctx, name)
    length(uuids) == 0 && return nothing
    length(uuids) == 1 && return uuids[1]
    choices::Vector{String} = []
    choices_cache::Vector{Tuple{UUID,String}} = []
    for uuid in uuids
        values = registered_info(ctx, uuid, "repo")
        for value in values
            depot = "(unknown)"
            for d in depots()
                r = joinpath(d, "registries")
                startswith(value[1], r) || continue
                depot = split(relpath(value[1], r), Base.Filesystem.path_separator_re)[1]
                break
            end
            push!(choices, "Registry: $depot - Path: $(value[2])")
            push!(choices_cache, (uuid, value[1]))
        end
    end
    length(choices_cache) == 1 && return choices_cache[1][1]
    if isinteractive()
        # prompt for which UUID was intended:
        menu = RadioMenu(choices)
        choice = request("There are multiple registered `$name` packages, choose one:", menu)
        choice == -1 && return nothing
        ctx.reg.paths[choices_cache[choice][1]] = [choices_cache[choice][2]]
        return choices_cache[choice][1]
    else
        pkgerror("there are multiple registered `$name` packages, explicitly set the uuid")
    end
end

# Determine current name for a given package UUID
function registered_name(ctx::Context, uuid::UUID)::Union{Nothing,String}
    names = RegistryOps.registered_names(ctx, uuid)
    length(names) == 0 && return nothing
    length(names) == 1 && return names[1]
    infos = registered_info(ctx, uuid, "name")
    first_found_name = nothing
    for (path, name) in infos
        first_found_name === nothing && (first_found_name = name)
        if first_found_name != name
            pkgerror("Inconsistent registry information. ",
                     "Package `$uuid` has multiple registered names: `$first_found_name`, `$name`.")
        end
    end
    return name
end

# Ensure that all packages are fully resolved
function ensure_resolved(ctx::Context,
    pkgs::AbstractVector{PackageSpec};
    registry::Bool=false,)::Nothing
    unresolved = Dict{String,Vector{UUID}}()
    for name in [pkg.name for pkg in pkgs if !has_uuid(pkg)]
        uuids = [uuid for (uuid, entry) in ctx.env.manifest if entry.name == name]
        sort!(uuids, by=uuid -> uuid.value)
        unresolved[name] = uuids
    end
    isempty(unresolved) && return
    msg = sprint() do io
        println(io, "The following package names could not be resolved:")
        for (name, uuids) in sort!(collect(unresolved), by=lowercase ∘ first)
        print(io, " * $name (")
        if length(uuids) == 0
            what = ["project", "manifest"]
            registry && push!(what, "registry")
            print(io, "not found in ")
            join(io, what, ", ", " or ")
        else
            join(io, uuids, ", ", " or ")
            print(io, " in manifest but not in project")
        end
        println(io, ")")
    end
        print(io, "Please specify by known `name=uuid`.")
    end
    pkgerror(msg)
end

end #module
