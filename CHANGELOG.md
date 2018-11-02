Pkg v1.1.0 Release Notes
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
