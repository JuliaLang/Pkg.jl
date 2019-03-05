# Pkg

Pkg is Julia's builtin package manager, and handles operations
such as installing, updating and removing packages.

!!! note
    What follows is a very brief introduction to Pkg. It is highly
    recommended to read the full manual, which is available here:
    [https://julialang.github.io/Pkg.jl/v1/](https://julialang.github.io/Pkg.jl/v1/).

```@eval
import Markdown
file = joinpath(Sys.STDLIB, "Pkg", "docs", "src", "getting-started.md")
str = read(file, String)
str = replace(str, r"^#.*$"m => "")
str = replace(str, "[API Reference](@ref)" =>
          "[API Reference](https://julialang.github.io/Pkg.jl/v1/api/)")
Markdown.parse(str)
```
