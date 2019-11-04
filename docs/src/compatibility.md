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
will result in `[1.2.0, 3.0.0)`.  Note leading zeros are treated differently, e.g. `Example = "0.2, 1"` would only result in `[0.2.0-0.3.0, 1.0.0-2.0.0]`. See the next section for more information on versions with leading zeros.

### Behavior of versions with leading zeros (0.0.x and 0.x.y)

While the semver specification says that all versions with a major version of 0 (versions before 1.0.0) are incompatible
with each other, we have decided to only apply that for when both the major and minor versions are zero. In other words,
0.0.1 and 0.0.2 are considered incompatible. A pre-1.0 version with non-zero minor version (`0.a.b` with `a != 0`) is
considered compatible with versions with the same minor version and smaller or equal patch versions (`0.a.c` with `c <= b`);
i.e., the versions 0.2.2 and 0.2.3 are compatible with 0.2.1 and 0.2.0. Versions with a major version of 0 and different
minor versions are not considered compatible, so the version 0.3.0 might have breaking changes from 0.2.0. To that end, the
`[compat]` entry:

```julia
[compat]
Example = "0.0.1"
```

results in a versionbound on `Example` as `[0.0.1, 0.0.2)` (which is equivalent to only the version 0.0.1), while the
`[compat]` entry:

```julia
[compat]
Example = "0.2.1"
```

results in a versionbound on Example as `[0.2.1, 0.3.0)`.

In particular, a package may set `version = "0.2.4"` when it has feature additions compared to 0.2.3 as long as it
remains backward compatible with 0.2.0.  See also [The `version` field](@ref).

### Caret specifiers

A caret specifier allows upgrade that would be compatible according to semver.
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

### Inequality specifiers

Inequalities can also be used to specify version ranges:

```toml
[compat]
PkgA = ">= 1.2.3" # [1.2.3,  ∞)
PkgB = "≥ 1.2.3"  # [1.2.3,  ∞)
PkgC = "= 1.2.3"  # [1.2.3, 1.2.3]
PkgD = "< 1.2.3"  # [0.0.0, 1.2.2]
```
