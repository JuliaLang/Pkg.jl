# [**6.** Compatibility](@id Compatibility)

Compatibility refers to the ability to restrict the versions of the dependencies that your project is compatible with.
If the compatibility for a dependency is not given, the project is assumed to be compatible with all versions of that dependency.

Compatibility for a dependency is entered in the `Project.toml` file as for example:

```toml
[compat]
julia = "1.0"
Example = "0.4.3"
```

After a compatibility entry is put into the project file, `up` can be used to apply it.

The format of the version specifier is described in detail below.

!!! info
    There is currently no way to give compatibility from the Pkg REPL mode so for now, one has to manually edit the project file.

## Version specifier format

Similar to other package managers, the Julia package manager respects [semantic versioning](https://semver.org/) (semver).
As an example, a version specifier given as e.g. `1.2.3` is therefore assumed to be compatible with the versions `[1.2.3 - 2.0.0)` where `)` is a non-inclusive upper bound.
More specifically, a version specifier is either given as a **caret specifier**, e.g. `^1.2.3`  or as a **tilde specifier**, e.g. `~1.2.3`.
Caret specifiers are the default and hence `1.2.3 == ^1.2.3`. The difference between a caret and tilde is described in the next section.
The union of multiple version specifiers can be formed by comma separating individual version specifiers, e.g.
```toml
[compat]
Example = "1.2, 2"
```
will result in `[1.2.0, 3.0.0)`.  Note leading zeros are treated differently, e.g. `Example = "0.2, 1"` would only result in `[0.2.0 - 0.3.0) ∪ [1.0.0 - 2.0.0)`. See the next section for more information on versions with leading zeros.

### [Behavior of versions with leading zeros (0.0.x and 0.x.y)](@id compat-pre-1.0)

While the semver specification says that all versions with a major version of 0 (versions before 1.0.0) are incompatible
with each other, we have decided to only apply that for when both the major and minor versions are zero. In other words,
0.0.1 and 0.0.2 are considered incompatible. A pre-1.0 version with non-zero minor version (`0.a.b` with `a != 0`) is
considered compatible with versions with the same minor version and smaller or equal patch versions (`0.a.c` with `c <= b`);
i.e., the versions 0.2.2 and 0.2.3 are compatible with 0.2.1 and 0.2.0. Versions with a major version of 0 and different
minor versions are not considered compatible, so the version 0.3.0 might have breaking changes from 0.2.0. To that end, the
`[compat]` entry:

```toml
[compat]
Example = "0.0.1"
```

results in a versionbound on `Example` as `[0.0.1, 0.0.2)` (which is equivalent to only the version 0.0.1), while the
`[compat]` entry:

```toml
[compat]
Example = "0.2.1"
```

results in a versionbound on Example as `[0.2.1, 0.3.0)`.

In particular, a package may set `version = "0.2.4"` when it has feature additions compared to 0.2.3 as long as it
remains backward compatible with 0.2.0.  See also [The `version` field](@ref).

### Caret specifiers

A caret (`^`) specifier allows upgrade that would be compatible according to semver. This is the default behavior if no specifier is used.
An updated dependency is considered compatible if the new version does not modify the left-most non zero digit in the version specifier.

Some examples are shown below.

```toml
[compat]
PkgA = "^1.2.3" # [1.2.3, 2.0.0)
PkgB = "^1.2"   # [1.2.0, 2.0.0)
PkgC = "^1"     # [1.0.0, 2.0.0)
PkgD = "^0.2.3" # [0.2.3, 0.3.0)
PkgE = "^0.0.3" # [0.0.3, 0.0.4)
PkgF = "^0.0"   # [0.0.0, 0.1.0)
PkgG = "^0"     # [0.0.0, 1.0.0)
```

### Tilde specifiers

A tilde specifier provides more limited upgrade possibilities. When specifying major, minor
and patch versions, or when specifying major and minor versions, only the patch version is
allowed to change. If you only specify a major version, then both minor and patch versions
are allowed to be upgraded (`~1` is thus equivalent to `^1`).
For example:

```toml
[compat]
PkgA = "~1.2.3" # [1.2.3, 1.3.0)
PkgB = "~1.2"   # [1.2.0, 1.3.0)
PkgC = "~1"     # [1.0.0, 2.0.0)
PkgD = "~0.2.3" # [0.2.3, 0.3.0)
PkgE = "~0.0.3" # [0.0.3, 0.0.4)
PkgF = "~0.0"   # [0.0.0, 0.1.0)
PkgG = "~0"     # [0.0.0, 1.0.0)
```

For all versions with a major version of 0 the tilde and caret specifiers are equivalent.

### Equality specifier

Equality can be used to specify exact versions:

```toml
[compat]
PkgA = "=1.2.3"           # [1.2.3, 1.2.3]
PkgA = "=0.10.1, =0.10.3" # 0.10.1 or 0.10.3
```

### Inequality specifiers

Inequalities can also be used to specify version ranges:

```toml
[compat]
PkgB = ">= 1.2.3" # [1.2.3,  ∞)
PkgC = "≥ 1.2.3"  # [1.2.3,  ∞)
PkgD = "< 1.2.3"  # [0.0.0, 1.2.3) = [0.0.0, 1.2.2]
```

### Hyphen specifiers

Hyphen syntax can also be used to specify version ranges. Make sure that you have a space on both sides of the hyphen.

```toml
[compat]
PkgA = "1.2.3 - 4.5.6" # [1.2.3, 4.5.6]
PkgA = "0.2.3 - 4.5.6" # [0.2.3, 4.5.6]
```

Any unspecified trailing numbers in the first end-point are considered to be zero:

```toml
[compat]
PkgA = "1.2 - 4.5.6"   # [1.2.0, 4.5.6]
PkgA = "1 - 4.5.6"     # [1.0.0, 4.5.6]
PkgA = "0.2 - 4.5.6"   # [0.2.0, 4.5.6]
PkgA = "0.2 - 0.5.6"   # [0.2.0, 0.5.6]
```

Any unspecified trailing numbers in the second end-point will be considered to be wildcards:

```toml
[compat]
PkgA = "1.2.3 - 4.5"   # 1.2.3 - 4.5.* = [1.2.3, 4.6.0)
PkgA = "1.2.3 - 4"     # 1.2.3 - 4.*.* = [1.2.3, 5.0.0)
PkgA = "1.2 - 4.5"     # 1.2.0 - 4.5.* = [1.2.0, 4.6.0)
PkgA = "1.2 - 4"       # 1.2.0 - 4.*.* = [1.2.0, 5.0.0)
PkgA = "1 - 4.5"       # 1.0.0 - 4.5.* = [1.0.0, 4.6.0)
PkgA = "1 - 4"         # 1.0.0 - 4.*.* = [1.0.0, 5.0.0)
PkgA = "0.2.3 - 4.5"   # 0.2.3 - 4.5.* = [0.2.3, 4.6.0)
PkgA = "0.2.3 - 4"     # 0.2.3 - 4.*.* = [0.2.3, 5.0.0)
PkgA = "0.2 - 4.5"     # 0.2.0 - 4.5.* = [0.2.0, 4.6.0)
PkgA = "0.2 - 4"       # 0.2.0 - 4.*.* = [0.2.0, 5.0.0)
PkgA = "0.2 - 0.5"     # 0.2.0 - 0.5.* = [0.2.0, 0.6.0)
PkgA = "0.2 - 0"       # 0.2.0 - 0.*.* = [0.2.0, 1.0.0)
```

!!! compat "Julia 1.4"
    Hyphen specifiers requires at least Julia 1.4, so it is strongly recomended to also add
    ```toml
    [compat]
    julia = "1.4"
    ```
    to the project file when using them.

## Fixing conflicts

Version conflicts were introduced previously with an [example](@ref conflicts)
of a conflict arising in a package `D` used by two other packages, `B` and `C`.
Our analysis of the error message revealed that `B` is using an outdated
version of `D`.
To fix it, the first thing to try is to `pkg> dev B` so that
you can modify `B` and its compatibility requirements.
If you open its `Project.toml` file in an editor, you would probably notice something like

```toml
[compat]
D = "0.1"
```

Usually the first step is to modify this to something like
```toml
[compat]
D = "0.1, 0.2"
```

This indicates that `B` is compatible with both versions 0.1 and version 0.2; if you `pkg> up`
this would fix the package error.
However, there is one major concern you need to address first: perhaps there was an incompatible change
in `v0.2` of `D` that breaks `B`.
Before proceeding further, you should update all packages and then run `B`'s tests, scanning the
output of `pkg> test B` to be sure that `v0.2` of `D` is in fact being used.
(It is possible that an additional dependency of `D` pins it to `v0.1`, and you wouldn't want to be misled into thinking that you had tested `B` on the newer version.)
If the new version was used and the tests still pass,
you can assume that `B` didn't need any further updating to accomodate `v0.2` of `D`;
you can safely submit this change as a pull request to `B` so that a new release is made.
If instead an error is thrown, it indicates that `B` requires more extensive updates to be
compatible with the latest version of `D`; those updates will need to be completed before
it becomes possible to use both `A` and `B` simultaneously.
You can, though, continue to use them independently of one another.
