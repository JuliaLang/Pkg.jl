# This file is a part of Julia. License is MIT: https://julialang.org/license

module APITests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, Test, REPL
import Pkg.Types.PkgError, Pkg.Resolve.ResolverError
using Pkg: stdout_f, stderr_f
using UUIDs

using ..Utils
@testset "Pkg.activate" begin
    isolate() do; cd_tempdir() do tmp
        path = pwd()
        Pkg.activate(".")
        mkdir("Foo")
        cd(mkdir("modules")) do
            Pkg.generate("Foo")
        end
        Pkg.develop(Pkg.PackageSpec(path="modules/Foo")) # to avoid issue #542
        Pkg.activate("Foo") # activate path Foo over deps Foo
        @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
        Pkg.activate(".")
        rm("Foo"; force=true, recursive=true)
        Pkg.activate("Foo") # activate path from developed Foo
        @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
        Pkg.activate(".")
        Pkg.activate("./Foo") # activate empty directory Foo (sidestep the developed Foo)
        @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
        Pkg.activate(".")
        Pkg.activate("Bar") # activate empty directory Bar
        @test Base.active_project() == joinpath(path, "Bar", "Project.toml")
        Pkg.activate(".")
        Pkg.add("Example") # non-deved deps should not be activated
        Pkg.activate("Example")
        @test Base.active_project() == joinpath(path, "Example", "Project.toml")
        Pkg.activate(".")
        cd(mkdir("tests"))
        Pkg.activate("Foo") # activate developed Foo from another directory
        @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
        Pkg.activate() # activate LOAD_PATH project
        @test Base.ACTIVE_PROJECT[] === nothing
    end end
end

include("FakeTerminals.jl")
import .FakeTerminals.FakeTerminal

@testset "Pkg.precompile" begin
    # sequential precompile, depth-first
    isolate() do; cd_tempdir() do tmp
        Pkg.activate(".")
        cd(mkdir("packages")) do
            Pkg.generate("Dep1")
            Pkg.generate("Dep2")
            Pkg.generate("Dep3")
            Pkg.generate("Dep4")
            Pkg.generate("Dep5")
            Pkg.generate("Dep6")
            Pkg.generate("Dep7")
            Pkg.generate("Dep8")
            Pkg.generate("NoVersion")
            open(joinpath("NoVersion","Project.toml"), "w") do io
                write(io, "name = \"NoVersion\"\nuuid = \"$(UUIDs.uuid4())\"")
            end
            Pkg.generate("BrokenDep")
            open(joinpath("BrokenDep","src","BrokenDep.jl"), "w") do io
                write(io, "module BrokenDep\nerror()\nend")
            end
            Pkg.generate("TrailingTaskDep")
            open(joinpath("TrailingTaskDep","src","TrailingTaskDep.jl"), "w") do io
                write(io, """
                module TrailingTaskDep
                println(stderr, "waiting for IO to finish") # pretend to be a warning
                sleep(2)
                end""")
            end
            Pkg.generate("SlowPrecompile")
            open(joinpath("SlowPrecompile","src","SlowPrecompile.jl"), "w") do io
                write(io, """
                module SlowPrecompile
                sleep(10)
                end""")
            end
        end
        Pkg.develop(Pkg.PackageSpec(path="packages/Dep1"))

        Pkg.activate("Dep1")
        Pkg.develop(Pkg.PackageSpec(path="packages/Dep2"))
        Pkg.activate("Dep2")
        Pkg.develop(Pkg.PackageSpec(path="packages/Dep3"))

        Pkg.activate(".")
        Pkg.resolve()
        Pkg.precompile()

        iob = IOBuffer()
        ENV["JULIA_PKG_PRECOMPILE_AUTO"]=1
        @info "Auto precompilation enabled"
        Pkg.develop(Pkg.PackageSpec(path="packages/Dep4"))
        Pkg.develop(Pkg.PackageSpec(path="packages/NoVersion")) # a package with no version number
        Pkg.build(io=iob) # should trigger auto-precomp
        @test occursin("Precompiling", String(take!(iob)))
        Pkg.precompile(io=iob)
        @test !occursin("Precompiling", String(take!(iob))) # test that the previous precompile was a no-op

        Pkg.precompile("Dep4", io=iob)
        @test !occursin("Precompiling", String(take!(iob))) # should be a no-op
        Pkg.precompile(["Dep4", "NoVersion"], io=iob)
        @test !occursin("Precompiling", String(take!(iob))) # should be a no-op

        Pkg.precompile(Pkg.PackageSpec(name="Dep4"))
        @test !occursin("Precompiling", String(take!(iob))) # should be a no-op
        Pkg.precompile([Pkg.PackageSpec(name="Dep4"), Pkg.PackageSpec(name="NoVersion")])
        @test !occursin("Precompiling", String(take!(iob))) # should be a no-op

        ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0
        @info "Auto precompilation disabled"
        Pkg.develop(Pkg.PackageSpec(path="packages/Dep5"))
        Pkg.precompile(io=iob)
        @test occursin("Precompiling", String(take!(iob)))

        ENV["JULIA_PKG_PRECOMPILE_AUTO"]=1
        Pkg.develop(Pkg.PackageSpec(path="packages/BrokenDep"))
        Pkg.build(io=iob) # should trigger auto-precomp and soft-error
        @test occursin("Precompiling", String(take!(iob)))

        ptoml = joinpath("packages","BrokenDep","Project.toml")
        lines = readlines(ptoml)
        open(joinpath("packages","BrokenDep","src","BrokenDep.jl"), "w") do io
            write(io, "module BrokenDep\n\nend") # remove error
        end
        open(ptoml, "w") do io
            for line in lines
                if startswith(line, "version = \"0.1.0\"")
                    println(io, replace(line, "version = \"0.1.0\"" => "version = \"0.1.1\"", count=1)) # up version
                else
                    println(io, line)
                end
            end
        end
        Pkg.update("BrokenDep") # should trigger auto-precomp including the fixed BrokenDep
        Pkg.precompile(io=iob)
        @test !occursin("Precompiling", String(take!(iob))) # test that the previous precompile was a no-op

        # https://github.com/JuliaLang/Pkg.jl/pull/2142
        Pkg.build(; verbose=true)

        @testset "timing mode" begin
            iob = IOBuffer()
            Pkg.develop(Pkg.PackageSpec(path="packages/Dep6"))
            Pkg.precompile(io=iob, timing=true)
            str = String(take!(iob))
            @test occursin("Precompiling", str)
            @test occursin(" ms", str)
            @test occursin("Dep6", str)
            Pkg.precompile(io=iob)
            @test !occursin("Precompiling", String(take!(iob))) # test that the previous precompile was a no-op
        end

        @testset "instantiate" begin
            iob = IOBuffer()
            Pkg.activate("packages/Dep7")
            Pkg.resolve()
            @test isfile("packages/Dep7/Project.toml")
            @test isfile("packages/Dep7/Manifest.toml")
            Pkg.instantiate(io=iob) # with a Project.toml and Manifest.toml
            @test occursin("Precompiling", String(take!(iob)))

            Pkg.activate("packages/Dep8")
            @test isfile("packages/Dep8/Project.toml")
            @test !isfile("packages/Dep8/Manifest.toml")
            Pkg.instantiate(io=iob) # with only a Project.toml
            @test occursin("Precompiling", String(take!(iob)))
        end

        ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

        @testset "waiting for trailing tasks" begin
            Pkg.activate("packages/TrailingTaskDep")
            iob = IOBuffer()
            Pkg.precompile(io=iob)
            str = String(take!(iob))
            @test occursin("Precompiling", str)
            @test occursin("Waiting for background task / IO / timer.", str)
        end

        @testset "pidlocked precompile" begin
            proj = joinpath(pwd(), "packages", "SlowPrecompile")
            cmd = addenv(`$(Base.julia_cmd()) --color=no --startup-file=no --project="$(pkgdir(Pkg))" -e "
                using Pkg
                Pkg.activate(\"$(escape_string(proj))\")
                Pkg.precompile()
            "`,
                    "JULIA_PKG_PRECOMPILE_AUTO" => "0")
            iob1 = IOBuffer()
            iob2 = IOBuffer()
            try
                Base.Experimental.@sync begin
                    @async run(pipeline(cmd, stderr=iob1, stdout=iob1))
                    @async run(pipeline(cmd, stderr=iob2, stdout=iob2))
                end
            catch
                println("pidlocked precompile tests failed:")
                println("process 1:\n", String(take!(iob1)))
                println("process 2:\n", String(take!(iob2)))
                rethrow()
            end
            s1 = String(take!(iob1))
            s2 = String(take!(iob2))
            @test occursin("Precompiling", s1)
            @test occursin("Precompiling", s2)
            @test any(contains("Being precompiled by another process (pid: "), (s1, s2))
        end

    end end
    # ignoring circular deps, to avoid deadlock
    isolate() do; cd_tempdir() do tmp
        Pkg.activate(".")
        cd(mkdir("packages")) do
            Pkg.generate("CircularDep1")
            Pkg.generate("CircularDep2")
            Pkg.generate("CircularDep3")
        end
        Pkg.develop(Pkg.PackageSpec(path="packages/CircularDep1"))
        Pkg.develop(Pkg.PackageSpec(path="packages/CircularDep2"))
        Pkg.develop(Pkg.PackageSpec(path="packages/CircularDep3"))

        Pkg.activate("CircularDep1")
        Pkg.develop(Pkg.PackageSpec(path="packages/CircularDep2"))
        Pkg.activate("CircularDep2")
        Pkg.develop(Pkg.PackageSpec(path="packages/CircularDep3"))
        Pkg.activate("CircularDep3")
        Pkg.develop(Pkg.PackageSpec(path="packages/CircularDep1"))

        Pkg.activate(".")
        Pkg.resolve()

        ## Tests when circularity is in dependencies
        @test_logs (:warn, r"Circular dependency detected") Pkg.precompile()

        ## Tests when circularity goes through the active project
        Pkg.activate("CircularDep1")
        Pkg.resolve() # necessary because resolving in `Pkg.precompile` has been removed
        @test_logs (:warn, r"Circular dependency detected") Pkg.precompile()
        Pkg.activate(".")
        Pkg.activate("CircularDep2")
        Pkg.resolve() # necessary because resolving in `Pkg.precompile` has been removed
        @test_logs (:warn, r"Circular dependency detected") Pkg.precompile()
        Pkg.activate(".")
        Pkg.activate("CircularDep3")
        Pkg.resolve() # necessary because resolving in `Pkg.precompile` has been removed
        @test_logs (:warn, r"Circular dependency detected") Pkg.precompile()

        Pkg.activate(temp=true)
        Pkg.precompile() # precompile an empty env should be a no-op
        # TODO: Reenable
        #@test_throws ErrorException Pkg.precompile("DoesNotExist") # fail to find a nonexistant dep in an empty env

        Pkg.add("Random")
        #@test_throws ErrorException Pkg.precompile("DoesNotExist")
        Pkg.precompile() # should be a no-op
    end end
end

@testset "Pkg.API.check_package_name: Error message if package name ends in .jl" begin
    @test_throws Pkg.Types.PkgError("`Example.jl` is not a valid package name. Perhaps you meant `Example`") Pkg.API.check_package_name("Example.jl")
end

@testset "issue #2587, PR #2589: `Pkg.PackageSpec` accepts `Union{UUID, AbstractString, Nothing}` for `uuid`" begin
    @testset begin
        xs = [
            Pkg.PackageSpec(uuid = Base.UUID(0)),
            Pkg.PackageSpec(uuid = Base.UUID("00000000-0000-0000-0000-000000000000")),
            Pkg.PackageSpec(uuid = "00000000-0000-0000-0000-000000000000"),
            Pkg.PackageSpec(uuid = strip("00000000-0000-0000-0000-000000000000")), # `strip` returns a `SubString{String}`, which is an `AbstractString` but is not a `String`
        ]
        for x in xs
            @test x isa Pkg.PackageSpec
            @test x.uuid isa Base.UUID
            @test x.uuid == Base.UUID(0)
        end
    end

    @testset begin
        xs = [
            Pkg.PackageSpec(),
            Pkg.PackageSpec(uuid = nothing),
        ]
        for x in xs
            @test x isa Pkg.PackageSpec
            @test x.uuid === nothing
        end
    end
end

@testset "set number of concurrent requests" begin
    @test Pkg.Types.num_concurrent_downloads() == 8
    withenv("JULIA_PKG_CONCURRENT_DOWNLOADS"=>"5") do
        @test Pkg.Types.num_concurrent_downloads() == 5
    end
    withenv("JULIA_PKG_CONCURRENT_DOWNLOADS"=>"0") do
        @test_throws ErrorException Pkg.Types.num_concurrent_downloads()
    end
end

@testset "`[compat]` entries for `julia`" begin
    isolate(loaded_depot=true) do; mktempdir() do tempdir
        pathf = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "FarFuture"))
        pathp = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "FarPast"))
        @test_throws "julia version requirement from Project.toml's compat section not satisfied for package" Pkg.add(path=pathf)
        @test_throws "julia version requirement from Project.toml's compat section not satisfied for package" Pkg.add(path=pathp)
    end end
end

@testset "allow_reresolve parameter" begin
    isolate(loaded_depot=false) do; mktempdir() do tempdir
        Pkg.Registry.add(url = "https://github.com/JuliaRegistries/Test")
        # AllowReresolveTest has Example v0.5.1 which is yanked in the test registry.
        test_dir = joinpath(tempdir, "AllowReresolveTest")

        # Test that we can build and test with allow_reresolve=true
        copy_test_package(tempdir, "AllowReresolveTest")
        Pkg.activate(joinpath(tempdir, "AllowReresolveTest"))
        @test Pkg.build(; allow_reresolve=true) == nothing

        rm(test_dir, force=true, recursive=true)
        copy_test_package(tempdir, "AllowReresolveTest")
        Pkg.activate(joinpath(tempdir, "AllowReresolveTest"))
        @test Pkg.test(; allow_reresolve=true) == nothing

        # Test that allow_reresolve=false fails with the broken manifest
        rm(test_dir, force=true, recursive=true)
        copy_test_package(tempdir, "AllowReresolveTest")
        Pkg.activate(joinpath(tempdir, "AllowReresolveTest"))
        @test_throws Pkg.Resolve.ResolverError Pkg.build(; allow_reresolve=false)

        rm(test_dir, force=true, recursive=true)
        copy_test_package(tempdir, "AllowReresolveTest")
        Pkg.activate(joinpath(tempdir, "AllowReresolveTest"))
        @test_throws Pkg.Resolve.ResolverError Pkg.test(; allow_reresolve=false)
    end end
end

end # module APITests
