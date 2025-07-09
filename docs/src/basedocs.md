```@meta
EditURL = "https://github.com/JuliaLang/Pkg.jl/blob/master/docs/src/basedocs.md"
```

# Pkg

Pkg is Julia's built-in package manager, and handles operations
such as installing, updating and removing packages.

!!! note
    What follows is a very brief introduction to Pkg. For more
    information on `Project.toml` files, `Manifest.toml` files, package
    version compatibility (`[compat]`), environments, registries, etc.,
    it is highly recommended to read the full manual, which is available here:
    [https://pkgdocs.julialang.org](https://pkgdocs.julialang.org).

```@eval
import Markdown
file = joinpath(Sys.STDLIB, "Pkg", "docs", "src", "getting-started.md")
str = read(file, String)
str = replace(str, r"^#.*$"m => "")
str = replace(str, "[API Reference](@ref)" => "[API Reference](https://pkgdocs.julialang.org/v1/api/)")
str = replace(str, "(@ref Working-with-Environments)" => "(https://pkgdocs.julialang.org/v1/environments/)")
str = replace(str, "(@ref Managing-Packages)" => "(https://pkgdocs.julialang.org/v1/managing-packages/)")
Markdown.parse(str)
```
