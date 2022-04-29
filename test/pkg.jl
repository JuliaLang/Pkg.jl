# This file is a part of Julia. License is MIT: https://julialang.org/license

module OperationsTest
import ..Pkg # ensure we are using the correct Pkg

import Random: randstring
import LibGit2
using Test
using UUIDs
using Dates
using TOML

using Pkg
using Pkg.Types

import Random: randstring
import LibGit2

using ..Utils

const TEST_PKG = (name = "Example", uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
const PackageSpec = Pkg.Types.PackageSpec

import Pkg.Types: semver_spec, VersionSpec
@testset "semver notation" begin
    @test semver_spec("^1.2.3") == VersionSpec("1.2.3-1")
    @test semver_spec("^1.2")   == VersionSpec("1.2.0-1")
    @test semver_spec("^1")     == VersionSpec("1.0.0-1")
    @test semver_spec("^0.2.3") == VersionSpec("0.2.3-0.2")
    @test semver_spec("^0.0.3") == VersionSpec("0.0.3-0.0.3")
    @test semver_spec("^0.0")   == VersionSpec("0.0.0-0.0")
    @test semver_spec("^0")     == VersionSpec("0.0.0-0")
    @test semver_spec("~1.2.3") == VersionSpec("1.2.3-1.2")
    @test semver_spec("~1.2")   == VersionSpec("1.2.0-1.2")
    @test semver_spec("~1")     == VersionSpec("1.0.0-1")
    @test semver_spec("1.2.3")  == semver_spec("^1.2.3")
    @test semver_spec("1.2")    == semver_spec("^1.2")
    @test semver_spec("1")      == semver_spec("^1")
    @test semver_spec("0.0.3")  == semver_spec("^0.0.3")
    @test semver_spec("0")      == semver_spec("^0")

    @test semver_spec("0.0.3, 1.2") == VersionSpec(["0.0.3-0.0.3", "1.2.0-1"])
    @test semver_spec("~1.2.3, ~v1") == VersionSpec(["1.2.3-1.2", "1.0.0-1"])

    @test   v"1.5.2"  in semver_spec("1.2.3")
    @test   v"1.2.3"  in semver_spec("1.2.3")
    @test !(v"2.0.0"  in semver_spec("1.2.3"))
    @test !(v"1.2.2"  in semver_spec("1.2.3"))
    @test   v"1.2.99" in semver_spec("~1.2.3")
    @test   v"1.2.3"  in semver_spec("~1.2.3")
    @test !(v"1.3"    in semver_spec("~1.2.3"))
    @test  v"1.2.0"   in semver_spec("1.2")
    @test  v"1.9.9"   in semver_spec("1.2")
    @test !(v"2.0.0"  in semver_spec("1.2"))
    @test !(v"1.1.9"  in semver_spec("1.2"))
    @test   v"0.2.3"  in semver_spec("0.2.3")
    @test !(v"0.3.0"  in semver_spec("0.2.3"))
    @test !(v"0.2.2"  in semver_spec("0.2.3"))
    @test   v"0.0.0"  in semver_spec("0")
    @test  v"0.99.0"  in semver_spec("0")
    @test !(v"1.0.0"  in semver_spec("0"))
    @test  v"0.0.0"   in semver_spec("0.0")
    @test  v"0.0.99"  in semver_spec("0.0")
    @test !(v"0.1.0"  in semver_spec("0.0"))

    @test semver_spec("<1.2.3") == VersionSpec("0.0.0 - 1.2.2")
    @test semver_spec("<1.2") == VersionSpec("0.0.0 - 1.1")
    @test semver_spec("<1") == VersionSpec("0.0.0 - 0")
    @test semver_spec("<2") == VersionSpec("0.0.0 - 1")
    @test semver_spec("<0.2.3") == VersionSpec("0.0.0 - 0.2.2")
    @test semver_spec("<2.0.3") == VersionSpec("0.0.0 - 2.0.2")
    @test   v"0.2.3" in semver_spec("<0.2.4")
    @test !(v"0.2.4" in semver_spec("<0.2.4"))

    @test semver_spec("=1.2.3") == VersionSpec("1.2.3")
    @test semver_spec("=1.2") == VersionSpec("1.2.0")
    @test semver_spec("  =1") == VersionSpec("1.0.0")
    @test   v"1.2.3" in semver_spec("=1.2.3")
    @test !(v"1.2.4" in semver_spec("=1.2.3"))
    @test !(v"1.2.2" in semver_spec("=1.2.3"))

    @test semver_spec("≥1.3.0") == semver_spec(">=1.3.0")

    @test semver_spec(">=   1.2.3") == VersionSpec("1.2.3-*")
    @test semver_spec(">=1.2  ") == VersionSpec("1.2.0-*")
    @test semver_spec("  >=  1") == VersionSpec("1.0.0-*")
    @test   v"1.0.0" in semver_spec(">=1")
    @test   v"0.0.1" in semver_spec(">=0")
    @test   v"1.2.3" in semver_spec(">=1.2.3")
    @test !(v"1.2.2" in semver_spec(">=1.2.3"))

    @test_throws ErrorException semver_spec("0.1.0-0.2.2")
    @test semver_spec("0.1.0 - 0.2.2") == VersionSpec("0.1.0 - 0.2.2")
    @test semver_spec("1.2.3 - 4.5.6") == semver_spec("1.2.3  - 4.5.6") == semver_spec("1.2.3 -  4.5.6") == semver_spec("1.2.3  -  4.5.6")
    @test semver_spec("0.0.1 - 0.0.2") == VersionSpec("0.0.1 - 0.0.2")
    @test semver_spec("0.0.1 - 0.1.0") == VersionSpec("0.0.1 - 0.1.0")
    @test semver_spec("0.0.1 - 0.1") == VersionSpec("0.0.1 - 0.1")
    @test semver_spec("0.0.1 - 1") == VersionSpec("0.0.1 - 1")
    @test semver_spec("0.1 - 0.2") == VersionSpec("0.1 - 0.2")
    @test semver_spec("0.1.0 - 0.2") == VersionSpec("0.1.0 - 0.2")
    @test semver_spec("0.1 - 0.2.0") == VersionSpec("0.1 - 0.2.0")
    @test semver_spec("0.1.0 - 0.2.0") == VersionSpec("0.1.0 - 0.2.0")
    @test semver_spec("0.1.1 - 0.2") == VersionSpec("0.1.1 - 0.2")
    @test semver_spec("0.1 - 0.2.1") == VersionSpec("0.1 - 0.2.1")
    @test semver_spec("0.1.1 - 0.2.1") == VersionSpec("0.1.1 - 0.2.1")
    @test semver_spec("1 - 2") == VersionSpec("1 - 2")
    @test semver_spec("1.0 - 2") == VersionSpec("1.0 - 2")
    @test semver_spec("1 - 2.0") == VersionSpec("1 - 2.0")
    @test semver_spec("1.0 - 2.0") == VersionSpec("1.0 - 2.0")
    @test semver_spec("1.0.0 - 2.0") == VersionSpec("1.0.0 - 2.0")
    @test semver_spec("1.0 - 2.0.0") == VersionSpec("1.0 - 2.0.0")
    @test semver_spec("1.0.0 - 2.0.0") == VersionSpec("1.0.0 - 2.0.0")
    @test semver_spec("1.0.1 - 2") == VersionSpec("1.0.1 - 2")
    @test semver_spec("1.0.1 - 2.0") == VersionSpec("1.0.1 - 2.0")
    @test semver_spec("1.0.1 - 2.0.0") == VersionSpec("1.0.1 - 2.0.0")
    @test semver_spec("1.0.1 - 2.0.1") == VersionSpec("1.0.1 - 2.0.1")
    @test semver_spec("1.0.1 - 2.1.0") == VersionSpec("1.0.1 - 2.1.0")
    @test semver_spec("1.0.1 - 2.1.1") == VersionSpec("1.0.1 - 2.1.1")
    @test semver_spec("1.1 - 2") == VersionSpec("1.1 - 2")
    @test semver_spec("1.1 - 2.0") == VersionSpec("1.1 - 2.0")
    @test semver_spec("1.1 - 2.0.0") == VersionSpec("1.1 - 2.0.0")
    @test semver_spec("1.1 - 2.0.1") == VersionSpec("1.1 - 2.0.1")
    @test semver_spec("1.1 - 2.1.0") == VersionSpec("1.1 - 2.1.0")
    @test semver_spec("1.1 - 2.1.1") == VersionSpec("1.1 - 2.1.1")
    @test semver_spec("1.1.0 - 2") == VersionSpec("1.1.0 - 2")
    @test semver_spec("1.1.0 - 2.0") == VersionSpec("1.1.0 - 2.0")
    @test semver_spec("1.1.0 - 2.0.0") == VersionSpec("1.1.0 - 2.0.0")
    @test semver_spec("1.1.0 - 2.0.1") == VersionSpec("1.1.0 - 2.0.1")
    @test semver_spec("1.1.0 - 2.1.0") == VersionSpec("1.1.0 - 2.1.0")
    @test semver_spec("1.1.0 - 2.1.1") == VersionSpec("1.1.0 - 2.1.1")
    @test semver_spec("1.1.1 - 2") == VersionSpec("1.1.1 - 2")
    @test semver_spec("1.1.1 - 2.0") == VersionSpec("1.1.1 - 2.0")
    @test semver_spec("1.1.1 - 2.0.0") == VersionSpec("1.1.1 - 2.0.0")
    @test semver_spec("1.1.1 - 2.0.1") == VersionSpec("1.1.1 - 2.0.1")
    @test semver_spec("1.1.1 - 2.1.0") == VersionSpec("1.1.1 - 2.1.0")
    @test semver_spec("1.1.1 - 2.1.1") == VersionSpec("1.1.1 - 2.1.1")

    @test semver_spec("0.1.0 - 0.2.2, 1.2") == VersionSpec(["0.1.0 - 0.2.2", "1.2.0-1"])
    @test semver_spec("0.1.0 - 0.2.2, >=1.2") == VersionSpec(["0.1.0 - 0.2.2", "1.2.0-*"])
    @test !(v"0.3" in semver_spec("0.1 - 0.2"))
    @test v"0.2.99" in semver_spec("0.1 - 0.2")
    @test v"0.3" in semver_spec("0.1 - 0")

    @test_throws ErrorException semver_spec("^^0.2.3")
    @test_throws ErrorException semver_spec("^^0.2.3.4")
    @test_throws ErrorException semver_spec("0.0.0")
    @test_throws ErrorException semver_spec("0.7 1.0")

    @test Pkg.Types.isjoinable(Pkg.Types.VersionBound((1,5)), Pkg.Types.VersionBound((1,6)))
    @test !(Pkg.Types.isjoinable(Pkg.Types.VersionBound((1,5)), Pkg.Types.VersionBound((1,6,0))))
end

# TODO: Should rewrite these tests not to rely on internals like field names
@testset "union, isjoinable" begin
    @test sprint(print, VersionRange("0-0.3.2")) == "0-0.3.2"
    # test missing paths on union! and isjoinable
    # there's no == for VersionBound or VersionRange
    unified_vr = union!([VersionRange("1.5-2.8"), VersionRange("2.5-3")])[1]
    @test unified_vr.lower.t == (UInt32(1), UInt32(5), UInt32(0))
    @test unified_vr.upper.t == (UInt32(3), UInt32(0), UInt32(0))
    unified_vr = union!([VersionRange("2.5-3"), VersionRange("1.5-2.8")])[1]
    @test unified_vr.lower.t == (UInt32(1), UInt32(5), UInt32(0))
    @test unified_vr.upper.t == (UInt32(3), UInt32(0), UInt32(0))
    unified_vr = union!([VersionRange("1.5-2.2"), VersionRange("2.5-3")])[1]
    @test unified_vr.lower.t == (UInt32(1), UInt32(5), UInt32(0))
    @test unified_vr.upper.t == (UInt32(2), UInt32(2), UInt32(0))
    unified_vr = union!([VersionRange("1.5-2.2"), VersionRange("2.5-3")])[2]
    @test unified_vr.lower.t == (UInt32(2), UInt32(5), UInt32(0))
    @test unified_vr.upper.t == (UInt32(3), UInt32(0), UInt32(0))
    unified_vb = Types.VersionBound(union!([v"1.5", v"1.6"])[1])
    @test unified_vb.t == (UInt32(1), UInt32(5), UInt32(0))
    unified_vb = Types.VersionBound(union!([v"1.5", v"1.6"])[2])
    @test unified_vb.t == (UInt32(1), UInt32(6), UInt32(0))
    unified_vb = Types.VersionBound(union!([v"1.5", v"1.5"])[1])
    @test unified_vb.t == (UInt32(1), UInt32(5), UInt32(0))
end

temp_pkg_dir() do project_path
    @testset "simple add, remove and gc" begin
        Pkg.activate(project_path)
        Pkg.add(TEST_PKG.name)
        @test isinstalled(TEST_PKG)
        @eval import $(Symbol(TEST_PKG.name))
        @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
        Pkg.rm(TEST_PKG.name)
        @test !isinstalled(TEST_PKG)
        pkgdir = joinpath(Pkg.depots1(), "packages")

        # Test to ensure that with a long enough collect_delay, nothing gets reaped
        Pkg.gc(;collect_delay=Day(1000))
        @test !isempty(readdir(pkgdir))

        # Setting collect_delay to zero causes it to be reaped immediately, however
        Pkg.gc(;collect_delay=Second(0))
        @test isempty(readdir(pkgdir))

        clonedir = joinpath(Pkg.depots1(), "clones")
        Pkg.add(Pkg.PackageSpec(name=TEST_PKG.name, rev="master"))
        @test !isempty(readdir(clonedir))
        Pkg.rm(TEST_PKG.name)
        Pkg.gc(;collect_delay=Day(1000))
        @test !isempty(readdir(clonedir))
        Pkg.gc(;collect_delay=Second(0))
        @test isempty(readdir(clonedir))
    end

    @testset "package with wrong UUID" begin
        @test_throws PkgError Pkg.add(PackageSpec(TEST_PKG.name, UUID(UInt128(1))))
        # Missing uuid
        @test_throws PkgError Pkg.add(PackageSpec(uuid = uuid4()))
    end

    @testset "adding and upgrading different versions" begin
        # VersionNumber
        Pkg.add(PackageSpec(TEST_PKG.name, v"0.3"))
        @test @inferred(Pkg.dependencies())[TEST_PKG.uuid].version == v"0.3"
        Pkg.add(PackageSpec(TEST_PKG.name, v"0.3.1"))
        @test Pkg.dependencies()[TEST_PKG.uuid].version == v"0.3.1"
        Pkg.rm(TEST_PKG.name)

        # VersionRange
        Pkg.add(PackageSpec(TEST_PKG.name, VersionSpec(VersionRange("0.3.0-0.3.2"))))
        @test Pkg.dependencies()[TEST_PKG.uuid].version == v"0.3.2"
        # Check that adding another packages doesn't upgrade other packages
        Pkg.add("Test")
        @test Pkg.dependencies()[TEST_PKG.uuid].version == v"0.3.2"
        Pkg.update(; level = UPLEVEL_PATCH)
        @test Pkg.dependencies()[TEST_PKG.uuid].version == v"0.3.3"
        Pkg.update(; level = UPLEVEL_MINOR)
        @test Pkg.dependencies()[TEST_PKG.uuid].version.minor != 3
        Pkg.rm(TEST_PKG.name)
    end

    @testset "testing" begin
        Pkg.add(TEST_PKG.name)
        Pkg.test(TEST_PKG.name; coverage=true)
        pkgdir = Base.locate_package(Base.PkgId(TEST_PKG.uuid, TEST_PKG.name))
        # No coverage files being generated?
        @test_broken TEST_PKG.name * ".cov" in readdir(pkgdir)
        Pkg.rm(TEST_PKG.name)
    end

    @testset "pinning / freeing" begin
        Pkg.add(TEST_PKG.name)
        old_v = Pkg.dependencies()[TEST_PKG.uuid].version
        Pkg.pin(Pkg.PackageSpec(;name=TEST_PKG.name, version=v"0.2"))
        @test Pkg.dependencies()[TEST_PKG.uuid].version.minor == 2
        Pkg.update(TEST_PKG.name)
        @test Pkg.dependencies()[TEST_PKG.uuid].version.minor == 2
        Pkg.free(TEST_PKG.name)
        Pkg.update()
        @test Pkg.dependencies()[TEST_PKG.uuid].version == old_v
        Pkg.rm(TEST_PKG.name)
    end

    @testset "develop / freeing" begin
        Pkg.add(TEST_PKG.name)
        old_v = Pkg.dependencies()[TEST_PKG.uuid].version
        Pkg.rm(TEST_PKG.name)
        mktempdir() do devdir
            withenv("JULIA_PKG_DEVDIR" => devdir) do
                @test_throws PkgError Pkg.develop(Pkg.PackageSpec(url="bleh", rev="blurg"))
                Pkg.develop(TEST_PKG.name)
                @test isinstalled(TEST_PKG)
                @test Pkg.dependencies()[TEST_PKG.uuid].version > old_v
                test_pkg_main_file = joinpath(devdir, TEST_PKG.name, "src", TEST_PKG.name * ".jl")
                @test isfile(test_pkg_main_file)
                # Pkg #152
                write(test_pkg_main_file,
                    """
                    module Example
                        export hello, domath
                        const example2path = joinpath(@__DIR__, "..", "deps", "deps.jl")
                        if !isfile(example2path)
                            error("Example is not installed correctly")
                        end
                        hello(who::String) = "Hello, \$who"
                        domath(x::Number) = x + 5
                    end
                    """)
                mkpath(joinpath(devdir, TEST_PKG.name, "deps"))
                write(joinpath(devdir, TEST_PKG.name, "deps", "build.jl"),
                    """
                    touch("deps.jl")
                    """
                )
                Pkg.build(TEST_PKG.name)
                @test isfile(joinpath(devdir, TEST_PKG.name, "deps", "deps.jl"))
                Pkg.test(TEST_PKG.name)
                Pkg.free(TEST_PKG.name)
                @test Pkg.dependencies()[TEST_PKG.uuid].version == old_v
            end
        end
    end

    @testset "stdlibs as direct dependency" begin
        uuid_pkg = (name = "CRC32c", uuid = UUID("8bf52ea8-c179-5cab-976a-9e18b702a9bc"))
        Pkg.add("CRC32c")
        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
        Pkg.update()
        # Disable until fixed in Base
        # Pkg.test("CRC32c")
        Pkg.rm("CRC32c")
    end

    @testset "package name in resolver errors" begin
        try
            Pkg.add(PackageSpec(;name = TEST_PKG.name, version = v"55"))
        catch e
            @test occursin(TEST_PKG.name, sprint(showerror, e))
        end
    end

    @testset "protocols" begin
        mktempdir() do devdir
            withenv("JULIA_PKG_DEVDIR" => devdir) do
                try
                    # Test below commented out because it is really slow, https://github.com/JuliaLang/Pkg.jl/issues/1291
                    #Pkg.setprotocol!(domain = "github.com", protocol = "notarealprotocol")
                    #@test_throws PkgError Pkg.develop("Example")
                    Pkg.setprotocol!(domain = "github.com", protocol = "https")
                    Pkg.develop("Example")
                    @test isinstalled(TEST_PKG)
                finally
                    Pkg.setprotocol!(domain = "github.com")
                end
            end
        end
        mktempdir() do devdir
            withenv("JULIA_PKG_DEVDIR" => devdir) do
                try
                    https_url = "https://github.com/JuliaLang/Example.jl.git"
                    ssh_url = "ssh://git@github.com/JuliaLang/Example.jl.git"
                    @test Pkg.GitTools.normalize_url(https_url) == https_url
                    Pkg.setprotocol!(domain = "github.com", protocol = "ssh")
                    @test Pkg.GitTools.normalize_url(https_url) == ssh_url
                    # TODO: figure out how to test this without
                    #       having to deploy a ssh key on github
                    #Pkg.develop("Example")
                    #@test isinstalled(TEST_PKG)

                    https_url = "https://gitlab.example.com/example/Example.jl.git"
                    ssh_url = "ssh://git@gitlab.example.com/example/Example.jl.git"

                    @test Pkg.GitTools.normalize_url(https_url) == https_url
                    Pkg.setprotocol!(domain = "gitlab.example.com", protocol = "ssh")
                    @test Pkg.GitTools.normalize_url(https_url) == ssh_url

                    @test_deprecated Pkg.setprotocol!("ssh")
                    @test_deprecated Pkg.GitTools.setprotocol!("ssh")

                finally
                    Pkg.setprotocol!(domain = "github.com")
                    Pkg.setprotocol!(domain = "gitlab.example.com")
                end
            end
        end
    end

    @testset "check logging" begin
        usage = TOML.parsefile(joinpath(Pkg.logdir(), "manifest_usage.toml"))
        manifest = Pkg.safe_realpath(joinpath(project_path, "Manifest.toml"))
        @test any(x -> startswith(x, manifest), keys(usage))
    end

    @testset "test atomicity of write_env_usage with $(Sys.CPU_THREADS) parallel processes" begin
        tasks = Task[]
        iobs = IOBuffer[]
        Sys.CPU_THREADS == 1 && error("Cannot test for atomic usage log file interaction effectively with only Sys.CPU_THREADS=1")
        # to precompile Pkg given we're in a different depot
        run(`$(Base.julia_cmd()) --project="$(pkgdir(Pkg))" -e "import Pkg"`)
        # make sure the General registry is installed
        Utils.show_output_if_command_errors(`$(Base.julia_cmd()) --project="$(pkgdir(Pkg))" -e "import Pkg; Pkg.Registry.add()"`)
        flag_start_dir = tempdir() # once n=Sys.CPU_THREADS files are in here, the processes can proceed to the concurrent test
        flag_end_file = tempname() # use creating this file as a way to stop the processes early if an error happens
        for i in 1:Sys.CPU_THREADS
            iob = IOBuffer()
            t = @async run(pipeline(`$(Base.julia_cmd()[1]) --project="$(pkgdir(Pkg))"
                -e "import Pkg;
                Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true;
                Pkg.activate(temp = true);
                Pkg.add(\"Random\", io = devnull);
                touch(tempname(raw\"$flag_start_dir\")) # file marker that first part has finished
                while length(readdir(raw\"$flag_start_dir\")) < $(Sys.CPU_THREADS)
                    # sync all processes to start at the same time
                    sleep(0.1)
                end
                @async begin
                    sleep(15)
                    touch(raw\"$flag_end_file\")
                end
                i = 0
                while !isfile(raw\"$flag_end_file\")
                    global i += 1
                    try
                        Pkg.Types.EnvCache()
                    catch
                        touch(raw\"$flag_end_file\")
                        println(stderr, \"Errored after $i iterations\")
                        rethrow()
                    end
                    yield()
                end"`,
                stderr = iob, stdout = devnull))
            push!(tasks, t)
            push!(iobs, iob)
        end
        for i in eachindex(tasks)
            try
                fetch(tasks[i]) # If any of these failed it will throw when fetched
            catch
                print(String(take!(iobs[i])))
                break
            end
        end
        @test any(istaskfailed, tasks) == false
    end

    @testset "adding nonexisting packages" begin
        nonexisting_pkg = randstring(14)
        @test_throws PkgError Pkg.add(nonexisting_pkg)
        @test_throws PkgError Pkg.update(nonexisting_pkg)
    end

    Pkg.rm(TEST_PKG.name)

    @testset "add julia" begin
        @test_throws PkgError Pkg.add("julia")
    end
end

temp_pkg_dir() do project_path
    @testset "libgit2 downloads" begin
        Pkg.add(TEST_PKG.name; use_git_for_all_downloads=true)
        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
        @eval import $(Symbol(TEST_PKG.name))
        @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
        Pkg.rm(TEST_PKG.name)
    end

    @testset "up in Project without manifest" begin
        mktempdir() do dir
            cp(joinpath(@__DIR__, "test_packages", "UnregisteredWithProject"), joinpath(dir, "UnregisteredWithProject"))
            cd(joinpath(dir, "UnregisteredWithProject")) do
                with_current_env() do
                    Pkg.update()
                    @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
                end
            end
        end
    end
end

temp_pkg_dir() do project_path
    @testset "libgit2 downloads" begin
        Pkg.add(TEST_PKG.name; use_git_for_all_downloads=true)
        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
        Pkg.rm(TEST_PKG.name)
    end
    @testset "tarball downloads" begin
        Pkg.add("JSON"; use_only_tarballs_for_downloads=true)
        @test "JSON" in [pkg.name for (uuid, pkg) in Pkg.dependencies()]
        Pkg.rm("JSON")
    end
end

temp_pkg_dir() do project_path
    @testset "test should instantiate" begin
        mktempdir() do dir
            cp(joinpath(@__DIR__, "test_packages", "UnregisteredWithProject"), joinpath(dir, "UnregisteredWithProject"))
            cd(joinpath(dir, "UnregisteredWithProject")) do
                with_current_env() do
                    Pkg.add("Test") # test https://github.com/JuliaLang/Pkg.jl/issues/324
                    Pkg.test()
                end
            end
        end
    end
end

temp_pkg_dir() do project_path
    @testset "valid project file names" begin
        extract_uuid(toml_path) = begin
            uuid = ""
            for line in eachline(toml_path)
                m = match(r"uuid = \"(.+)\"", line)
                if m !== nothing
                    uuid = m.captures[1]
                    break
                end
            end
            return uuid
        end

        cd(project_path) do
            target_dir = mktempdir()
            uuid = nothing
            mktempdir() do tmp; cd(tmp) do
                pkg_name = "FooBar"
                # create a project and grab its uuid
                Pkg.generate(pkg_name)
                uuid = extract_uuid(joinpath(pkg_name, "Project.toml"))
                # activate project env
                Pkg.activate(abspath(pkg_name))
                # add an example project to populate manifest file
                Pkg.add("Example")
                # change away from default names
                ## note: this is written awkwardly because a `mv` here causes failures on AppVeyor
                cp(joinpath(pkg_name, "src"), joinpath(target_dir, "src"))
                cp(joinpath(pkg_name, "Project.toml"), joinpath(target_dir, "JuliaProject.toml"))
                cp(joinpath(pkg_name, "Manifest.toml"), joinpath(target_dir, "JuliaManifest.toml"))
            end end
            Pkg.activate()
            # make sure things still work
            Pkg.REPLMode.pkgstr("dev $target_dir")
            @test isinstalled((name="FooBar", uuid=UUID(uuid)))
            Pkg.rm("FooBar")
            @test !isinstalled((name="FooBar", uuid=UUID(uuid)))
        end # cd project_path
    end # @testset
end

temp_pkg_dir() do project_path
    @testset "invalid repo url" begin
        cd(project_path) do
            @test_throws PkgError Pkg.add("https://github.com")
            Pkg.generate("FooBar")
            @test_throws PkgError Pkg.add("./Foobar")
        end
    end
end

temp_pkg_dir() do project_path; cd(project_path) do
    tmp = mktempdir()
    depo1 = mktempdir()
    depo2 = mktempdir()
    cd(tmp) do; @testset "instantiating updated repo" begin
        empty!(DEPOT_PATH)
        pushfirst!(DEPOT_PATH, depo1)
        LibGit2.close(LibGit2.clone("https://github.com/JuliaLang/Example.jl", "Example.jl"))
        mkdir("machine1")
        cd("machine1")
        Pkg.activate(".")
        Pkg.add(Pkg.PackageSpec(path="../Example.jl"))
        cd("..")
        cp("machine1", "machine2")
        empty!(DEPOT_PATH)
        pushfirst!(DEPOT_PATH, depo2)
        cd("machine2")
        Pkg.activate(".")
        Pkg.instantiate()
        cd("..")
        cd("Example.jl")
        open("README.md", "a") do io
            print(io, "Hello")
        end
        LibGit2.with(LibGit2.GitRepo(".")) do repo
            LibGit2.add!(repo, "*")
            LibGit2.commit(repo, "changes"; author=TEST_SIG, committer=TEST_SIG)
        end
        cd("../machine1")
        empty!(DEPOT_PATH)
        pushfirst!(DEPOT_PATH, depo1)
        Pkg.activate(".")
        Pkg.update()
        cd("..")
        cp("machine1/Manifest.toml", "machine2/Manifest.toml"; force=true)
        cd("machine2")
        empty!(DEPOT_PATH)
        pushfirst!(DEPOT_PATH, depo2)
        Pkg.activate(".")
        Pkg.instantiate()
    end end
    Base.rm.([tmp, depo1, depo2]; force = true, recursive = true)
end end

@testset "printing of stdlib paths, issue #605" begin
    path = Pkg.Types.stdlib_path("Test")
    @test Pkg.pathrepr(path) == "`@stdlib/Test`"
end

@testset "stdlib_resolve!" begin
    a = Pkg.Types.PackageSpec(name="Markdown")
    b = Pkg.Types.PackageSpec(uuid=UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"))
    Pkg.Types.stdlib_resolve!([a, b])
    @test a.uuid == UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
    @test b.name == "Profile"

    x = Pkg.Types.PackageSpec(name="Markdown", uuid=UUID("d6f4376e-aef5-505a-96c1-9c027394607a"))
    Pkg.Types.stdlib_resolve!([x])
    @test x.name == "Markdown"
    @test x.uuid == UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
end

@testset "issue #913" begin
    temp_pkg_dir() do project_path
        Pkg.activate(project_path)
        Pkg.add(Pkg.PackageSpec(name="Example", rev = "master"))
        @test isinstalled(TEST_PKG)
        rm.(joinpath.(project_path, ["Project.toml","Manifest.toml"]))
        Pkg.add(Pkg.PackageSpec(name="Example", rev = "master")) # should not fail
        @test isinstalled(TEST_PKG)
    end
end

#issue #975
@testset "Pkg.gc" begin
    temp_pkg_dir() do project_path
        with_temp_env() do
            Pkg.add("Example")
            Pkg.gc()
            # issue #601 and #1228
            touch(joinpath(Pkg.depots1(), "packages", ".DS_Store"))
            touch(joinpath(Pkg.depots1(), "packages", "Example", ".DS_Store"))
            Pkg.gc()
        end
    end
end

#issue #876
@testset "targets should survive add/rm" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir
        cp(joinpath(@__DIR__, "project", "good", "pkg.toml"), "Project.toml")
        mkdir("src")
        touch("src/Pkg.jl")
        targets = deepcopy(Pkg.Types.read_project("Project.toml").targets)
        Pkg.activate(".")
        Pkg.add("Example")
        Pkg.rm("Example")
        @test targets == Pkg.Types.read_project("Project.toml").targets
    end end
end

@testset "canonicalized relative paths in manifest" begin
    mktempdir() do tmp; cd(tmp) do
        write("Manifest.toml",
            """
            [[Foo]]
            path = "bar/Foo"
            uuid = "824dc81a-29a7-11e9-3958-fba342a32644"
            version = "0.1.0"
            """)
        manifest = Pkg.Types.read_manifest("Manifest.toml")
        package = manifest[Base.UUID("824dc81a-29a7-11e9-3958-fba342a32644")]
        @test package.path == (Sys.iswindows() ? "bar\\Foo" : "bar/Foo")
        Pkg.Types.write_manifest(manifest, "Manifest.toml")
        @test occursin("path = \"bar/Foo\"", read("Manifest.toml", String))
    end end
end

@testset "building project should fix version of deps" begin
    temp_pkg_dir() do project_path
        dep_pkg = joinpath(@__DIR__, "test_packages", "BuildProjectFixedDeps")
        Pkg.activate(dep_pkg)
        Pkg.build()
        @test isfile(joinpath(dep_pkg, "deps", "artifact"))
    end
end

@testset "PkgError printing" begin
    err = PkgError("foobar")
    @test occursin("PkgError(\"foobar\")", sprint(show, err))
    @test sprint(showerror, err) == "foobar"
end

@testset "issue #1066: package with colliding name/uuid exists in project" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir
        Pkg.activate(".")
        Pkg.generate("A")
        cd(mkdir("packages")) do
            Pkg.generate("A")
            git_init_and_commit("A")
        end
        Pkg.generate("B")
        project = Pkg.Types.read_project("A/Project.toml")
        project.name = "B"
        Pkg.Types.write_project(project, "B/Project.toml")
        git_init_and_commit("B")
        Pkg.develop(Pkg.PackageSpec(path = abspath("A")))
        # package with same name but different uuid exist in project
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(path = abspath("packages", "A")))
        @test_throws PkgError Pkg.add(Pkg.PackageSpec(path = abspath("packages", "A")))
        # package with same uuid but different name exist in project
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(path = abspath("B")))
        @test_throws PkgError Pkg.add(Pkg.PackageSpec(path = abspath("B")))
    end end
end

@testset "issue #1180: broken toml-files in HEAD" begin
    temp_pkg_dir() do dir; cd(dir) do
        write("Project.toml", "[deps]\nExample = \n")
        git_init_and_commit(dir)
        write("Project.toml", "[deps]\nExample = \"7876af07-990d-54b4-ab0e-23690620f79a\"\n")
        Pkg.activate(dir)
        @test_logs (:warn, r"could not read project from HEAD") Pkg.status(diff=true)
    end end
end

import Markdown
@testset "REPL command doc generation" begin
    # test that the way doc building extracts
    # docstrings for Pkg REPL commands work
    d = Dict(Pkg.REPLMode.canonical_names())
    @test d["add"].help isa Markdown.MD
    @test d["registry add"].help isa Markdown.MD
end

@testset "up should prune manifest" begin
    example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    unicode_uuid = UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5")
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "Unpruned")
        Pkg.activate(joinpath(tmp, "Unpruned"))
        Pkg.update()
        manifest = Pkg.Types.Context().env.manifest
        package_example = get(manifest, example_uuid, nothing)
        @test package_example !== nothing
        @test package_example.version > v"0.4.0"
        @test get(manifest, unicode_uuid, nothing) === nothing
    end end
end

@testset "undo redo functionality" begin
    unicode_uuid = UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5")
    temp_pkg_dir() do project_path; with_temp_env() do
        # Example
        Pkg.add(TEST_PKG.name)
        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
        #
        Pkg.undo()
        @test !haskey(Pkg.dependencies(), TEST_PKG.uuid)
        # Example
        Pkg.redo()
        # Example, Unicode
        Pkg.add("Unicode")
        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
        # Example
        Pkg.undo()
        @test !haskey(Pkg.dependencies(), unicode_uuid)
        #
        Pkg.undo()
        @test !haskey(Pkg.dependencies(), TEST_PKG.uuid)
        # Example, Unicode
        Pkg.redo()
        Pkg.redo()
        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
        @test haskey(Pkg.dependencies(), unicode_uuid)
        # Should not add states since they are nops
        Pkg.add("Unicode")
        Pkg.add("Unicode")
        # Example
        Pkg.undo()
        @test !haskey(Pkg.dependencies(), unicode_uuid)
        # Example, Unicode
        Pkg.redo()
        @test haskey(Pkg.dependencies(), unicode_uuid)

        # Example
        Pkg.undo()

        prev_project = Base.active_project()
        mktempdir() do tmp
            Pkg.activate(tmp)
            Pkg.add("Example")
            Pkg.undo()
            @test !haskey(Pkg.dependencies(), TEST_PKG.uuid)
        end
        Pkg.activate(prev_project)

        # Check that undo state persists after swapping projects
        # Example, Unicode
        Pkg.redo()
        @test haskey(Pkg.dependencies(), unicode_uuid)

    end end
end

@testset "subdir functionality" begin
    temp_pkg_dir() do project_path; with_temp_env() do
        mktempdir() do tmp
            repodir = git_init_package(tmp, joinpath(@__DIR__, "test_packages", "MainRepo"))
            # Add with subdir
            subdir_uuid = UUID("6fe4e069-dcb0-448a-be67-3a8bf3404c58")
            Pkg.add(url = repodir, subdir = "SubDir")
            pkgdir = abspath(joinpath(dirname(Base.find_package("SubDir")), ".."))

            # Update with subdir in manifest
            Pkg.update()
            # Test instantiate with subdir
            rm(pkgdir; recursive=true)
            Pkg.instantiate()
            @test isinstalled("SubDir")
            Pkg.rm("SubDir")

            # Dev of local path with subdir
            Pkg.develop(path=repodir, subdir="SubDir")
            @test Pkg.dependencies()[subdir_uuid].source == joinpath(repodir, "SubDir")
        end
    end end
end

# PR #1784 - Remove trailing slash from URL.
@testset "URL with trailing slash" begin
    temp_pkg_dir() do project_path
        with_temp_env() do
            Pkg.add(Pkg.PackageSpec(url = "https://github.com/JuliaLang/Example.jl.git/"))
            @test isinstalled("Example")
        end
    end
end

@testset "Pkg.test process failure" begin
    temp_pkg_dir() do project_path
        mktempdir() do dir
            cp(joinpath(@__DIR__, "test_packages", "TestFailure"), joinpath(dir, "TestFailure"))
            cd(joinpath(dir, "TestFailure")) do
                with_current_env() do
                    Sys.isunix() && @testset "signal: KILL" begin
                        withenv("TEST_SIGNAL" => "KILL") do
                            try
                                Pkg.test()
                                @test false
                            catch err
                                @test err isa PkgError
                                @test err.msg == "Package TestFailure errored during testing (received signal: KILL)"
                            end
                        end
                    end

                    # # The following test is broken on macOS
                    # Sys.islinux() && @testset "signal: QUIT" begin
                    #     withenv("TEST_SIGNAL" => "QUIT") do
                    #         try
                    #             Pkg.test()
                    #             @test false
                    #         catch err
                    #             @test err isa PkgError
                    #             @test err.msg == "Package TestFailure errored during testing (exit code: 131)"
                    #         end
                    #     end
                    # end

                    @testset "exit code: 1" begin
                        withenv("TEST_EXITCODE" => "1") do
                            try
                                Pkg.test()
                                @test false
                            catch err
                                @test err isa PkgError
                                @test err.msg == "Package TestFailure errored during testing"
                            end
                        end
                    end

                    @testset "exit code: 2" begin
                        withenv("TEST_EXITCODE" => "2") do
                            try
                                Pkg.test()
                                @test false
                            catch err
                                @test err isa PkgError
                                @test err.msg == "Package TestFailure errored during testing (exit code: 2)"
                            end
                        end
                    end

                    @testset "multiple failures" begin
                        withenv("TEST_EXITCODE" => "3") do
                            try
                                Pkg.test(["TestFailure", "TestFailure"])
                                @test false
                            catch err
                                @test err isa PkgError
                                @test err.msg == """
                                    Packages errored during testing:
                                    • TestFailure (exit code: 3)
                                    • TestFailure (exit code: 3)"""
                            end
                        end
                    end
                end
            end
        end
    end
end

import Pkg.Resolve.range_compressed_versionspec
@testset "range_compressed_versionspec" begin
    pool = [v"1.0.0", v"1.1.0", v"1.2.0", v"1.2.1", v"2.0.0", v"2.0.1", v"3.0.0", v"3.1.0"]
    @test (range_compressed_versionspec(pool)
        == range_compressed_versionspec(pool, pool)
        == VersionSpec("1.0.0-3.1.0")
    )

    @test isequal(
        range_compressed_versionspec(pool, [v"1.2.0", v"1.2.1", v"2.0.0", v"2.0.1", v"3.0.0"]),
        VersionSpec("1.2.0-3.0.0")
    )

    @test isequal(  # subset has 1.x and 3.x, but not 2.x
        range_compressed_versionspec(
            pool, [v"1.0.0", v"1.1.0", v"1.2.0", v"1.2.1", v"3.0.0", v"3.1.0"]
        ),
        VersionSpec([VersionRange(v"1.0.0", v"1.2.1"), VersionRange(v"3.0.0", v"3.1.0")])
    )

    @test range_compressed_versionspec(pool, [v"1.1.0"]) == VersionSpec("1.1.0")
end

@testset "versionspec with v" begin
    v = VersionSpec("v1.2.3")
    @test !(v"1.2.2" in v)
    @test   v"1.2.3" in v
    @test !(v"1.2.4" in v)
end

@testset "Suggest `Pkg.develop` instead of `Pkg.add`" begin
    mktempdir() do tmp_dir
        touch(joinpath(tmp_dir, "Project.toml"))
        @test_throws Pkg.Types.PkgError Pkg.add(; path = tmp_dir)
    end
end

@testset "Issue #3069" begin
    p = PackageSpec(; path="test_packages/Example")
    @test_throws Pkg.Types.PkgError("Package PackageSpec(\n  path = test_packages/Example\n  version = *\n) has neither name nor uuid") ensure_resolved(Pkg.Types.Context(), Pkg.Types.Manifest(), [p])
end

end # module
