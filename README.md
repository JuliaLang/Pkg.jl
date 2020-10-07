# Pkg

| **Documentation**                                                 | **Build Status**                                                                                |
|:-----------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
| [![][docs-v1-img]][docs-v1-url] [![][docs-dev-img]][docs-dev-url] | [![][travis-img]][travis-url] [![][appveyor-img]][appveyor-url] [![][codecov-img]][codecov-url] |

Development repository for Julia's package manager,
shipped with Julia v1.0 and above.

#### Using the development version of Pkg.jl

If you want to develop this package do the following steps:
- Clone the repo anywhere.
- In line 2 of the `Project.toml` file (the line that begins with `uuid = ...`), modify the UUID, e.g. change the `44c` to `54c`.
- Change the current directory to the Pkg repo you just cloned and start julia with `julia --project`.
- `import Pkg` will now load the files in the cloned repo instead of the Pkg stdlib .
- To test your changes, simply do `include("test/runtests.jl")`.

If you need to build Julia from source with a git checkout of Pkg, then instead use `make DEPS_GIT=Pkg` when building Julia. The `Pkg` repo is in `stdlib/Pkg`, and created initially with a detached `HEAD`. If you're doing this from a pre-existing Julia repository, you may need to `make clean` beforehand.

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://julialang.github.io/Pkg.jl/dev/

[docs-v1-img]: https://img.shields.io/badge/docs-v1-blue.svg
[docs-v1-url]: https://julialang.github.io/Pkg.jl/v1/

[travis-img]: https://travis-ci.com/JuliaLang/Pkg.jl.svg?branch=master
[travis-url]: https://travis-ci.com/JuliaLang/Pkg.jl

[appveyor-img]: https://ci.appveyor.com/api/projects/status/cgno2xgwapugpg4t/branch/master?svg=true
[appveyor-url]: https://ci.appveyor.com/project/JuliaLang/pkg-jl/branch/master

[codecov-img]: https://codecov.io/gh/JuliaLang/Pkg.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaLang/Pkg.jl
