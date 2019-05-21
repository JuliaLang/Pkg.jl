# This file is a part of Julia. License is MIT: https://julialang.org/license

module OperationsTest

import Random: randstring
import LibGit2
using Test
using UUIDs

using Pkg
using Pkg.Types

import Random: randstring
import LibGit2

include("utils.jl")

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

    @test_throws ErrorException semver_spec("^^0.2.3")
    @test_throws ErrorException semver_spec("^^0.2.3.4")
    @test_throws ErrorException semver_spec("0.0.0")

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
    @testset "simple add and remove with preview" begin
        Pkg.activate(project_path)
        Pkg.add(TEST_PKG.name; preview = true)
        @test !isinstalled(TEST_PKG)
        Pkg.add(TEST_PKG.name)
        @test isinstalled(TEST_PKG)
        @eval import $(Symbol(TEST_PKG.name))
        @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
        Pkg.rm(TEST_PKG.name; preview = true)
        @test isinstalled(TEST_PKG)
        Pkg.rm(TEST_PKG.name)
        @test !isinstalled(TEST_PKG)
        # https://github.com/JuliaLang/Pkg.jl/issues/601
        pkgdir = joinpath(Pkg.depots1(), "packages")
        touch(joinpath(pkgdir, ".DS_Store"))
        Pkg.gc()
        rm(joinpath(pkgdir, ".DS_Store"))
        @test isempty(readdir(pkgdir))
    end

    @testset "package with wrong UUID" begin
        @test_throws PkgError Pkg.add(PackageSpec(TEST_PKG.name, UUID(UInt128(1))))
    end

    @testset "adding and upgrading different versions" begin
        # VersionNumber
        Pkg.add(PackageSpec(TEST_PKG.name, v"0.3"))
        @test Pkg.API.__installed()[TEST_PKG.name] == v"0.3"
        Pkg.add(PackageSpec(TEST_PKG.name, v"0.3.1"))
        @test Pkg.API.__installed()[TEST_PKG.name] == v"0.3.1"
        Pkg.rm(TEST_PKG.name)

        # VersionRange
        Pkg.add(PackageSpec(TEST_PKG.name, VersionSpec(VersionRange("0.3.0-0.3.2"))))
        @test Pkg.API.__installed()[TEST_PKG.name] == v"0.3.2"
        # Check that adding another packages doesn't upgrade other packages
        Pkg.add("Test")
        @test Pkg.API.__installed()[TEST_PKG.name] == v"0.3.2"
        Pkg.update(; level = UPLEVEL_PATCH)
        @test Pkg.API.__installed()[TEST_PKG.name] == v"0.3.3"
        Pkg.update(; level = UPLEVEL_MINOR)
        @test Pkg.API.__installed()[TEST_PKG.name].minor != 3
        Pkg.rm(TEST_PKG.name)
    end

    @testset "testing" begin
        # TODO: Check that preview = true doesn't actually execute the test
        Pkg.add(TEST_PKG.name)
        Pkg.test(TEST_PKG.name; coverage=true)
        pkgdir = Base.locate_package(Base.PkgId(TEST_PKG.uuid, TEST_PKG.name))
        # No coverage files being generated?
        @test_broken TEST_PKG.name * ".cov" in readdir(pkgdir)
        Pkg.rm(TEST_PKG.name)
    end

    @testset "pinning / freeing" begin
        Pkg.add(TEST_PKG.name)
        old_v = Pkg.API.__installed()[TEST_PKG.name]
        Pkg.pin(PackageSpec(TEST_PKG.name, v"0.2"))
        @test Pkg.API.__installed()[TEST_PKG.name].minor == 2
        Pkg.update(TEST_PKG.name)
        @test Pkg.API.__installed()[TEST_PKG.name].minor == 2
        Pkg.free(TEST_PKG.name)
        Pkg.update()
        @test Pkg.API.__installed()[TEST_PKG.name] == old_v
        Pkg.rm(TEST_PKG.name)
    end

    @testset "develop / freeing" begin
        Pkg.add(TEST_PKG.name)
        old_v = Pkg.API.__installed()[TEST_PKG.name]
        Pkg.rm(TEST_PKG.name)
        mktempdir() do devdir
            withenv("JULIA_PKG_DEVDIR" => devdir) do
                @test_throws PkgError Pkg.develop(Pkg.PackageSpec(url="bleh", rev="blurg"))
                Pkg.develop(TEST_PKG.name)
                @test isinstalled(TEST_PKG)
                @test Pkg.API.__installed()[TEST_PKG.name] > old_v
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
                @test Pkg.API.__installed()[TEST_PKG.name] == old_v
            end
        end
    end

    @testset "invalid pkg name" begin
        @test_throws PkgError Pkg.add(",sa..,--")
    end

    @testset "stdlibs as direct dependency" begin
        uuid_pkg = (name = "CRC32c", uuid = UUID("8bf52ea8-c179-5cab-976a-9e18b702a9bc"))
        Pkg.add("CRC32c")
        @test haskey(Pkg.API.__installed(), uuid_pkg.name)
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
                    Pkg.setprotocol!(domain = "github.com", protocol = "notarealprotocol")
                    @test_throws PkgError Pkg.develop("Example")
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
        usage = Pkg.TOML.parse(String(read(joinpath(Pkg.logdir(), "manifest_usage.toml"))))
        manifest = Types.safe_realpath(joinpath(project_path, "Manifest.toml"))
        @test any(x -> startswith(x, manifest), keys(usage))
    end

    @testset "adding nonexisting packages" begin
        nonexisting_pkg = randstring(14)
        @test_throws PkgError Pkg.add(nonexisting_pkg)
        @test_throws PkgError Pkg.update(nonexisting_pkg)
    end

    Pkg.rm(TEST_PKG.name)

    @testset "legacy CI script" begin
        mktempdir() do dir
            LibGit2.with(LibGit2.clone("https://github.com/JuliaLang/Example.jl", joinpath(dir, "Example.jl"))) do r
                cd(joinpath(dir, "Example.jl")) do
                    let Pkg = Pkg
                        Pkg.clone(pwd())
                        Pkg.build("Example")
                        Pkg.test("Example"; coverage=true)
                        @test isfile(Pkg.dir("Example", "src", "Example.jl"))
                    end
                end
            end
        end
    end

    @testset "add julia" begin
        @test_throws PkgError Pkg.add("julia")
    end
end

temp_pkg_dir() do project_path
    @testset "libgit2 downloads" begin
        Pkg.add(TEST_PKG.name; use_libgit2_for_all_downloads=true)
        @test haskey(Pkg.installed(), TEST_PKG.name)
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
                    @test haskey(Pkg.API.__installed(), "Example")
                end
            end
        end
    end
end

temp_pkg_dir() do project_path
    @testset "libgit2 downloads" begin
        Pkg.add(TEST_PKG.name; use_libgit2_for_all_downloads=true)
        @test haskey(Pkg.API.__installed(), TEST_PKG.name)
        Pkg.rm(TEST_PKG.name)
    end
    @testset "tarball downloads" begin
        Pkg.add("JSON"; use_only_tarballs_for_downloads=true)
        @test haskey(Pkg.API.__installed(), "JSON")
        Pkg.rm("JSON")
    end
end

@testset "preview generate" begin
    mktempdir() do tmp
        cd(tmp) do
            Pkg.generate("Foo"; preview=true)
            @test !isdir(joinpath(tmp, "Foo"))
        end
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

temp_pkg_dir() do project_path
    # pkg assumes `Example.jl` is still a git repo, it will try to fetch on `update`
    # `fetch` should warn that it is no longer a git repo
    with_temp_env() do
        @testset "inconsistent repo state" begin
            package_path = joinpath(project_path, "Example")
            LibGit2.with(LibGit2.clone("https://github.com/JuliaLang/Example.jl", package_path)) do repo
                Pkg.add(Pkg.PackageSpec(path=package_path))
            end
            rm(joinpath(package_path, ".git"); force=true, recursive=true)
            @test_throws PkgError Pkg.update()
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

temp_pkg_dir() do project_path
    cd(project_path) do
        project = """
        [deps]
        UUIDs = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

        [extras]
        Markdown = "d6f4376e-aef5-505a-96c1-9c027394607a"
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Markdown", "Test"]
        """
        write("Project.toml", project)
        Pkg.activate(".")
        @testset "resolve ignores extras" begin
            Pkg.resolve()
            @test !(occursin("[[Test]]", read("Manifest.toml", String)))
        end
    end
end

@testset "dependency of test dependency (#567)" begin
    temp_pkg_dir() do project_path; cd_tempdir(;rm=false) do tmpdir; with_temp_env(;rm=false) do
        for x in ["x1", "x2", "x3"]
            cp(joinpath(@__DIR__, "test_packages/$x"), joinpath(tmpdir, "$x"))
            Pkg.develop(Pkg.PackageSpec(url = joinpath(tmpdir, x)))
        end
        Pkg.test("x3")
    end end end
end

@testset "printing of stdlib paths, issue #605" begin
    path = Pkg.Types.stdlib_path("Test")
    @test Pkg.Types.pathrepr(path) == "`@stdlib/Test`"
end

@testset "Set download concurrency" begin
    withenv("JULIA_PKG_CONCURRENCY" => 1) do
        ctx = Pkg.Types.Context()
        @test ctx.num_concurrent_downloads == 1
    end
end

temp_pkg_dir() do project_path
    @testset "Pkg.add should not mutate" begin
        package_names = ["JSON"]
        packages = PackageSpec.(package_names)
        Pkg.add(packages)
        @test [p.name for p in packages] == package_names
    end
end

@testset "manifest read/write unit tests" begin
    manifestdir = joinpath(@__DIR__, "manifest", "good")
    temp = joinpath(mktempdir(), "x.toml")
    for testfile in joinpath.(manifestdir, readdir(manifestdir))
        a = Types.read_manifest(testfile)
        Types.write_manifest(a, temp)
        b = Types.read_manifest(temp)
        for (uuid, x) in a
            y = b[uuid]
            for property in propertynames(x)
                # `other` caches the *whole* input dictionary. its ok to mutate the fields of
                # the input dictionary if that field will eventually be overwriten on `write_manifest`
                property == :other && continue
                @test getproperty(x, property) == getproperty(y, property)
            end
        end
    end
    rm(dirname(temp); recursive = true, force = true)
    @test_throws PkgError Types.read_manifest(
        joinpath(@__DIR__, "manifest", "bad", "parse_error.toml"))
end

@testset "project read/write unit tests" begin
    projectdir = joinpath(@__DIR__, "project", "good")
    temp = joinpath(mktempdir(), "x.toml")
    for testfile in joinpath.(projectdir, readdir(projectdir))
        a = Types.read_project(testfile)
        Types.write_project(a, temp)
        b = Types.read_project(temp)
        for property in propertynames(a)
            @test getproperty(a, property) == getproperty(b, property)
        end
    end
    rm(dirname(temp); recursive = true, force = true)
    @test_throws PkgError Types.read_project(
        joinpath(@__DIR__, "project", "bad", "parse_error.toml"))
end

@testset "stdlib_resolve!" begin
    a = Pkg.Types.PackageSpec(name="Markdown")
    b = Pkg.Types.PackageSpec(uuid=UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"))
    Pkg.Types.stdlib_resolve!(Types.Context(), [a, b])
    @test a.uuid == UUID("d6f4376e-aef5-505a-96c1-9c027394607a")
    @test b.name == "Profile"

    x = Pkg.Types.PackageSpec(name="Markdown", uuid=UUID("d6f4376e-aef5-505a-96c1-9c027394607a"))
    Pkg.Types.stdlib_resolve!(Types.Context(), [x])
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

@testset "issue #1077" begin
    temp_pkg_dir() do project_path
        Pkg.add("UUIDs")
        # the following should not error
        Pkg.add("UUIDs")
        Pkg.test("UUIDs")
        @test_throws PkgError("cannot `pin` stdlibs.") Pkg.pin("UUIDs")
    end
end

#issue #975
@testset "Pkg.gc" begin
    temp_pkg_dir() do project_path
        with_temp_env() do
            Pkg.add("Example")
            Pkg.gc()
        end
    end
end

#issue #876
@testset "targets should survive add/rm" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir
        cp(joinpath(@__DIR__, "project", "good", "pkg.toml"), "Project.toml")
        targets = deepcopy(Pkg.Types.read_project("Project.toml").targets)
        Pkg.activate(".")
        Pkg.add("Example")
        Pkg.rm("Example")
        @test targets == Pkg.Types.read_project("Project.toml").targets
    end end
end

@testset "reading corrupted project files" begin
    dir = joinpath(@__DIR__, "project", "bad")
    for bad_project in joinpath.(dir, readdir(dir))
        @test_throws PkgError Pkg.Types.read_project(bad_project)
    end
end

@testset "reading corrupted manifest files" begin
    dir = joinpath(@__DIR__, "manifest", "bad")
    for bad_manifest in joinpath.(dir, readdir(dir))
        @test_throws PkgError Pkg.Types.read_manifest(bad_manifest)
    end
end

@testset "Unregistered UUID in manifest" begin
    temp_pkg_dir() do project_path; with_temp_env() do; cd_tempdir() do tmpdir
        cp(joinpath(@__DIR__, "test_packages", "UnregisteredUUID"), "UnregisteredUUID")
        Pkg.activate("UnregisteredUUID")
        @test_throws PkgError Pkg.update()
    end end end
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
            LibGit2.with(LibGit2.init("A")) do repo
                LibGit2.add!(repo, "*")
                LibGit2.commit(repo, "initial commit"; author=TEST_SIG, committer=TEST_SIG)
            end
        end
        Pkg.generate("B")
        project = Pkg.Types.read_project("A/Project.toml")
        project.name = "B"
        Pkg.Types.write_project(project, "B/Project.toml")
        LibGit2.with(LibGit2.init("B")) do repo
            LibGit2.add!(repo, "*")
            LibGit2.commit(repo, "initial commit"; author=TEST_SIG, committer=TEST_SIG)
        end
        Pkg.develop(Pkg.PackageSpec(path = abspath("A")))
        # package with same name but different uuid exist in project
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(path = abspath("packages", "A")))
        @test_throws PkgError Pkg.add(Pkg.PackageSpec(path = abspath("packages", "A")))
        # package with same uuid but different name exist in project
        @test_throws PkgError Pkg.develop(Pkg.PackageSpec(path = abspath("B")))
        @test_throws PkgError Pkg.add(Pkg.PackageSpec(path = abspath("B")))
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

@testset "instantiate should respect tree hash" begin
    temp_pkg_dir() do project_path; mktempdir() do tmp
        copy_test_package(tmp, "NotUpdated")
        Pkg.activate(joinpath(tmp, "NotUpdated"))
        hash = Pkg.Types.Context().env.manifest[TEST_PKG.uuid].tree_hash
        Pkg.instantiate()
        @test hash == Pkg.Types.Context().env.manifest[TEST_PKG.uuid].tree_hash
    end end
end

include("repl.jl")
include("api.jl")
include("registry.jl")

end # module
