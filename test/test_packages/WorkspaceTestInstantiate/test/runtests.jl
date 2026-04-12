using Test
# Example is a test-only dep (not in root Project.toml).
# Verify it was precompiled against the test project, not the parent.
@test Base.isprecompiled(Base.identify_package("Example"))
using Example
