# Pkg

Development repository for Julia's package manager,
shipped with Julia v1.0 and above.

| **Documentation**                                                 | **Build Status**                                                                                |
|:-----------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
| [![][docs-v1-img]][docs-v1-url] [![][docs-dev-img]][docs-dev-url] | [![][ci-img]][ci-url] [![][codecov-img]][codecov-url] |

## Using the development version of Pkg.jl

If you want to develop this package do the following steps:
- Make a fork and then clone the repo locally on your computer
- In line 2 of the `Project.toml` file (the line that begins with `uuid = ...`), modify the UUID, e.g. change the `44cf...` to `54cf...`.
- Change the current directory to the Pkg repo you just cloned and start julia with `julia --project`.
- `import Pkg` will now load the files in the cloned repo instead of the Pkg stdlib .
- To test your changes, simply do `include("test/runtests.jl")`.
- Before you commit and push your changes, remember to change the UUID in the `Project.toml` file back to the original UUID

If you need to build Julia from source with a Git checkout of Pkg, then instead use `make DEPS_GIT=Pkg` when building Julia. The `Pkg` repo is in `stdlib/Pkg`, and created initially with a detached `HEAD`. If you're doing this from a pre-existing Julia repository, you may need to `make clean` beforehand.

If you need to build Julia from source with Git checkouts of two or more stdlibs, please see the instructions in the [`Building Julia from source with a Git checkout of a stdlib`](https://github.com/JuliaLang/julia/blob/master/doc/src/devdocs/build/build.md#building-julia-from-source-with-a-git-checkout-of-a-stdlib) section of the [`doc/src/devdocs/build/build.md`](https://github.com/JuliaLang/julia/blob/master/doc/src/devdocs/build/build.md) file within the Julia devdocs.

## Synchronization with the Julia repo

To check which commit julia master uses see [JuliaLang/julia/stdlib/Pkg.version](https://github.com/JuliaLang/julia/blob/master/stdlib/Pkg.version).

To open a PR to update this to the latest commit the [JuliaPackaging/BumpStdlibs.jl](https://github.com/JuliaPackaging/BumpStdlibs.jl) github actions bot is recommended.

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://pkgdocs.julialang.org/dev/

[docs-v1-img]: https://img.shields.io/badge/docs-v1-blue.svg
[docs-v1-url]: https://pkgdocs.julialang.org/v1/

[ci-img]: https://github.com/JuliaLang/Pkg.jl/workflows/Run%20tests/badge.svg?branch=master
[ci-url]: https://github.com/JuliaLang/Pkg.jl/actions?query=workflow%3A%22Run+tests%22

[codecov-img]: https://codecov.io/gh/JuliaLang/Pkg.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaLang/Pkg.jl
