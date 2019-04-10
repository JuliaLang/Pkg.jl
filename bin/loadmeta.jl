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

const JULIA_VERSIONS = Dict(
    v"0.1.1"  => Version("bddb70374fdbb2256782398c13430fa4d8b55d0b"),
    v"0.1.2"  => Version("1187040d027210cc466f0b6a6d54118fd692cf2d"),
    v"0.2.0"  => Version("05c6461b55d9a66f05ead24926f5ee062b920d6b"),
    v"0.2.1"  => Version("e44b5939057d87c1e854077108a1a6d66203f4fa"),
    v"0.3.0"  => Version("768187890c2709bf2ff06818f40e1cdc79bd44b0"),
    v"0.3.1"  => Version("c03f413bbdb46c00033f4eaad402995cfe3b7be5"),
    v"0.3.2"  => Version("8227746b95146c2921f83d2ae5f37ecd146592d8"),
    v"0.3.3"  => Version("b24213b893ace6ca601722f6cdaac15f2b034b7b"),
    v"0.3.4"  => Version("33920266908e950936ef3f8503810a2d47333741"),
    v"0.3.5"  => Version("a05f87b79ad62beb033817fdfdefa270c9557aaf"),
    v"0.3.6"  => Version("0c24dca65c031820b91721139f0291068086955c"),
    v"0.3.7"  => Version("cb9bcae93a32b42cec02585c387396ff11836aed"),
    v"0.3.8"  => Version("79599ada444fcc63cb08aed64b4ff6a415bb4d29"),
    v"0.3.9"  => Version("31efe690bea1fd8f4e44692e205fb72d34f50ad3"),
    v"0.3.10" => Version("c8ceeefcc1dc25953a644622a895a3adcbc80dad"),
    v"0.3.11" => Version("483dbf5279efe29f94cf35d42de0ab0a673fb34e"),
    v"0.3.12" => Version("80aa77986ec84067f4696439f10fc77c93703bc7"),
    v"0.4.0"  => Version("0ff703b40afddf9b705bd6a06d3a59cb4c089ea5"),
    v"0.4.1"  => Version("cbe1bee3a8f27ba4f349556857bf4615ee5fa68f"),
    v"0.4.2"  => Version("bb73f3489d837e3339fce2c1aab283d3b2e97a4c"),
    v"0.4.3"  => Version("a2f713dea5ac6320d8dcf2835ac4a37ea751af05"),
    v"0.4.4"  => Version("ae683afcc4cc824dcf68251569a6cf8760e4fb6f"),
    v"0.4.5"  => Version("2ac304dfba75fad148d4070ef4f8a2e400c305bb"),
    v"0.4.6"  => Version("2e358ce975029ec97aba5994c17d4a2169c3b085"),
    v"0.4.7"  => Version("ae26b25d43317d7dd3ca05f60b70677aab9c0e08"),
    v"0.5.0"  => Version("3c9d75391c72d7c32eea75ff187ce77b2d5effc8"),
    v"0.5.1"  => Version("6445c82d0060dbe82b88436f0f4371a4ee64d918"),
    v"0.5.2"  => Version("f4c6c9d4bbbd9587d84494e314f692c15ff1f9c0"),
    v"0.6.0"  => Version("903644385b91ed8d95e5e3a5716c089dd1f1b08a"),
    v"0.6.1"  => Version("0d7248e2ff65bd6886ba3f003bf5aeab929edab5"),
    v"0.6.2"  => Version("d386e40c17d43b79fc89d3e579fc04547241787c"),
    v"0.7.0"  => Version("a4cb80f3edcf8cea00bd9660e3b65f544f41462f"),
    v"1.0.0"  => Version("5d4eaca0c9fa3d555c79dbacdccb9169fdf64b65"),
    v"1.0.1"  => Version("0d713926f85dfa3e4e0962215b909b8e47e94f48"),
    v"1.0.2"  => Version("d789231e9985537686052db9b2314c0d51656308"),
    v"1.0.3"  => Version("099e826241fca365a120df9bac9a9fede6e7bae4"),
    v"1.1.0"  => Version("80516ca20297a67b996caa08c38786332379b6a5"),
    v"1.2.0"  => Version("217d330296debe0567bb07addabf66b00602e325"), # dummy commit, not actual 1.2
    v"1.3.0"  => Version("62d7ec55fd8063c722bc79b72c6d20b34a887c39"), # dummy commit, not actual 1.3
)

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
    "PhasedArrayTracking"
    "SimilarReferences"
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
