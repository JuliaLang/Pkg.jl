Pkg v1.3 Release Notes
========================

New features
------------
* `Pkg.offline` can be used to toggle the new offline mode. In offline mode
Pkg tries harder to do operations without connecting to internet ([#OFFLINEPR]).

* `Pkg.test` now accept `julia_args` and `test_args` as keyword arguments
for passing Julia flags and Julia arguments (`ARGS`), respectively, to the
underlying test process ([#TESTARGSPR]).

* Package arguments in the Pkg REPL may now be separated by comma, e.g.
`pkg> add Example, JSON` now works ([#COMMAPR]).

* `Pkg.precompile()` is now available ([#PRECOMPILEPR]).

Changed functionality
---------------------
* `pkg> status` (and `Pkg.status()`) now shows the absolute status also for
projects in git repositories. To show the diff, use `pkg> status --diff`
(`Pkg.status(diff=true)`) ([#STATUSPR]).

Pkg v1.2 Release Notes
========================

New features
------------
* Experimental support for `test/Project.toml` for specifying test-dependencies ([#SANDBOXPR]).

Pkg v1.1 Release Notes
========================

New features
------------

* Pkg now implements an interface for working with registries ([#588]).
* `Pkg.status` and `pkg> status` now accept package arguments for
  filtering of the output ([#881]).

Bug fixes
----------

* The `gc` command no longer crashes when it encounters normal files
  (like `.DS_Store`) in the `packages` directory. ([#634])
* Removed incorrect documentation stating that git revisions could be used
  with `develop`. ([#639])
* Packages no longer erronously updates on non updating commands like `add` ([#642])

Deprecated or removed
---------------------


<!--- LINKS -->

[#634]: https://github.com/JuliaLang/Pkg.jl/pull/634
[#639]: https://github.com/JuliaLang/Pkg.jl/pull/639
[#642]: https://github.com/JuliaLang/Pkg.jl/pull/642
[#588]: https://github.com/JuliaLang/Pkg.jl/pull/588
[#881]: https://github.com/JuliaLang/Pkg.jl/pull/881
[#STATUSPR]: https://github.com/JuliaLang/Pkg.jl/pull/STATUSPR
[#PRECOMPILEPR]: https://github.com/JuliaLang/Pkg.jl/pull/PRECOMPILEPR
[#OFFLINEPR]: https://github.com/JuliaLang/Pkg.jl/pull/OFFLINEPR
[#TESTARGSPR]: https://github.com/JuliaLang/Pkg.jl/pull/TESTARGSPR
[#COMMAPR]: https://github.com/JuliaLang/Pkg.jl/pull/COMMAPR
[#SANDBOXPR]: https://github.com/JuliaLang/Pkg.jl/pull/SANDBOXPR
