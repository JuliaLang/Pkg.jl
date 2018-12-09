#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

import Pkg: TOML

prefix = joinpath(homedir(), ".julia", "registries", "Stdlib")

stdlib_uuids = Dict{String,String}()
stdlib_trees = Dict{String,String}()
stdlib_deps = Dict{String,Vector{String}}()

for pkg in readdir(Sys.STDLIB)
    project_file = joinpath(Sys.STDLIB, pkg, "Project.toml")
    isfile(project_file) || continue
    project = TOML.parsefile(project_file)
    stdlib_uuids[pkg] = project["uuid"]
    version_file = joinpath(Sys.STDLIB, "..", "..", "..", "..", "..", "stdlib", "$pkg.version")
    if isfile(version_file)
        r = Regex("^\\s*$(pkg)_SHA1\\s*=\\s*(\\S+)\\s*\$", "im")
        m = match(r, read(version_file, String))
        m === nothing && error("expected PKG_SHA1 in $version_file")
        stdlib_trees[pkg] = m.captures[1]
    else
        dir = dirname(realpath(joinpath(Sys.STDLIB, pkg)))
        stdlib_trees[pkg] = split(readchomp(`git -C $dir ls-tree HEAD -- $pkg`))[3]
    end
    stdlib_deps[pkg] = String[]
    haskey(project, "deps") || continue
    append!(stdlib_deps[pkg], sort!(collect(keys(project["deps"]))))
end

#=
write_toml(prefix, "Registry") do io
    repo = "https://github.com/JuliaRegistries/Stdlib.git"
    uuid = string(uuid5(uuid_registry, repo))
    println(io, "name = ", repr("Stdlib"))
    println(io, "uuid = ", repr(uuid))
    println(io, "repo = ", repr(repo))
    println(io, "\ndescription = \"\"\"")
    print(io, """
        Official Julia Standard Library registry where versions
        of packages that ship with Julia itself are registered.
        """)
    println(io, "\"\"\"")
    println(io, "\n[packages]")
    for pkg in sort!(collect(keys(stdlib_deps)), by=pkg->stdlib_uuids[pkg])
        println(io, stdlib_uuids[pkg], " = { name = ", repr(pkg), ", path = ", repr(pkg), " }")
    end
end

for (pkg, uuid) in stdlib_uuids
    url = "https://github.com/JuliaLang/julia.git"
    tree = stdlib_trees[pkg]
    deps = stdlib_deps[pkg]

    # Package.toml
    write_toml(prefix, pkg, "Package") do io
        println(io, "name = ", repr(pkg))
        println(io, "uuid = ", repr(uuid))
        println(io, "repo = ", repr(url))
    end

    # Versions.toml
    write_toml(prefix, pkg, "Versions") do io
        println(io, "[", toml_key("0.7.0-DEV+r$(tree[1:8])"), "]")
        println(io, "tree.git.sha1 = ", repr(tree))
    end

    # Deps.toml
    if isempty(deps)
        rm(joinpath(prefix, pkg, "Deps.toml"), force=true)
    else
        write_toml(prefix, pkg, "Deps") do io
            println(io, "[", toml_key("0.7"), "]")
            for dep in sort!(deps, by=lowercase)
                println(io, "$dep = ", repr(stdlib_uuids[dep]))
            end
        end
    end

    # Compat.toml
    write_toml(prefix, pkg, "Compat") do io
        println(io, "[", toml_key("0.7"), "]")
        println(io, "julia = \"0.7\"")
    end
end
=#
