#!/usr/bin/env julia

import Pkg
import Pkg.Types: VersionSpec, VersionRange, VersionBound, semver_spec
import Base: thismajor, thisminor, thispatch, nextmajor, nextminor, nextpatch

const STDLIBS = [
    "Base64"
    "CRC32c"
    "Dates"
    "DelimitedFiles"
    "Distributed"
    "FileWatching"
    "Future"
    "InteractiveUtils"
    "Libdl"
    "LibGit2"
    "LinearAlgebra"
    "Logging"
    "Markdown"
    "Mmap"
    "Pkg"
    "Printf"
    "Profile"
    "Random"
    "REPL"
    "Serialization"
    "SHA"
    "SharedArrays"
    "Sockets"
    "SparseArrays"
    "Statistics"
    "SuiteSparse"
    "Test"
    "Unicode"
    "UUIDs"
]

function uuid(name::AbstractString)
    string(Pkg.METADATA_compatible_uuid(String(name)))
end

function uses(repo::AbstractString, lib::AbstractString)
    pattern = string(raw"\b(import|using)\s+((\w|\.)+\s*,\s*)*", lib, raw"\b")
    success(`git -C $repo grep -Eq $pattern -- '*.jl'`)
end

function semver(intervals)
    spec = String[]
    for ival in intervals
        if ival.upper == v"∞"
            push!(spec, "≥ $(thispatch(ival.lower))")
        else
            lo, hi = ival.lower, ival.upper
            if lo.major < hi.major
                push!(spec, "^$(lo.major).$(lo.minor).$(lo.patch)")
                for major = lo.major+1:hi.major-1
                    push!(spec, "~$major")
                end
                for minor = 0:hi.minor-1
                    push!(spec, "~$(hi.major).$minor")
                end
                for patch = 0:hi.patch-1
                    push!(spec, "=$(hi.major).$(hi.minor).$patch")
                end
            elseif lo.minor < hi.minor
                push!(spec, "~$(lo.major).$(lo.minor).$(lo.patch)")
                for minor = lo.minor+1:hi.minor-1
                    push!(spec, "~$(hi.major).$minor")
                end
                for patch = 0:hi.patch-1
                    push!(spec, "=$(hi.major).$(hi.minor).$patch")
                end
            else
                for patch = lo.patch:hi.patch-1
                    push!(spec, "=$(hi.major).$(hi.minor).$patch")
                end
            end
        end
    end
    return join(spec, ", ")
end

if ARGS[1] == "-f"
    const force = true
    popfirst!(ARGS)
else
    const force = false
end
isempty(ARGS) && (push!(ARGS, pwd()))

for arg in ARGS
    dir = abspath(expanduser(arg))
    isdir(dir) ||
        @error "$arg does not appear to be a package (not a directory)"

    name = basename(dir)
    if isempty(name)
        dir = dirname(dir)
        name = basename(dir)
    end
    endswith(name, ".jl") && (name = chop(name, tail=3))

    project_file = joinpath(dir, "Project.toml")
    !force && isfile(project_file) &&
        @error "$arg already has a project file"

    require_file = joinpath(dir, "REQUIRE")
    isfile(require_file) ||
        @error "$arg does not appear to be a package (no REQUIRE file)"

    project = Dict(
        "name" => name,
        "uuid" => uuid(name),
        "deps" => Dict{String,String}(),
        "compat" => Dict{String,String}(),
    )

    reqs = Pkg.Pkg2.Reqs.read(require_file)
    for req in reqs
        dep = String(req.package)
        if dep != "julia"
            project["deps"][dep] = uuid(dep)
        end
        if req.versions != Pkg.Pkg2.Pkg2Types.VersionSet()
            project["compat"][dep] = semver(req.versions.intervals)
        end
    end

    for stdlib in STDLIBS
        if uses(dir, stdlib)
            project["deps"][stdlib] = uuid(stdlib)
        end
    end

    println(stderr, "Generating project file for $name: $project_file")
    open(project_file, "w") do io
        Pkg.TOML.print(io, project, sorted=true)
    end
    project = Pkg.Types.read_project(project_file)
    Pkg.Types.write_project(project, project_file)
end
