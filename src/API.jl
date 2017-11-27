module API

import Pkg3
import Pkg3.DEFAULT_DEV_PATH
using Pkg3.Types
using Base.Random.UUID
using SHA

previewmode_info() = info("In preview mode")

add(pkg::String; kwargs...)               = add([pkg]; kwargs...)
add(pkgs::Vector{String}; kwargs...)      = add([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
add(pkgs::Vector{PackageSpec}; kwargs...) = add(EnvCache(), pkgs; kwargs...)

function add(env::EnvCache, pkgs::Vector{PackageSpec}; preview::Bool=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    registry_resolve!(env, pkgs)
    path_resolve!(env, pkgs)
    ensure_resolved(env, pkgs, true)
    Pkg3.Operations.add(env, pkgs)
end


rm(pkg::String; kwargs...)               = rm([pkg]; kwargs...)
rm(pkgs::Vector{String}; kwargs...)      = rm([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
rm(pkgs::Vector{PackageSpec}; kwargs...) = rm(EnvCache(), pkgs; kwargs...)

function rm(env::EnvCache, pkgs::Vector{PackageSpec}; preview::Bool=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    manifest_resolve!(env, pkgs)
    path_resolve!(env, pkgs)
    Pkg3.Operations.rm(env, pkgs)
end


up(;kwargs...)                           = up(PackageSpec[], kwargs...)
up(pkg::String; kwargs...)               = up([pkg]; kwargs...)
up(pkgs::Vector{String}; kwargs...)      = up([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
up(pkgs::Vector{PackageSpec}; kwargs...) = up(EnvCache(), pkgs; kwargs...)

function up(env::EnvCache, pkgs::Vector{PackageSpec};
            level::UpgradeLevel=UpgradeLevel(:major), mode::Symbol=:project, preview::Bool=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    if isempty(pkgs)
        if mode == :project
            for (name::String, uuid::UUID) in env.project["deps"]
                push!(pkgs, PackageSpec(name, uuid, level))
            end
        elseif mode == :manifest
            for (name, infos) in env.manifest, info in infos
                uuid = UUID(info["uuid"])
                push!(pkgs, PackageSpec(name, uuid, level))
            end
        end
    else
        project_resolve!(env, pkgs)
        manifest_resolve!(env, pkgs)
        ensure_resolved(env, pkgs)
    end
    path_resolve!(env, pkgs)
    Pkg3.Operations.up(env, pkgs)
end

test(;kwargs...)                           = test(PackageSpec[], kwargs...)
test(pkg::String; kwargs...)               = test([pkg]; kwargs...)
test(pkgs::Vector{String}; kwargs...)      = test([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
test(pkgs::Vector{PackageSpec}; kwargs...) = test(EnvCache(), pkgs; kwargs...)

function test(env::EnvCache, pkgs::Vector{PackageSpec}; coverage=false, preview=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    manifest_resolve!(env, pkgs)
    path_resolve!(env, pkgs)
    ensure_resolved(env, pkgs)
    Pkg3.Operations.test(env, pkgs; coverage=coverage)
end



## Computing UUID5 values from (namespace, key) pairs ##
function uuid5(namespace::UUID, key::String)
    data = [reinterpret(UInt8, [namespace.value]); Vector{UInt8}(key)]
    u = reinterpret(UInt128, sha1(data)[1:16])[1]
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end
uuid5(namespace::UUID, key::AbstractString) = uuid5(namespace, String(key))

const uuid_dns = UUID(0x6ba7b810_9dad_11d1_80b4_00c04fd430c8)
const uuid_julia = uuid5(uuid_dns, "julialang.org")
const uuid_package = uuid5(uuid_julia, "package")
const uuid_registry = uuid5(uuid_julia, "registry")

function url_and_pkg(url_or_pkg::AbstractString)
    # try to parse as URL or local path
    m = match(r"(?:^|[/\\])(\w+?)(?:\.jl)?(?:\.git)?$", url_or_pkg)
    m === nothing && throw(PkgError("can't determine package name from URL: $url_or_pkg"))
    return url_or_pkg, m.captures[1]
end
clone(pkg::String; kwargs...) = clone(pkg; kwargs...)

function clone(env::EnvCache, url::AbstractString; name=nothing, basepath=nothing, preview=env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    if name == nothing
        url, name = url_and_pkg(url)
    end
    basepath == nothing && (basepath = get(ENV, "JULIA_PKG_DEV_PATH", DEFAULT_DEV_PATH))
    pkg = PackageSpec(name=name, path=joinpath(basepath, name), url=url)
    registry_resolve!(env, [pkg])
    project_resolve!(env, [pkg])
    manifest_resolve!(env, [pkg])
    path_resolve!(env, [pkg])
    # Cloning a non existent package, give it a UUID and version
    if !has_uuid(pkg)
        pkg.version = v"0.0"
        pkg.uuid = uuid5(uuid_package, pkg.name)
    end
    ensure_resolved(env, [pkg])
    Pkg3.Operations.clone(env, [pkg])
end


free(;kwargs...)                           = free(PackageSpec[], kwargs...)
free(pkg::String; kwargs...)               = free([pkg]; kwargs...)
free(pkgs::Vector{String}; kwargs...)      = free([PackageSpec(pkg) for pkg in pkgs]; kwargs...)
free(pkgs::Vector{PackageSpec}; kwargs...) = free(EnvCache(), pkgs; kwargs...)
function free(env::EnvCache, pkgs::Vector{PackageSpec}; preview = env.preview[])
    env.preview[] = preview
    preview && previewmode_info()
    project_resolve!(env, pkgs)
    manifest_resolve!(env, pkgs)
    ensure_resolved(env, pkgs)
    Pkg3.Operations.free(env, pkgs)
end


end # module

