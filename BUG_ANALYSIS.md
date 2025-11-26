# Bug Analysis: Missing Manifest Entry Error

## Error Message
```
`LLVM_jll=...` depends on `libLLVM_jll=...`, but no such entry exists in the manifest.
```

Also seen with: `Enzyme` → `ADTypes`

## Key Observations
1. **Intermittent** - doesn't always happen
2. **Fresh depots affected** - not just stale cache
3. **Affects**: Julia 1.12.x, 1.13.0-alpha1, nightly
4. **Cleaning depot fixes it** (for cached cases)

## The Bug Mechanism

### How manifests are built:

1. `deps_graph()` builds resolver graph, populates `uuid_to_name` dict
2. `Resolve.resolve()` returns `vers::Dict{UUID, VersionNumber}`
3. For each UUID in `vers`, add to `pkgs` if not present
4. For each pkg in `pkgs`, query deps from registry → `deps_map[uuid]`
5. `update_manifest!` sets `entry.deps = deps_map[uuid]`
6. `prune_manifest()` keeps only reachable packages

### The Problem

**Step 4 queries ALL deps (including weak deps) from registry data:**
```julia
deps_for_version = Registry.query_deps_for_version(
    deps_map_compressed, weak_deps_map_compressed,  # ← BOTH!
    pkg.uuid, pkg.version
)
```

This can include UUIDs that are NOT in `pkgs` because:
- They're weak deps that weren't resolved (solver chose "uninstalled")
- They're stdlibs handled specially

### Why Ordering Matters (Your Insight)

The iteration over `vers` (a Dict) at line 842-851 is **non-deterministic**:

```julia
for (uuid, ver) in vers  # Dict iteration order varies!
    ...
    push!(pkgs, PackageSpec(...))
end
```

Then at lines 854-880, for each `pkg in pkgs`:
```julia
for uuid in deps_for_version
    d[names[uuid]] = uuid  # Requires uuid to be in names!
end
```

If the `names` dict wasn't fully populated due to ordering, or if a dependency UUID exists in `deps_for_version` but the package itself wasn't added to `pkgs` (and thus won't be in manifest), we get a corrupt manifest.

## Root Cause Hypothesis

**The `is_stdlib` check at line 849 uses current Julia's stdlibs, not `julia_version`:**

```julia
name = is_stdlib(uuid) ? stdlib_infos()[uuid].name : registered_name(registries, uuid)
```

But `deps_graph` uses `stdlibs_for_julia_version` which could differ!

This inconsistency, combined with non-deterministic Dict iteration, could cause:
1. A stdlib to be in the resolver graph (treated as stdlib for `julia_version`)
2. But NOT recognized as stdlib when building `pkgs` (using `VERSION`)
3. Leading to it being in a package's `deps` but not in the manifest

## Relevant Commits

- `cdc17a0d7` "allow having unknown weak dependencies" - filters unavailable weak deps during resolution, but doesn't help with manifest reading
- `efe1eaf7a` "stop uncompressing registry data" - only on master

## Potential Fix

Line 849 should use `is_stdlib(uuid, julia_version)` instead of `is_stdlib(uuid)`:

```julia
# Current (buggy):
name = is_stdlib(uuid) ? stdlib_infos()[uuid].name : registered_name(registries, uuid)

# Fixed:
name = is_stdlib(uuid, julia_version) ?
    get_last_stdlibs(julia_version)[uuid].name :
    registered_name(registries, uuid)
```

Additionally, `deps_map` should only include deps that are actually in `pkgs`/`vers`, not all deps from registry.

## To Verify

1. Check if `julia_version != VERSION` in failing cases
2. Add logging to see if stdlib detection differs between resolver and pkgs-building
3. Check if the missing package (libLLVM_jll, ADTypes) is a stdlib for one version but not another
