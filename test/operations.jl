module OperationsTest

using ..Pkg3
using ..Test
using Pkg3.Types

function temp_pkg_dir(fn::Function)
    local project_path
    local dev_dir
    try
        # TODO: Use a temporary depot
        project_path = joinpath(tempdir(), randstring())
        dev_dir = joinpath(tempdir(), randstring())
        withenv("JULIA_ENV" => project_path, "JULIA_DEVDIR" => dev_dir) do
            fn(project_path)
        end
    finally
        rm(project_path, recursive=true, force=true)
        rm(dev_dir, recursive=true, force=true)
    end
end

isinstalled(pkg) = Pkg3._find_package(pkg) != nothing

# Tests for Example.jl fail on master,
# so let's use another small package
# in the meantime
const TEST_PKG = "Crayons"

temp_pkg_dir() do project_path
    Pkg3.init(project_path)
    Pkg3.add(TEST_PKG; preview = true)
    @test_warn "not in project" Pkg3.API.rm("Example")
    Pkg3.add(TEST_PKG)
    @eval import $(Symbol(TEST_PKG))
    Pkg3.up()
    Pkg3.rm(TEST_PKG; preview = true)
    @test isinstalled(TEST_PKG)
    # TODO: Check coverage kwargs
    # TODO: Check that preview = true doesn't actually execute the test
    # by creating a package with a test file that fails.
    Pkg3.test(TEST_PKG)
    Pkg3.test(TEST_PKG; preview = true)

    Pkg3.GLOBAL_SETTINGS.use_libgit2_for_all_downloads = true
    Pkg3.add("Example")
    Pkg3.GLOBAL_SETTINGS.use_libgit2_for_all_downloads = false

    try
        Pkg3.add([PackageSpec(TEST_PKG, VersionSpec(v"55"))])
    catch e
        @test contains(sprint(showerror, e), TEST_PKG)
    end

    usage = Pkg3.TOML.parse(String(read(joinpath(Pkg3.logdir(), "usage.toml"))))
    @test any(x -> startswith(x, joinpath(project_path, "Manifest.toml")), keys(usage))

    # Clone an unregistered packge and check that it can be imported
    Pkg3.clone("https://github.com/fredrikekre/ImportMacros.jl")
    @eval import ImportMacros
    Pkg3.test("ImportMacros")

    # Clone a registered packge and check that it can be imported
    Pkg3.clone("https://github.com/KristofferC/TimerOutputs.jl")
    @eval import TimerOutputs

    nonexisting_pkg = randstring(14)
    @test_throws CommandError Pkg3.add(nonexisting_pkg)
    @test_throws CommandError Pkg3.up(nonexisting_pkg)
    @test_warn "not in project" Pkg3.rm(nonexisting_pkg)

    mktempdir() do tmp
        LibGit2.init(tmp)
        mkdir(joinpath(tmp, "subfolder"))
        cd(joinpath(tmp, "subfolder")) do
            # Haven't initialized here so using the default env
            @test isinstalled(TEST_PKG)
            withenv("JULIA_ENV" => nothing) do
                Pkg3.init()
                @test !isinstalled(TEST_PKG)
                @test isfile(joinpath(tmp, "Project.toml"))
                Pkg3.add(TEST_PKG)
                @test isinstalled(TEST_PKG)
            end
        end
    end

    Pkg3.rm(TEST_PKG)
    # TimerOutputs depends on Crayons, which is therefore still installed
    @test isinstalled(TEST_PKG)
    # This removes also Crayons
    Pkg3.rm("TimerOutputs")
    @test !isinstalled(TEST_PKG)

end

end # module
