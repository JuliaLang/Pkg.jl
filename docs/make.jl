# This file is a part of Julia. License is MIT: https://julialang.org/license

using Documenter
using Pkg

include("generate.jl")

makedocs(
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
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
        # "faq.md",
        "glossary.md",
        "toml-files.md",
        "repl.md",
        "api.md"
    ],
    assets = ["assets/custom.css"],
)

deploydocs(
    repo = "github.com/JuliaLang/Pkg.jl",
    versions = ["v#.#", "dev" => "dev"],
)
