# Pkg test

Development repository for Julia's package manager,
shipped with Julia v1.0 and above.

| **Documentation**                                                 | **Build Status**                                                                                |
|:-----------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
| [![][docs-v1-img]][docs-v1-url] [![][docs-dev-img]][docs-dev-url] | [![][ci-img]][ci-url] [![][codecov-img]][codecov-url] |

## Using the development version of Pkg.jl

If you want to develop this package do the following steps:
- Make a fork and then clone the repo locally on your computer
- Change the current directory to the Pkg repo you just cloned and start julia with `julia --project`.
- `import Pkg` will now load the files in the cloned repo instead of the Pkg stdlib.
- To test your changes, simply do `Pkg.test()`.

If you need to build Julia from source with a Git checkout of Pkg, then instead use `make DEPS_GIT=Pkg` when building Julia. The `Pkg` repo is in `stdlib/Pkg`, and created initially with a detached `HEAD`. If you're doing this from a pre-existing Julia repository, you may need to `make clean` beforehand.

If you need to build Julia from source with Git checkouts of two or more stdlibs, please see the instructions in the [`Building Julia from source with a Git checkout of a stdlib`](https://github.com/JuliaLang/julia/blob/master/doc/src/devdocs/build/build.md#building-julia-from-source-with-a-git-checkout-of-a-stdlib) section of the [`doc/src/devdocs/build/build.md`](https://github.com/JuliaLang/julia/blob/master/doc/src/devdocs/build/build.md) file within the Julia devdocs.

## Pre-commit hooks

This repository uses pre-commit hooks to automatically check and format code before commits. The hooks perform various checks including:

- File size and case conflict validation
- YAML syntax checking
- Trailing whitespace removal and line ending fixes
- Julia code formatting with Runic

To install and use the pre-commit hooks:

1. Install pre-commit: `pip install pre-commit` (or use your system's package manager)
2. Install the hooks: `pre-commit install` from the root of the repository
3. Run on all files: `pre-commit run --all-files` from the root of the repository

Once installed, the hooks will run automatically on each commit. You can also run them manually anytime with `pre-commit run`.

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
