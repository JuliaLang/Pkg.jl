# This file is a part of Julia. License is MIT: https://julialang.org/license

generate(path::String; kwargs...) = generate(Context(), path; kwargs...)
function generate(ctx::Context, path::String; kwargs...)
    Context!(ctx; kwargs...)
    dir, pkg = dirname(path), basename(path)
    Base.isidentifier(pkg) || pkgerror("$(repr(pkg)) is not a valid package name")
    isdir(path) && pkgerror("$(abspath(path)) already exists")
    printpkgstyle(ctx, :Generating, " project $pkg:")
    uuid = project(ctx, pkg, dir)
    entrypoint(ctx, pkg, dir)
    return Dict(pkg => uuid)
end

function project(ctx::Context, pkg::String, dir::String)
    name = _gitconfig("user.name")
    name == nothing && (name = _envfirst(
        ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "USER", "USERNAME", "NAME"]))
    name == nothing && (name = "Unknown")

    email = _gitconfig("user.email")
    email == nothing && (email = _envfirst(
        ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL", "EMAIL"]))

    authors = [email===nothing ? name : "$name <$email>"]

    uuid = UUIDs.uuid4()

    file(ctx, pkg, dir, "Project.toml") do io
        toml = Dict("authors" => authors,
                    "name" => pkg,
                    "uuid" => string(uuid),
                    "version" => "0.1.0",
                    )
        TOML.print(io, toml, sorted=true, by=key -> (Types.project_key_order(key), key))
    end
    return uuid
end

function entrypoint(ctx::Context, pkg::String, dir)
    file(ctx, pkg, dir, joinpath("src", "$pkg.jl")) do io
        print(io,
           """
            module $pkg

            greet() = print("Hello World!")

            end # module
            """
        )
    end
end

function file(f::Function, ctx::Context, pkg::String, dir::String, file::String)
    path = joinpath(dir, pkg, file)
    println(ctx.io, "    $path")
    mkpath(dirname(path))
    open(f, path, "w")
    return
end


function _gitconfig(k)
    v = LibGit2.getconfig(k, "")
    isempty(v) ? nothing : v
end

function _envfirst(ks)
    v = nothing
    for k in ks
        v = get(ENV, k, nothing)
        v != nothing && break
    end
    v
end
