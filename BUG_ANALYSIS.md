# Bug Analysis: Missing Manifest Entry Error

## Error Message

```
`LLVM_jll=...` depends on `libLLVM_jll=...`, but no such entry exists in the manifest.
```

Also seen with: `Enzyme` → `ADTypes`

## Key Observations

- **Intermittent** - doesn't always happen
- **Fresh depots affected** - not just stale cache
- **Affects**: Julia 1.12.x, 1.13.0-alpha1, nightly
- **Cleaning depot fixes it** (for cached cases)

## Root Cause

When building `deps_map` for manifest entries, `query_deps_for_version` returns ALL deps including weak deps:

```julia
deps_for_version = Registry.query_deps_for_version(
    deps_map_compressed, weak_deps_map_compressed,  # ← includes weak deps!
    pkg.uuid, pkg.version
)
```

But weak deps that weren't triggered (no extension trigger present) are NOT in `vers`/`pkgs` because the resolver marked them as "uninstalled".

Result: `entry.deps` contains UUIDs that have no corresponding manifest entry.

## Why Existing Fix Doesn't Help

Commit `cdc17a0d7` ("allow having unknown weak dependencies") handles weak deps that are **not in any registry**. It filters them from `fixed` before resolution.

This bug is about weak deps that ARE registered but weren't resolved because the trigger wasn't needed.

## The Fix

Filter `deps_map` to only include UUIDs that are actually in `pkgs`:

```julia
pkgs_uuids = Set{UUID}(pkg.uuid for pkg in pkgs)

for uuid in deps_for_version
    uuid in pkgs_uuids || continue  # ← Skip deps not in manifest
    d[names[uuid]] = uuid
end
```

## Why Intermittent?

Unclear. Possibly related to:
- Registry caching/state
- Which package versions get selected
- Timing of when weak deps get evaluated
