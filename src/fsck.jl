# This file is a part of Julia. License is MIT: https://julialang.org/license

module Fsck

using TOML
using Base: UUID, SHA1
using ..Pkg: depots
using ..Types: Types, Context, RegistrySpec
using ..Operations: find_installed
using ..GitTools: GitTools

struct FsckComplication
    type
    severity
    repairable::Bool
end

function fsck(ctx::Context)
    fsck_packages(ctx)
    fsck_registries(ctx)
end


##############
## Packages ##
##############
function fsck_packages(ctx::Context)
    for (uuid, pkg) in ctx.env.manifest
        fsck_package(uuid, pkg)
    end
end

function fsck_package(uuid, pkg)

    pkg.tree_hash === nothing && return # Anything to check here?

    path = find_installed(pkg.name, uuid, pkg.tree_hash)
    computed = SHA1(GitTools.tree_hash(path))
    if computed != pkg.tree_hash
        @warn "Content hash mismatch for package $(pkg.name)=$(uuid)" expected=pkg.tree_hash computed
    end
end


################
## Registries ##
################

function fsck_registries(ctx::Context)
    for depot in depots()
        rdir = joinpath(depot, "registries")
        isdir(rdir) || continue
        for regdir in filter!(isdir, readdir(rdir; join=true))
            tree_info = joinpath(regdir, ".tree_info.toml")
            if isfile(tree_info)
                ti = TOML.tryparsefile(tree_info)
                ti === nothing && @warn "corrupt .tree_info.toml"
                # Remove the file for computation
                rm(tree_info)
                expected = SHA1(ti["git-tree-sha1"])
                computed = SHA1(GitTools.tree_hash(regdir))
                if computed != expected
                    @warn "Content hash mismatch for registry" expected computed
                end
                # Put it back
                open(tree_info, "w") do io
                    TOML.print(io, ti)
                end
            end
            toml = joinpath(regdir, "Registry.toml")
            isfile(toml) || @warn "Missing Registry.toml" folder=regdir
            dict = TOML.tryparsefile(toml)
            dict === nothing && @warn "Unparsable TOML"
            haskey(dict, "name") || @warn "No name"
            haskey(dict, "uuid") || @warn "No uuid"
            haskey(dict, "repo") || @warn "No repo"
            haskey(dict, "packages") || @warn "No packages"
            dict["packages"] isa Dict{String,Any} || @warn "bad package section"
            for (uuid, data) in dict["packages"]
                tryparse(UUID, uuid) === nothing && @warn "not uuid"
                haskey(data, "name") || @warn "no name"
                haskey(data, "path") || @warn "no path"
                pkg_dir = joinpath(regdir, data["path"])
                isdir(pkg_dir) || @warn "missing directory"
                pkg_toml = joinpath(pkg_dir, "Package.toml")
                isfile(pkg_toml) || @warn "no pkg.toml"
                vers_toml = joinpath(pkg_dir, "Versions.toml")
                isfile(vers_toml) || @warn "no vers.toml"
            end
        end
    end
end

function fsck_registry(ctx::Context, reg::RegistrySpec)
    @show reg
end

end # module
