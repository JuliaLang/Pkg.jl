# This file is a part of Julia. License is MIT: https://julialang.org/license

generate(path::String; kwargs...) = generate(Context(), path; kwargs...)
function generate(ctx::Context, path::String; kwargs...)
    Context!(ctx; kwargs...)
    ctx.preview && preview_info()
    dir, pkg = dirname(path), basename(path)
    Base.isidentifier(pkg) || pkgerror("$(repr(pkg)) is not a valid package name")
    isdir(path) && pkgerror("$(abspath(path)) already exists")
    printstyled("Generating"; color=:green, bold=true)
    print(" project $pkg:\n")
    uuid = project(pkg, dir; preview=ctx.preview)
    entrypoint(pkg, dir; preview=ctx.preview)
    gentestproject(pkg, dir; preview=ctx.preview)
    genruntests(pkg, dir; preview=ctx.preview)
    gendocsindex(pkg, dir; preview=ctx.preview)
    ctx.preview && preview_info()
    return Dict(pkg => uuid)
end

function genfile(f::Function, pkg::String, dir::String, file::String; preview::Bool)
    path = joinpath(dir, pkg, file)
    println(stdout, "    $path")
    preview && return
    mkpath(dirname(path))
    open(f, path, "w")
    return
end

function project(pkg::String, dir::String; preview::Bool)
    name = email = nothing
    gitname = LibGit2.getconfig("user.name", "")
    isempty(gitname) || (name = gitname)
    gitmail = LibGit2.getconfig("user.email", "")
    isempty(gitmail) || (email = gitmail)

    if name == nothing
        for env in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "USER", "USERNAME", "NAME"]
            name = get(ENV, env, nothing)
            name != nothing && break
        end
    end

    name == nothing && (name = "Unknown")

    if email == nothing
        for env in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL"];
            email = get(ENV, env, nothing)
            email != nothing && break
        end
    end

    authors = ["$name " * (email == nothing ? "" : "<$email>")]

    uuid = UUIDs.uuid4()
    genfile(pkg, dir, "Project.toml"; preview=preview) do io
        toml = Dict("authors" => authors,
                    "name" => pkg,
                    "uuid" => string(uuid),
                    "version" => "0.1.0",
                    )
        TOML.print(io, toml, sorted=true, by=key -> (Types.project_key_order(key), key))
    end
    return uuid
end

function entrypoint(pkg::String, dir; preview::Bool)
    genfile(pkg, dir, "src/$pkg.jl"; preview=preview) do io
        print(io,
           """
            module $pkg

            greet() = print("Hello World!")

            end # module
            """
        )
    end
end

function gentestproject(pkg::String, dir; preview::Bool)
    genfile(pkg, dir, "test/Project.toml"; preview=preview) do io
        toml = Dict(
            "deps" => Dict("Test" => "8dfed614-e22c-5e08-85e1-65c5234f0b40")
            )
        TOML.print(io, toml, sorted=true, by=key -> (Types.project_key_order(key), key))
    end
end

function genruntests(pkg::String, dir; preview::Bool)
    genfile(pkg, dir, "test/runtests.jl"; preview=preview) do io
        print(io,
           """
            using $pkg
            using Test

            @test 1 == 1
            """
        )
    end
end

function gendocsindex(pkg::String, dir; preview::Bool)
    genfile(pkg, dir, "docs/src/index.md"; preview=preview) do io
        print(io,
           """
            # Introduction

            Welcome to the documentation for $pkg.jl.
            """
        )
    end
end
