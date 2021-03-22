module Environments

using UUIDs, TOML, Dates, ..Versions
using Base: SHA1
import ..Pkg
import ..logdir, ..safe_realpath, ..GitRepo, ..Bleh.PackageSpec, ..PkgError, ..pkgerror, ..parse_toml

Base.@kwdef mutable struct PackageEntry
    name::Union{String,Nothing} = nothing
    version::Union{VersionNumber,Nothing} = nothing
    path::Union{String,Nothing} = nothing
    pinned::Bool = false
    repo::GitRepo = GitRepo()
    tree_hash::Union{Nothing,SHA1} = nothing
    deps::Dict{String,UUID} = Dict{String,UUID}()
    other::Union{Dict,Nothing} = nothing
end
Base.:(==)(t1::PackageEntry, t2::PackageEntry) = t1.name == t2.name &&
    t1.version == t2.version &&
    t1.path == t2.path &&
    t1.pinned == t2.pinned &&
    t1.repo == t2.repo &&
    t1.tree_hash == t2.tree_hash &&
    t1.deps == t2.deps   # omits `other`
Base.hash(x::PackageEntry, h::UInt) = foldr(hash, [x.name, x.version, x.path, x.pinned, x.repo, x.tree_hash, x.deps], init=h)  # omits `other`

function Base.show(io::IO, pkg::PackageEntry)
    f = []
    pkg.name        !== nothing && push!(f, "name"      => pkg.name)
    pkg.version     !== nothing && push!(f, "version"   => pkg.version)
    pkg.tree_hash   !== nothing && push!(f, "tree_hash" => pkg.tree_hash)
    pkg.path        !== nothing && push!(f, "dev/path"  => pkg.path)
    pkg.pinned                  && push!(f, "pinned"    => pkg.pinned)
    pkg.repo.source !== nothing && push!(f, "url/path"  => "`$(pkg.repo.source)`")
    pkg.repo.rev    !== nothing && push!(f, "rev"       => pkg.repo.rev)
    pkg.repo.subdir !== nothing && push!(f, "subdir"    => pkg.repo.subdir)
    print(io, "PackageEntry(\n")
    for (field, value) in f
        print(io, "  ", field, " = ", value, "\n")
    end
    print(io, ")")
end

include("project.jl")
include("manifest.jl")
include("environment.jl")

end
