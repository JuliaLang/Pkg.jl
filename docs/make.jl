# This file is a part of Julia. License is MIT: https://julialang.org/license

using Documenter, DocumenterLaTeX
using Pkg

include("generate.jl")

const formats = Any[
    Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://julialang.github.io/Pkg.jl/v1/",
        assets = ["assets/custom.css"],
    ),
]
if "pdf" in ARGS
    push!(formats, LaTeX(platform = "docker"))
end

makedocs(
    format = formats,
    modules = [Pkg],
    sitename = "Pkg.jl",
    pages = Any[
        "index.md",
        "getting-started.md",
        "managing-packages.md",
        "environments.md",
        "creating-packages.md",
        "compatibility.md",
        "registries.md",
        "artifacts.md",
        # "faq.md",
        "glossary.md",
        "toml-files.md",
        "repl.md",
        "api.md",
    ],
)

mktempdir() do tmp
    # Hide the PDF from html-deploydocs
    build = joinpath(@__DIR__, "build")
    files = readdir(build)
    idx = findfirst(f -> startswith(f, "Pkg.jl") && endswith(f, ".pdf"), files)
    pdf = idx === nothing ? nothing : joinpath(build, files[idx])
    if pdf !== nothing
        pdf = mv(pdf, joinpath(tmp, basename(pdf)))
    end
    # Deploy HTML pages
    @info "Deploying HTML pages"
    deploydocs(
        repo = "github.com/JuliaLang/Pkg.jl",
        versions = ["v#.#", "dev" => "dev"],
    )
    # Put back PDF into docs/build/pdf
    mkpath(joinpath(build, "pdf"))
    if pdf !== nothing
        pdf = mv(pdf, joinpath(build, "pdf", basename(pdf)))
    end
    # Deploy PDF
    @info "Deploying PDF"
    deploydocs(
        repo = "github.com/JuliaLang/Pkg.jl",
        target = "build/pdf",
        branch = "gh-pages-pdf",
        forcepush = true,
    )
end
