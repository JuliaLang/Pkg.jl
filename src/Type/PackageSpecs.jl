module PackageSpecs

export PackageSpec, has_name, has_uuid,
       PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST, PKGMODE_COMBINED,
       UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR,
       PackageSpecialAction, PKGSPEC_NOTHING, PKGSPEC_PINNED, PKGSPEC_FREED,
           PKGSPEC_DEVELOPED, PKGSPEC_TESTED, PKGSPEC_REPO_ADDED

import Base: SHA1
using  UUIDs
using  ..VersionTypes, ..GitRepos

###
### Auxilary Types
###
@enum(UpgradeLevel, UPLEVEL_FIXED, UPLEVEL_PATCH, UPLEVEL_MINOR, UPLEVEL_MAJOR)
@enum(PackageMode, PKGMODE_PROJECT, PKGMODE_MANIFEST, PKGMODE_COMBINED)
@enum(PackageSpecialAction, PKGSPEC_NOTHING, PKGSPEC_PINNED, PKGSPEC_FREED,
                            PKGSPEC_DEVELOPED, PKGSPEC_TESTED, PKGSPEC_REPO_ADDED)

const _VersionTypes = Union{VersionNumber,VersionSpec,UpgradeLevel}

###
### PackageSpec
###
Base.@kwdef mutable struct PackageSpec
    name::Union{Nothing,String} = nothing
    uuid::Union{Nothing,UUID} = nothing
    version::_VersionTypes = VersionSpec()
    tree_hash::Union{Nothing,SHA1} = nothing
    repo::GitRepo = GitRepo()
    path::Union{Nothing,String} = nothing
    pinned::Bool = false
    special_action::PackageSpecialAction = PKGSPEC_NOTHING # If the package is currently being pinned, freed etc
    mode::PackageMode = PKGMODE_PROJECT
end
PackageSpec(name::AbstractString) = PackageSpec(;name=name)
PackageSpec(name::AbstractString, uuid::UUID) = PackageSpec(;name=name, uuid=uuid)
PackageSpec(name::AbstractString, version::_VersionTypes) = PackageSpec(;name=name, version=version)
PackageSpec(n::AbstractString, u::UUID, v::_VersionTypes) = PackageSpec(;name=n, uuid=u, version=v)

function Base.show(io::IO, pkg::PackageSpec)
    vstr = repr(pkg.version)
    f = []
    pkg.name      !== nothing && push!(f, "name" => pkg.name)
    pkg.uuid      !== nothing && push!(f, "uuid" => pkg.uuid)
    pkg.path      !== nothing && push!(f, "dev/path" => pkg.path)
    pkg.tree_hash !== nothing && push!(f, "tree_hash" => pkg.tree_hash)
    pkg.pinned                && push!(f, "pinned" => pkg.pinned)
    pkg.repo.url  !== nothing && push!(f, "url/path" => string("\"", pkg.repo.url, "\""))
    pkg.repo.rev  !== nothing && push!(f, "rev" => pkg.repo.rev)
    push!(f, "version" => (vstr == "VersionSpec(\"*\")" ? "*" : vstr))
    print(io, "PackageSpec(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", value, "\n")
    end
    print(io, ")")
end

function Base.getindex(pkgs::Vector{PackageSpec}, uuid::UUID)
    index = findfirst(pkg -> pkg.uuid == uuid, pkgs)
    return index === nothing ? nothing : pkgs[index]
end

###
### Utils
###
has_name(pkg::PackageSpec) = pkg.name !== nothing
has_uuid(pkg::PackageSpec) = pkg.uuid !== nothing

end #module
