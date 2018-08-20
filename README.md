# Pkg

[![Build Status](https://travis-ci.org/JuliaLang/Pkg.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/Pkg.jl) [![Build status](https://ci.appveyor.com/api/projects/status/7q884kyh6f733uyk/branch/master?svg=true)](https://ci.appveyor.com/project/KristofferC/pkg-jl/branch/master) [![](https://img.shields.io/badge/docs-latest-blue.svg)](https://julialang.github.io/Pkg.jl/latest/) [![codecov](https://codecov.io/gh/JuliaLang/Pkg.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaLang/Pkg.jl)

Next-generation package manager for Julia.

Pkg is available from the Julia nightly build or by building the Julia master branch.


#### Using the development version of Pkg.jl

If you want to develop this package do the following steps:
- Clone the repo anywhere.
- Remove the `uuid = ` line from the `Project.toml` file.
- Change the current directory to the Pkg repo you just cloned and start julia with `julia --project`.
- `import Pkg` will now load the files in the cloned repo instead of the Pkg stdlib .
- To test your changes, simple `include("test/runtests.jl")`.
