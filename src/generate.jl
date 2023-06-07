# This file is a part of Julia. License is MIT: https://julialang.org/license

function generate(path::String; io::IO=stderr_f())
    base = basename(path)
    pkg = endswith(lowercase(base), ".jl") ? chop(base, tail=3) : base
    Base.isidentifier(pkg) || pkgerror("$(repr(pkg)) is not a valid package name")
    isdir(path) && pkgerror("$(abspath(path)) already exists")
    printpkgstyle(io, :Generating, " project $pkg:")
    uuid = project(io, pkg, path)
    entrypoint(io, pkg, path)
    return Dict(pkg => uuid)
end

function genfile(f::Function, io::IO, dir::AbstractString, file::AbstractString)
    path = joinpath(dir, file)
    println(io, "    $(Base.contractuser(path))")
    mkpath(dirname(path))
    open(f, path, "w")
    return
end

function project(io::IO, pkg::AbstractString, dir::AbstractString)
    mkpath(dir)

    name = email = nothing
    gitname = LibGit2.getconfig("user.name", "")
    isempty(gitname) || (name = gitname)
    gitmail = LibGit2.getconfig("user.email", "")
    isempty(gitmail) || (email = gitmail)

    if name === nothing
        for env in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "USER", "USERNAME", "NAME"]
            name = get(ENV, env, nothing)
            name !== nothing && break
        end
    end

    name === nothing && (name = "Unknown")

    if email === nothing
        for env in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL"];
            email = get(ENV, env, nothing)
            email !== nothing && break
        end
    end

    authors = ["$name " * (email === nothing ? "" : "<$email>")]

    uuid = UUIDs.uuid4()
    genfile(io, dir, "Project.toml") do file_io
        toml = Dict{String,Any}("authors" => authors,
                                "name" => pkg,
                                "uuid" => string(uuid),
                                "version" => "0.1.0",
                                )
        TOML.print(file_io, toml, sorted=true, by=key -> (Types.project_key_order(key), key))
    end
    return uuid
end

function entrypoint(io::IO, pkg::AbstractString, dir)
    genfile(io, joinpath(dir, "src"), "$pkg.jl") do file_io
        print(file_io,
           """
            module $pkg

            greet() = print("Hello World!")

            end # module $pkg
            """
        )
    end
end
