# This file is a part of Julia. License is MIT: https://julialang.org/license

function generate(path::String; io::IO = stderr_f())
    # Handle "." to generate in current directory
    abspath_path = abspath(path)
    # Remove trailing path separator to ensure basename works correctly
    abspath_path = rstrip(abspath_path, ('/', '\\'))
    base = basename(abspath_path)
    pkg = endswith(lowercase(base), ".jl") ? chop(base, tail = 3) : base
    Base.isidentifier(pkg) || pkgerror("$(repr(pkg)) is not a valid package name")

    if isdir(abspath_path)
        # Allow generating in existing directory only if it's effectively empty for our purposes
        files = readdir(abspath_path)
        # Filter out common hidden files that are okay to have
        relevant_files = filter(f -> f != ".git" && f != ".gitignore", files)
        if !isempty(relevant_files)
            pkgerror("$(abspath_path) already exists and is not empty")
        end
    end

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
        for env in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL"]
            email = get(ENV, env, nothing)
            email !== nothing && break
        end
    end

    authors = ["$name " * (email === nothing ? "" : "<$email>")]

    uuid = UUIDs.uuid4()
    genfile(io, dir, "Project.toml") do file_io
        toml = Dict{String, Any}(
            "authors" => authors,
            "name" => pkg,
            "uuid" => string(uuid),
            "version" => "0.1.0",
        )
        TOML.print(file_io, toml, sorted = true, by = key -> (Types.project_key_order(key), key))
    end
    return uuid
end

function entrypoint(io::IO, pkg::AbstractString, dir)
    return genfile(io, joinpath(dir, "src"), "$pkg.jl") do file_io
        print(
            file_io,
            """
            module $pkg

            \"""
                hello(who::String)

            Return "Hello, `who`".
            \"""
            hello(who::String) = "Hello, \$who"

            \"""
                domath(x::Number)

            Return `x + 5`.
            \"""
            domath(x::Number) = x + 5

            end # module $pkg
            """
        )
    end
end
