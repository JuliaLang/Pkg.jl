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
will result in `[1.2.0, 3.0.0)`.

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

While the semver specification says that all versions with a major version of 0 are incompatible with each other, we have made that choice that
a version given as `0.a.b` is considered compatible with `0.a.c` if `a != 0` and  `c >= b`.

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
```

### Inequality specifiers

Inequalities can also be used to specify version ranges:

```toml
[compat]
PkgA = ">= 1.2.3" # [1.2.3,  ∞)
PkgB = "≥ 1.2.3"  # [1.2.3,  ∞)
PkgC = "= 1.2.3"  # [1.2.3, 1.2.3]
PkgD = "< 1.2.3"  # [0.0.0, 1.2.2]
```
