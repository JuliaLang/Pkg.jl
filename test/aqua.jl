using Aqua
# The persistent-tasks check loads Pkg from a wrapper environment whose manifest
# Aqua synthesizes without the `syntax` tables Pkg records, so the cache of
# Resolver (recorded with the syntax version of this julia, as it declares no
# julia compat) is rejected there and its dependencies are recompiled, which
# orphans the cache of Pkg; precompiling Pkg is disallowed during the tests.
# Skip it until Aqua carries the syntax entries over, or Resolver is bundled
# with Pkg and there is no such entry.
Aqua.test_all(Pkg; persistent_tasks = false)
