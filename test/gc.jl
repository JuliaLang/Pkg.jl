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
        source = Base.locate_package(Base.PkgId(TEST_PKG.uuid, TEST_PKG.name))
        @test_throws SystemError open(source, "w") do io end  # check read-only
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

    @testset "usage is not rewritten for every EnvCache (#4082)" begin
        temp_pkg_dir() do project_path
            Pkg.activate(project_path)
            Pkg.add("Random")
            usage_file = joinpath(Pkg.logdir(), "manifest_usage.toml")
            Pkg.dependencies()
            @test isfile(usage_file)
            rm(usage_file)
            Pkg.dependencies()
            @test !isfile(usage_file)
        end
    end

    @testset "failing to write the usage file only warns (#3453)" begin
        temp_pkg_dir() do project_path
            Pkg.activate(project_path)
            Pkg.add("Random")
            manifest = joinpath(project_path, "Manifest.toml")
            # A file in place of the log directory makes taking the usage file lock fail
            rm(Pkg.logdir(); recursive = true)
            touch(Pkg.logdir())
            @test_logs (:warn, r"Failed to record usage") Pkg.Types.write_env_usage(manifest, "manifest_usage.toml")
            rm(Pkg.logdir())
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

@testset "Pkg.gc: precompilation cache files that can never be loaded" begin
    temp_pkg_dir() do project_path
        CC = Pkg.CompiledCaches
        # C depends on B, which depends on A
        uuid_a, uuid_b, uuid_c = (UUID("a3f6f8e8-0b8e-4b8e-9d6c-2d1c6e6a000$i") for i in 1:3)
        pkgs_dir = mktempdir()
        for (name, uuid, deps) in (("A", uuid_a, ""), ("B", uuid_b, "A = \"$uuid_a\""), ("C", uuid_c, "B = \"$uuid_b\""))
            mkpath(joinpath(pkgs_dir, name, "src"))
            write(
                joinpath(pkgs_dir, name, "Project.toml"),
                "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n[deps]\n$deps\n"
            )
            using_line = name == "B" ? "using A\n" : name == "C" ? "using B\n" : ""
            write(joinpath(pkgs_dir, name, "src", "$name.jl"), "module $name\n$(using_line)f() = 1\nend\n")
        end
        compiled = joinpath(Pkg.depots1(), "compiled", "v$(VERSION.major).$(VERSION.minor)")
        junk = joinpath(compiled, "A", "junk.ji")
        cachefiles(name) = isdir(joinpath(compiled, name)) ?
            filter(endswith(".ji"), readdir(joinpath(compiled, name); join = true)) : String[]
        function setup()
            Pkg.activate(project_path)
            Pkg.develop([Pkg.PackageSpec(path = joinpath(pkgs_dir, name)) for name in ("A", "B", "C")])
            Pkg.precompile()
            @test count(!=(junk), cachefiles("A")) == 1
            @test length(cachefiles("B")) == 1
            @test length(cachefiles("C")) == 1
        end
        setup()

        @testset "headers are read like Base reads them" begin
            for depot in Pkg.depots(), file in CC.cachefiles(depot)
                h = CC.read_cache_header(file)
                @test h !== nothing
                modules, (includes, _, _), required = Base.parse_cache_header(file)
                checksum = open(Base.isvalid_cache_header, file)
                @test h.modules == [id => (UInt128(checksum) << 64) | (b % UInt64) for (id, b) in modules]
                @test h.required == required
            end
        end

        # A file that is not a cache file is left alone
        write(junk, "not a cache file")
        @test CC.read_cache_header(junk) === nothing

        # Nothing is deleted while everything can be loaded
        Pkg.gc()
        @test length(cachefiles("A")) == 2 # including the junk
        @test length(cachefiles("B")) == 1
        @test length(cachefiles("C")) == 1

        # A dependency's cache file is gone, as when Base evicted it: B can not load, and
        # then neither can C
        for file in cachefiles("A")
            file == junk || rm.(CC.companion_files(file); recursive = true)
        end
        Pkg.gc()
        @test isempty(cachefiles("B"))
        @test isempty(cachefiles("C"))
        @test cachefiles("A") == [junk]

        # A's source is gone: A's cache and, in turn, B's are dead
        setup()
        rm(joinpath(pkgs_dir, "A"); recursive = true)
        Pkg.gc()
        @test cachefiles("A") == [junk]
        @test isempty(cachefiles("B"))
        @test isempty(cachefiles("C"))
        @test !isdir(joinpath(compiled, "B")) # empty directories are pruned
    end
end

if isdefined(Base.Filesystem, :delayed_delete_ref)
    @testset "Pkg.gc for delayed deletes" begin
        # a temporary depot, so that `gc` does not collect the depot the tests run with
        temp_pkg_dir() do root
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
