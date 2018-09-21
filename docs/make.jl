# This file is a part of Julia. License is MIT: https://julialang.org/license

using Documenter
using Pkg

makedocs(
    modules = [Pkg],
    format = :html,
    sitename = "Pkg.jl",
    pages = Any[
        "index.md",
        "getting-started.md",
        "managing-packages.md",
        "environments.md",
        "creating-packages.md",
        "compatibility.md",
        "registries.md",
        "faq.md",
        "glossary.md",
        "api.md"
    ]
)

deploydocs(
    repo = "github.com/JuliaLang/Pkg.jl",
    target = "build",
    julia = "nightly",
    deps = nothing,
    make = nothing,
)
