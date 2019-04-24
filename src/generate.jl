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
