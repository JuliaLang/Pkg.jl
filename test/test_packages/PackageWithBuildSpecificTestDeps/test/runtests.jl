@show LOAD_PATH
@show pwd()
using Example
using PackageWithBuildSpecificTestDeps
using Test

@test PackageWithBuildSpecificTestDeps.f(3) == 3