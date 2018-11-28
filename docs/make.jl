# This file is a part of Julia. License is MIT: https://julialang.org/license

using Documenter
using Pkg

makedocs(
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
        "api.md"
    ],
    versions = ["v#.#", "dev" => "dev"]
)

deploydocs(
    repo = "github.com/JuliaLang/Pkg.jl",
)
