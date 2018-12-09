#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

using Base: thispatch, thisminor, nextpatch, nextminor
import LinearAlgebra: checksquare
import UUIDs
import Pkg
using Pkg.Types
using Pkg.Types: uuid_package, uuid_registry, uuid5
import Pkg.Pkg2.Reqs: Reqs, Requirement
import Pkg.Pkg2.Pkg2Types: VersionInterval, VersionSet

## Loading data into various data structures ##

struct Require
    versions::VersionSet
    systems::Vector{Symbol}
end

struct Version
    sha1::String
    requires::Dict{String,Require}
end

struct Package
    uuid::UUID
    url::String
    versions::Dict{VersionNumber,Version}
end

Require(versions::VersionSet) = Require(versions, Symbol[])
Require(version::VersionInterval) = Require(VersionSet([version]), Symbol[])
Version(sha1::AbstractString) = Version(String(sha1), Dict{String,Require}())

function load_requires(path::String)
    requires = Dict{String,Require}()
    requires["julia"] = Require(VersionInterval())
    isfile(path) || return requires
    for r in filter!(r->r isa Requirement, Reqs.read(path))
        new = haskey(requires, r.package)
        versions, systems = VersionSet(r.versions.intervals), r.system
        if haskey(requires, r.package)
            versions = versions ∩ requires[r.package].versions
            systems  = systems  ∪ requires[r.package].systems
        end
        requires[r.package] = Require(versions, Symbol.(systems))
    end
    return requires
end

function load_versions(dir::String)
    versions = Dict{VersionNumber,Version}()
    isdir(dir) || return versions
    for ver in readdir(dir)
        path = joinpath(dir, ver)
        sha1 = joinpath(path, "sha1")
        isfile(sha1) || continue
        requires = load_requires(joinpath(path, "requires"))
        versions[VersionNumber(ver)] = Version(readchomp(sha1), requires)
    end
    return versions
end

const JULIA_VERSIONS = Dict{VersionNumber,Version}()
# Note: This is a dummy commit that will get overwritten by the loop below once 1.1 is released
JULIA_VERSIONS[v"1.1.0"] = Version("6ef1d76c50a39c0ce68b4e42948a1499c1551415")
for line in eachline(`git -C $(dirname(dirname(Sys.STDLIB))) ls-remote --tags origin`)
    global JULIA_VERSIONS
    # Lines are in the form 'COMMITSHA\trefs/tags/TAG'
    sha, ref = split(line, '\t')
    _, _, tag = split(ref, '/')
    occursin(Base.VERSION_REGEX, tag) || continue
    ver = VersionNumber(tag)
    JULIA_VERSIONS[ver] = Version(sha)
end

function load_packages(dir::String)
    pkgs = Dict{String,Package}()
    for pkg in readdir(dir)
        path = joinpath(dir, pkg)
        url = joinpath(path, "url")
        versions = joinpath(path, "versions")
        isfile(url) || continue
        pkgs[pkg] = Package(
            uuid5(uuid_package, pkg),
            readchomp(url),
            load_versions(versions),
        )
    end
    pkgs["julia"] = Package(
        uuid5(uuid_package, "julia"),
        "https://github.com/JuliaLang/julia.git",
        JULIA_VERSIONS,
    )
    return pkgs
end

@eval julia_versions() = $(sort!(collect(keys(JULIA_VERSIONS))))
julia_versions(f::Function) = filter(f, julia_versions())
julia_versions(vi::VersionInterval) = julia_versions(v->v in vi)

macro clean(ex) :(x = $(esc(ex)); $(esc(:clean)) &= x; x) end

function prune!(pkgs::AbstractDict{String,Package})
    # remove unsatisfiable versions
    while true
        clean = true
        filter!(pkgs) do (pkg, p)
            filter!(p.versions) do (ver, v)
                @clean ver == thispatch(ver) > v"0.0.0" &&
                all(v.requires) do kv
                    req, r = kv
                    haskey(pkgs, req) &&
                    any(w->w in r.versions, keys(pkgs[req].versions))
                end
            end
            @clean !isempty(p.versions)
        end
        clean && break
    end
    return pkgs
end

## Load package data ##

const pkgs = load_packages(Pkg.Pkg2.dir("METADATA"))

# delete packages whose repos that no longer exist:
for pkg in [
    "CardinalDicts"
    "CreateMacrosFrom"
    "GSDicts"
    "S3Dicts"
    "ChainMap"
    "NanoTimes"
    "OnlineMoments"
    "ProjectiveDictionaryPairLearning"
    "React"
    "PackageGenerator"
    "Sparrow"
    "KeyedTables"
    "Arduino"
    "ControlCore"
    "DynamicalBilliardsPlotting"
    "GLUT"
    "GetC"
]

    delete!(pkgs, pkg)
end

# cap julia version for probably-0.7-incompatible packages

const passing = readlines(joinpath(@__DIR__, "passing.txt"))
for pkg in passing
    haskey(pkgs, pkg) || continue
    p = pkgs[pkg]
    ver = maximum(keys(p.versions))
    v = p.versions[ver]
    for dep in keys(v.requires)
        dep == "julia" && continue
        dep in passing || push!(passing, dep)
    end
end
sort!(passing, by=lowercase)

const meta_dir = Pkg.Pkg2.dir("METADATA")
const time_map = Dict{Tuple{String,VersionNumber},Int}()
let t = 0
    for line in eachline(`git -C $meta_dir log --format=%ct --name-only`)
        if (m = match(r"^(\d+)$", line)) !== nothing
            t = parse(Int, line)
        elseif (m = match(r"^([^/]+)/versions/(\d+\.\d+\.\d+)/requires$", line)) !== nothing
            pkg = String(m.captures[1])
            ver = VersionNumber(m.captures[2])
            haskey(time_map, (pkg, ver)) && continue
            time_map[pkg,ver] = t
        end
    end
end

const all_vers = julia_versions()
const old_vers = julia_versions(v -> v < v"0.7")
const jul_14 = 1531526400 # Jul 14, 2018
const oct_10 = 1539129600 # Oct 10, 2018

function cap_compat!(pkg::String, ver::VersionNumber, reqs::Dict{String,Require})
    jvers = reqs["julia"].versions
    ivals = jvers.intervals
    isempty(ivals) && return
    t = get(time_map, (pkg, ver), 0)
    if pkg in passing && ver ≥ maximum(keys(pkgs[pkg].versions)) || !isempty(ivals[end]) &&
        (ivals[end].upper < v"∞" || !any(v->v in ivals[end] && v < v"0.7", all_vers))
        # in the "passing list" from pkgeval and maxiumal version => leave alone
        # has final interval with explicit upper bound => leave alone
        # or interval only containing 0.7+ versions => 1.0 compatible
        return # no change
    elseif (v"0.7" in jvers || v"1.0" in jvers) && t ≥ oct_10
        # recently tagged and claims to support 0.7/1.0 => face value
        return # no change
    elseif pkg != "Compat" && !haskey(reqs, "Compat") && any(v in jvers for v in old_vers)
        # supports an older julia & doesn't use Compat => 0.7 incompatible
        # fall through
    elseif (v"0.7" in jvers || v"1.0" in jvers) && t ≥ jul_14
        # claims to support 0.7+ & tagged after date cutoff => 1.0 compatible
        return # no change
    end
    # cap supported Julia versions at 0.7
    ivals[end] = VersionInterval(ivals[end].lower, v"0.7+")
    return
end

for (pkg, p) in pkgs
    (pkg == "julia" || pkg == "Example") && continue
    for (ver, v) in p.versions
        cap_compat!(pkg, ver, v.requires)
    end
end

# prune versions that can't be satisfied
prune!(pkgs)
