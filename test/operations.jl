module OperationsTest

import Random: randstring
import LibGit2
using Test
using Pkg3
using Pkg3.Types

import Random: randstring
import LibGit2

function temp_pkg_dir(fn::Function)
    local env_dir
    local old_load_path
    local old_depot_path
    try
        old_load_path = copy(LOAD_PATH)
        old_depot_path = copy(DEPOT_PATH)
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        mktempdir() do env_dir
            mktempdir() do depot_dir
                withenv("JULIA_ENV" => env_dir) do # TODO: use Base loading1
                    pushfirst!(LOAD_PATH, env_dir)
                    pushfirst!(DEPOT_PATH, depot_dir)
                    fn(env_dir)
                end
            end
        end
    finally
        resize!(LOAD_PATH, length(old_load_path))
        copyto!(LOAD_PATH, old_load_path)
        resize!(DEPOT_PATH, length(old_depot_path))
        copyto!(DEPOT_PATH, old_depot_path)
    end
end

const TEST_PKG = "Example"
isinstalled(name) = Base.identify_package(Main, name) !== nothing

temp_pkg_dir() do project_path
    Pkg3.init(project_path)
    Pkg3.add(TEST_PKG; preview = true)
    Pkg3.add(TEST_PKG)
    @eval import $(Symbol(TEST_PKG))
    Pkg3.up()
    Pkg3.rm(TEST_PKG; preview = true)
    @test isinstalled(TEST_PKG)
    # TODO: Check coverage kwargs
    # TODO: Check that preview = true doesn't actually execute the test
    # by creating a package with a test file that fails.

    @test_broken Pkg3.test(TEST_PKG)
    Pkg3.test(TEST_PKG; preview = true)

    Pkg3.add("Example"; use_libgit2_for_all_downloads = true)

    try
        Pkg3.add([PackageSpec(TEST_PKG, VersionSpec(v"55"))])
    catch e
        @test contains(sprint(showerror, e), TEST_PKG)
    end

    usage = Pkg3.TOML.parse(String(read(joinpath(Pkg3.logdir(), "usage.toml"))))
    @test any(x -> startswith(x, joinpath(project_path, "Manifest.toml")), keys(usage))

    nonexisting_pkg = randstring(14)
    @test_throws CommandError Pkg3.add(nonexisting_pkg)
    @test_throws CommandError Pkg3.up(nonexisting_pkg)
    # @test_warn "not in project" Pkg3.rm(nonexisting_pkg)

    Pkg3.rm(TEST_PKG)
    @test !isinstalled(TEST_PKG)
end

end # module
