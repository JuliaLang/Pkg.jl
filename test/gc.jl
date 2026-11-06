module GCTests

using Test, UUIDs, Dates
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
        # `du` reports what `gc` would free without deleting anything
        io = IOBuffer()
        Pkg.du(; io)
        out = String(take!(io))
        @test occursin("compiled", out)
        @test occursin("[this Julia]", out)
        @test occursin("to free", out)
        @test length(cachefiles("B")) == 1
        Pkg.gc()
        @test cachefiles("A") == [junk]
        @test isempty(cachefiles("B"))
        @test isempty(cachefiles("C"))
        @test !isdir(joinpath(compiled, "B")) # empty directories are pruned
    end
end

@testset "Pkg.gc: caches of Julia builds that are gone" begin
    temp_pkg_dir() do project_path
        CC = Pkg.CompiledCaches
        Pkg.activate(project_path)
        Pkg.add("Example")
        # using an environment records the running build with its system image
        usage_file = joinpath(Pkg.depots1(), "logs", "julia_usage.toml")
        @test isfile(usage_file)
        running = Base.module_build_id(Base)
        usage = TOML.parsefile(usage_file)
        entry = only(usage[string(running; base = 16, pad = 32)])
        @test entry["image"] == abspath(unsafe_string(Base.JLOptions().image_file))
        @test entry["version"] == string(VERSION)

        # an image that is still the recorded file is installed; one that is missing or was
        # replaced is gone; the running build is never gone
        image = tempname()
        write(image, "image")
        st = stat(image)
        installed, replaced, missing_image = UInt128(1), UInt128(2), UInt128(3)
        logentry(path, mtime, size) = [Dict{String, Any}("image" => path, "image_mtime" => mtime, "image_size" => size)]
        usage[string(installed; base = 16, pad = 32)] = logentry(image, st.mtime, st.size)
        usage[string(replaced; base = 16, pad = 32)] = logentry(image, st.mtime - 10, st.size)
        usage[string(missing_image; base = 16, pad = 32)] = logentry(image * "-missing", st.mtime, st.size)
        usage[string(running; base = 16, pad = 32)] = logentry(image * "-missing", 0.0, 0)
        open(io -> TOML.print(io, usage), usage_file, "w")
        builds = CC.julia_builds(Pkg.depots())
        @test builds[installed] == CC.BUILD_INSTALLED
        @test builds[replaced] == CC.BUILD_GONE
        @test builds[missing_image] == CC.BUILD_GONE
        @test builds[running] == CC.BUILD_RUNNING

        # rule 0: the caches of a build that is gone are dead, even those of stdlibs, and
        # those of builds that are installed or were never recorded are not judged by it
        base = Base.PkgId(nothing, "Base")
        header(build, entry) = CC.CacheHeader("x.ji", VERSION, "", Pair{Base.PkgId, UInt128}[], [base => build], entry)
        stdlib_entry = joinpath(Sys.STDLIB, "Random", "src", "Random.jl")
        headers = [header(replaced, stdlib_entry), header(missing_image, stdlib_entry), header(installed, stdlib_entry), header(UInt128(4), stdlib_entry)]
        @test CC.dead_cachefiles(headers, fill(true, 4), Pkg.depots(), String[], builds) == [1, 2]
        # but only in depots that are collected
        @test CC.dead_cachefiles(headers, [false, true, true, true], Pkg.depots(), String[], builds) == [2]

        # builds that were never recorded: a prerelease that compiled nothing for a while,
        # while another build of the same minor version did, is superseded
        now = time()
        day = 24 * 60 * 60.0
        vheader(build, v) = CC.CacheHeader("x.ji", v, "", Pair{Base.PkgId, UInt128}[], [base => build], stdlib_entry)
        old_nightly, new_nightly, only_alpha, logged_nightly, old_patch, new_patch =
            (UInt128(10 + i) for i in 1:6)
        headers = [
            vheader(old_nightly, v"1.20.0-DEV.100"),     # 1: old, superseded by new_nightly
            vheader(new_nightly, v"1.20.0-DEV.200"),
            vheader(only_alpha, v"1.21.0-alpha1"),       # 3: old, but the only 1.21 build
            vheader(logged_nightly, v"1.20.0-DEV.50"),   # 4: old, but recorded as installed
            vheader(old_patch, v"1.18.1"),               # 5: old, superseded by 1.18.2
            vheader(new_patch, v"1.18.2"),
        ]
        mtimes = [now - 30day, now - 1day, now - 100day, now - 60day, now - 40day, now - 2day]
        builds = Dict(logged_nightly => CC.BUILD_INSTALLED)
        CC.superseded_builds!(builds, headers, mtimes; now)
        @test builds == Dict(
            old_nightly => CC.BUILD_SUPERSEDED, old_patch => CC.BUILD_SUPERSEDED,
            logged_nightly => CC.BUILD_INSTALLED,
        )
        @test CC.dead_cachefiles(headers, fill(true, length(headers)), Pkg.depots(), String[], builds) == [1, 5]

        # the Julia of an installed app is recorded without running the app
        app_julia = joinpath(Sys.BINDIR, Base.julia_exename())
        mkpath(joinpath(Pkg.depots1(), "environments", "apps"))
        write(
            joinpath(Pkg.depots1(), "environments", "apps", "AppManifest.toml"), """
            [[deps.SomeApp]]
            uuid = "$(UUID(UInt128(42)))"
            [deps.SomeApp.apps.someapp]
            julia_command = "$(escape_string(app_julia))"
            submodule = ""
            """
        )
        rm(usage_file)
        Pkg.Types.record_installed_julia_usage(Pkg.depots())
        @test haskey(TOML.parsefile(usage_file), string(running; base = 16, pad = 32))

        # the Julias installed with juliaup: versions and download channels by their path
        # relative to the juliaup directory, linked channels by their command
        juliaup = mktempdir()
        write(
            joinpath(juliaup, "juliaup.json"), """
            {"Default": "release",
             "InstalledVersions": {"1.99.0+0": {"Path": "./julia-1.99.0", "BinaryPath": "./julia-1.99.0/bin/julia"}},
             "InstalledChannels": {
               "release": {"Version": "1.99.0+0"},
               "nightly": {"Path": "./julia-nightly", "Version": "1.100.0-DEV", "BinaryPath": "./julia-nightly/bin/julia"},
               "dev": {"Command": "/opt/julia/bin/julia", "Args": []}}}
            """
        )
        julias = Pkg.Types.juliaup_julias(juliaup)
        @test joinpath(juliaup, "julia-1.99.0", "bin", "julia") in julias
        @test joinpath(juliaup, "julia-nightly", "bin", "julia") in julias
        @test "/opt/julia/bin/julia" in julias
        # older juliaup records only the `Path` of an installation
        write(joinpath(juliaup, "juliaup.json"), """{"InstalledVersions": {"1.98.0+0": {"Path": "./julia-1.98.0"}}}""")
        @test Pkg.Types.juliaup_julias(juliaup) == [joinpath(juliaup, "julia-1.98.0", "bin", Base.julia_exename())]
    end
end

@testset "Pkg.gc: planning does not depend on condensing the usage logs" begin
    temp_pkg_dir() do project_path
        # a scratch space whose only parent project is gone
        space = joinpath(Pkg.depots1(), "scratchspaces", string(UUID(UInt128(7))), "space")
        mkpath(space)
        usage_file = joinpath(Pkg.depots1(), "logs", "scratch_usage.toml")
        mkpath(dirname(usage_file))
        open(usage_file, "w") do io
            TOML.print(io, Dict(space => [Dict("time" => Dates.now(), "parent_projects" => [joinpath(project_path, "gone", "Project.toml")])]))
        end
        dry = Pkg.API.gc_plan([Pkg.depots1()]; condense_usage = false)
        @test dry.spaces == [space]
        @test isfile(usage_file) && haskey(TOML.parsefile(usage_file), space)  # left alone
        @test Pkg.API.gc_plan([Pkg.depots1()]; condense_usage = true).spaces == dry.spaces
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
