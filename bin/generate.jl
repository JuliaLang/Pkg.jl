#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

import Pkg.Compress
import Pkg.Types: compress_versions

prefix = joinpath(homedir(), ".julia", "registries", "General")

write_toml(prefix, "Registry") do io
    repo = "https://github.com/JuliaRegistries/General.git"
    uuid = string(uuid5(uuid_registry, repo))
    println(io, "name = ", repr("General"))
    println(io, "uuid = ", repr(uuid))
    println(io, "repo = ", repr(repo))
    println(io, "\ndescription = \"\"\"")
    print(io, """
        Official general Julia package registry where people can
        register any package they want without too much debate about
        naming and without enforced standards on documentation or
        testing. We nevertheless encourage documentation, testing and
        some amount of consideration when choosing package names.
        """)
    println(io, "\"\"\"")
    println(io, "\n[packages]")
    for (pkg, p) in sort!(collect(pkgs), by=(p->p.uuid.value)∘last)
        bucket = string(uppercase(first(pkg)))
        path = joinpath(bucket, pkg)
        println(io, p.uuid, " = { name = ", repr(pkg), ", path = ", repr(path), " }")
    end
end

buckets = Dict()
for (pkg, p) in pkgs
    bucket = string(uppercase(first(pkg)))
    push!(get!(buckets, bucket, []), (pkg, p))
end

const trees, stdlibs = gitmeta(pkgs)

for pkg in STDLIBS
    tree = stdlib_trees[pkg]
    deps = Dict(dep => Require(VersionInterval()) for dep in stdlib_deps[pkg])
    pkgs[pkg] = Package(
        UUID(stdlib_uuids[pkg]),
        "https://github.com/JuliaLang/julia.git",
        Dict(VersionNumber(0,7,0,("DEV",),("r"*tree[1:8],)) => Version(tree, deps)),
    )
end

for (pkg, p) in pkgs
    uuid = string(p.uuid)
    haskey(stdlibs, uuid) || continue
    for (ver, v) in p.versions
        n = get(stdlibs[uuid], v.sha1, 0)
        n == 0 && continue
        for lib in STDLIBS
            if n & 1 != 0
                v.requires[lib] = Require(VersionInterval())
            end
            n >>>= 1
        end
    end
end

for (bucket, b_pkgs) in buckets, (pkg, p) in b_pkgs
    haskey(stdlibs, pkg) && continue
    url = p.url
    uuid = string(p.uuid)
    startswith(url, "git://github.com") && (url = "https"*url[4:end])

    # Package.toml
    write_toml(prefix, bucket, pkg, "Package") do io
        println(io, "name = ", repr(pkg))
        println(io, "uuid = ", repr(uuid))
        println(io, "repo = ", repr(url))
    end

    # Versions.toml
    write_toml(prefix, bucket, pkg, "Versions") do io
        for (i, (ver, v)) in enumerate(sort!(collect(p.versions), by=first))
            i > 1 && println(io)
            println(io, "[", toml_key(string(ver)), "]")
            println(io, "git-tree-sha1 = ", repr(trees[uuid][v.sha1]))
        end
    end
    versions = sort!(collect(keys(p.versions)))

    function uncompressed_data(f::Function)
        data = Dict{VersionNumber,Dict{String,Any}}()
        for (ver, v) in p.versions, (dep, d) in v.requires
            val = f(dep, d)
            val == nothing && continue
            haskey(data, ver) || (data[ver] = Dict{String,Any}())
            data[ver][dep] = val
        end
        return data
    end

    # Deps.toml
    deps_data = uncompressed_data() do dep, d
        dep == "julia" ? nothing : string(pkgs[dep].uuid)
    end
    for (ver, deps) in deps_data
        if haskey(deps, "BinDeps") || haskey(deps, "BinaryProvider")
            deps["Libdl"] = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
        end
    end
    !isempty(deps_data) &&
    Compress.save(joinpath(prefix, bucket, pkg, "Deps.toml"), deps_data, versions)

    # Compat.toml
    compat_data = uncompressed_data() do dep, d
        dep in STDLIBS && return nothing
        pool = collect(keys(pkgs[dep].versions))
        ranges = compress_versions(pool, d.versions).ranges
        length(ranges) == 1 ? string(ranges[1]) : map(string, ranges)
    end
    !isempty(compat_data) &&
    Compress.save(joinpath(prefix, bucket, pkg, "Compat.toml"), compat_data, versions)
end
