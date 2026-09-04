module GCTests

using Test, UUIDs
import ..Pkg
using TOML
using ..Utils

@testset "gc: unused packages and clones are reaped" begin
    temp_pkg_dir() do project_path
        Pkg.activate(project_path)
        Pkg.add(TEST_PKG.name)
        @test isinstalled(TEST_PKG)
        @eval import $(Symbol(TEST_PKG.name))
        @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
        Pkg.rm(TEST_PKG.name)
        @test !isinstalled(TEST_PKG)
        pkgdir = joinpath(Pkg.depots1(), "packages")

        # Test that unused packages are reaped
        Pkg.gc()
        @test isempty(filter(x -> x != "CACHEDIR.TAG", readdir(pkgdir)))

        clonedir = joinpath(Pkg.depots1(), "clones")
        Pkg.add(Pkg.PackageSpec(name = TEST_PKG.name, rev = "master"))
        @test !isempty(readdir(clonedir))
        Pkg.rm(TEST_PKG.name)
        # Test that unused repos are also reaped
        Pkg.gc()
        @test isempty(filter(x -> x != "CACHEDIR.TAG", readdir(clonedir)))
    end
end

@testset "manifest usage log" begin
    temp_pkg_dir() do project_path
        Pkg.activate(project_path)
        Pkg.add("Example")
        usage = TOML.parsefile(joinpath(Pkg.logdir(), "manifest_usage.toml"))
        manifest = Pkg.safe_realpath(joinpath(project_path, "Manifest.toml"))
        @test any(x -> startswith(x, manifest), keys(usage))
    end

    @testset "parsing malformed usage file" begin
        temp_pkg_dir() do project_path
            # first populate the usage files
            Pkg.activate(temp = true)
            Pkg.add("Random")

            man_usage_file = joinpath(Pkg.logdir(), "manifest_usage.toml")
            man_usage = TOML.parsefile(man_usage_file)
            last_entry = man_usage[last(collect(keys(man_usage)))][1]
            @test haskey(last_entry, "time")
            empty!(last_entry) # remove the "time" entry
            @test haskey(last_entry, "time") == false
            open(io -> TOML.print(io, man_usage), man_usage_file, "w")

            # and now these should not error when they update the manifest usage file
            Pkg.activate(temp = true)
            Pkg.add("Random")
        end
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

if isdefined(Base.Filesystem, :delayed_delete_ref)
    @testset "Pkg.gc for delayed deletes" begin
        mktempdir() do root
            with_temp_env(root) do
                dir = joinpath(root, "julia_delayed_deletes")
                mkdir(dir)
                testfile = joinpath(dir, "testfile")
                write(testfile, "foo bar")
                delayed_delete_ref_path = Base.Filesystem.delayed_delete_ref()
                mkpath(delayed_delete_ref_path)
                ref = tempname(delayed_delete_ref_path; cleanup = false)
                write(ref, testfile)
                @test isfile(testfile)
                Pkg.gc()
                @test !ispath(testfile)
                @test !ispath(dir)
                @test !ispath(ref)
                @test !ispath(delayed_delete_ref_path) || !isempty(readdir(delayed_delete_ref_path))
            end
        end
    end
end

end # module
