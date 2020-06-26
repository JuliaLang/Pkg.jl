module ArtifactTests
import ..Pkg # ensure we are using the correct Pkg

using Test, Random, Pkg.Artifacts, Pkg.BinaryPlatforms, Pkg.PlatformEngines
import Pkg.Artifacts: pack_platform!, unpack_platform, with_artifacts_directory, ensure_all_artifacts_installed, extract_all_hashes
using Pkg.TOML, Dates
import Base: SHA1

using ..Utils

# Helper function to create an artifact, then chmod() the whole thing to 0o644.  This is
# important to keep hashes stable across platforms that have different umasks, changing
# the permissions within a tree hash, breaking our tests.
function create_artifact_chmod(f::Function)
    create_artifact() do path
        f(path)

        # Change all files to have 644 permissions, leave directories alone
        for (root, dirs, files) in walkdir(path)
            for f in files
                f = joinpath(root, f)
                islink(f) || chmod(f, 0o644)
            end
        end
    end
end

@testset "Serialization Tools" begin
    # First, some basic tests
    meta = Dict()
    pack_platform!(meta, Linux(:i686))
    @test meta["os"] == "linux"
    @test meta["arch"] == "i686"
    @test meta["libc"] == "glibc"

    meta = Dict()
    pack_platform!(meta, Linux(:armv7l; libc=:musl))
    @test meta["os"] == "linux"
    @test meta["arch"] == "armv7l"
    @test meta["libc"] == "musl"

    meta = Dict()
    pack_platform!(meta, Windows(:x86_64; compiler_abi=CompilerABI(;libgfortran_version=v"3")))
    @test meta["os"] == "windows"
    @test meta["arch"] == "x86_64"
    @test meta["libgfortran_version"] == "3.0.0"

    meta = Dict()
    pack_platform!(meta, MacOS(:x86_64))
    @test meta == Dict("os" => "macos", "arch" => "x86_64")

    # Next, fuzz it out!  Ensure that we exactly reconstruct our platforms!
    platforms = Platform[]
    for libgfortran_version in (v"3", v"4", v"5", nothing),
        libstdcxx_version in (v"3.4.11", v"3.4.19", nothing),
        cxxstring_abi in (:cxx03, :cxx11, nothing)

        cabi = CompilerABI(;
            libgfortran_version=libgfortran_version,
            libstdcxx_version=libstdcxx_version,
            cxxstring_abi=cxxstring_abi,
        )

        for arch in (:x86_64, :i686, :aarch64, :armv7l),
            libc in (:glibc, :musl)

            push!(platforms, Linux(arch; libc=libc, compiler_abi=cabi))
        end
        push!(platforms, Windows(:x86_64; compiler_abi=cabi))
        push!(platforms, Windows(:i686; compiler_abi=cabi))
        push!(platforms, MacOS(:x86_64; compiler_abi=cabi))
        push!(platforms, FreeBSD(:x86_64; compiler_abi=cabi))
    end

    for p in platforms
        meta = Dict()
        pack_platform!(meta, p)
        @test unpack_platform(meta, "foo", "<in-memory-Artifacts.toml>") == p

        # Test that some things raise warnings
        bad_meta = copy(meta)
        delete!(bad_meta, "os")
        @test_logs (:error, r"Invalid artifacts file") unpack_platform(bad_meta, "foo", "")

        bad_meta = copy(meta)
        delete!(bad_meta, "arch")
        @test_logs (:error, r"Invalid artifacts file") unpack_platform(bad_meta, "foo", "")
    end
end

@testset "Artifact Creation" begin
    # We're going to ensure that our artifact creation does in fact give git-tree-sha1's.
    creators = [
        # First test the empty artifact
        (path -> begin
            # add no contents
        end, "4b825dc642cb6eb9a060e54bf8d69288fbee4904"),

        # Next test creating a single file
        (path -> begin
            open(joinpath(path, "foo"), "w") do io
                print(io, "Hello, world!")
            end
        end, "339aad93c0f854604248ea3b7c5b7edea20625a9"),

        # Next we will test creating multiple files
        (path -> begin
            open(joinpath(path, "foo1"), "w") do io
                print(io, "Hello")
            end
            open(joinpath(path, "foo2"), "w") do io
                print(io, "world!")
            end
        end, "98cda294312216b19e2a973e9c291c0f5181c98c"),

        # Finally, we will have nested directories and all that good stuff
        (path -> begin
            mkpath(joinpath(path, "bar", "bar"))
            open(joinpath(path, "bar", "bar", "foo1"), "w") do io
                print(io, "Hello")
            end
            open(joinpath(path, "bar", "foo2"), "w") do io
                print(io, "world!")
            end
            open(joinpath(path, "foo3"), "w") do io
                print(io, "baz!")
            end

            # Empty directories do nothing to effect the hash, so we create one with a
            # random name to prove that it does not get hashed into the rest.  Also, it
            # turns out that life is cxomplex enough that we need to test the nested
            # empty directories case as well.
            rand_dir = joinpath(path, Random.randstring(8), "inner")
            mkpath(rand_dir)

            # Symlinks are not followed, even if they point to directories
            symlink("foo3", joinpath(path, "foo3_link"))
            symlink("../bar", joinpath(path, "bar", "infinite_link"))
        end, "86a1ce580587d5851fdfa841aeb3c8d55663f6f9"),
    ]

    # Enable the following code snippet to figure out the correct gitsha's:
    if false
        for (creator, blah) in creators
            mktempdir() do path
                creator(path)
                for (root, dirs, files) in walkdir(path)
                    for f in files
                        chmod(joinpath(root, f), 0o644)
                    end
                end
                cd(path) do
                    read(`git init .`)
                    read(`git add . `)
                    read(`git commit --allow-empty -m "foo"`)
                    hash = chomp(String(read(`git log -1 --pretty='%T' HEAD`)))
                    println(hash)
                end
            end
        end
    end

    for (creator, known_hash) in creators
        # Create artifact
        hash = create_artifact_chmod(creator)

        # Ensure it hashes to the correct gitsha:
        @test hash.bytes == hex2bytes(known_hash)

        # Test that we can look it up and that it sits in the right place
        @test basename(dirname(artifact_path(hash))) == "artifacts"
        @test basename(artifact_path(hash)) == known_hash
        @test artifact_exists(hash)

        # Test that the artifact verifies
        if !Sys.iswindows()
            @test verify_artifact(hash)
        end
    end
end

@testset "with_artifacts_directory()" begin
    mktempdir() do art_dir
        with_artifacts_directory(art_dir) do
            hash = create_artifact() do path
                touch(joinpath(path, "foo"))
            end
            @test startswith(artifact_path(hash), art_dir)
        end
    end
end

@testset "Artifacts.toml Utilities" begin
    # First, let's test our ability to find Artifacts.toml files;
    ATS = joinpath(@__DIR__, "test_packages", "ArtifactTOMLSearch")
    test_modules = [
        joinpath(ATS, "pkg.jl") =>  joinpath(ATS, "Artifacts.toml"),
        joinpath(ATS, "sub_module", "pkg.jl") =>  joinpath(ATS, "Artifacts.toml"),
        joinpath(ATS, "sub_package", "pkg.jl") =>  joinpath(ATS, "sub_package", "Artifacts.toml"),
        joinpath(ATS, "julia_artifacts_test", "pkg.jl") =>  joinpath(ATS, "julia_artifacts_test", "JuliaArtifacts.toml"),
        joinpath(@__DIR__, "test_packages", "BasicSandbox", "src", "Foo.jl") => nothing,
    ]
    for (test_src, artifacts_toml) in test_modules
        temp_pkg_dir() do pkg_dir
            # Test that the Artifacts.toml that was found is what we expected
            @test find_artifacts_toml(test_src) == artifacts_toml

            # Load `arty` and check its gitsha
            if artifacts_toml !== nothing
                arty_hash = SHA1("43563e7631a7eafae1f9f8d9d332e3de44ad7239")
                @test artifact_hash("arty", artifacts_toml) == arty_hash

                @test arty_hash in extract_all_hashes(artifacts_toml)

                # Ensure it's installable (we uninstall first, to make sure)
                @test !artifact_exists(arty_hash)

                @test ensure_artifact_installed("arty", artifacts_toml) == artifact_path(arty_hash)
                if !Sys.iswindows()
                    @test verify_artifact(arty_hash)
                end

                # Make sure doing it twice "just works"
                @test ensure_artifact_installed("arty", artifacts_toml) == artifact_path(arty_hash)

                # clean up after thyself
                remove_artifact(arty_hash)
                @test !verify_artifact(arty_hash)
            end
        end
    end

    # Test binding/unbinding
    temp_pkg_dir() do path
        hash = create_artifact() do path
            open(joinpath(path, "foo.txt"), "w") do io
                print(io, "hello, world!")
            end
        end

        # Bind this artifact to something
        artifacts_toml = joinpath(path, "Artifacts.toml")
        @test artifact_hash("foo_txt", artifacts_toml) == nothing
        bind_artifact!(artifacts_toml, "foo_txt", hash)

        # Test that this binding worked
        @test artifact_hash("foo_txt", artifacts_toml) == hash
        @test ensure_artifact_installed("foo_txt", artifacts_toml) == artifact_path(hash)

        # Test that binding caused an entry in the manifest_usage.toml
        usage = Pkg.TOML.parse(String(read(joinpath(Pkg.logdir(), "artifact_usage.toml"))))
        @test any(x -> startswith(x, artifacts_toml), keys(usage))

        # Test that we can overwrite bindings
        hash2 = create_artifact() do path
            open(joinpath(path, "foo.txt"), "w") do io
                print(io, "goodbye, world!")
            end
        end
        @test_throws ErrorException bind_artifact!(artifacts_toml, "foo_txt", hash2)
        @test artifact_hash("foo_txt", artifacts_toml) == hash
        bind_artifact!(artifacts_toml, "foo_txt", hash2; force=true)
        @test artifact_hash("foo_txt", artifacts_toml) == hash2

        # Test that we can un-bind
        unbind_artifact!(artifacts_toml, "foo_txt")
        @test artifact_hash("foo_txt", artifacts_toml) == nothing

        # Test platform-specific binding and providing download_info
        download_info = [
            ("http://google.com/hello_world", "0"^64),
            ("http://microsoft.com/hello_world", "a"^64),
        ]

        # First, test the binding of things with various platforms and overwriting and such works properly
        bind_artifact!(artifacts_toml, "foo_txt", hash; download_info=download_info, platform=Linux(:x86_64))
        @test artifact_hash("foo_txt", artifacts_toml; platform=Linux(:x86_64)) == hash
        @test artifact_hash("foo_txt", artifacts_toml; platform=MacOS()) == nothing
        @test_throws ErrorException bind_artifact!(artifacts_toml, "foo_txt", hash2; download_info=download_info, platform=Linux(:x86_64))
        bind_artifact!(artifacts_toml, "foo_txt", hash2; download_info=download_info, platform=Linux(:x86_64), force=true)
        bind_artifact!(artifacts_toml, "foo_txt", hash; download_info=download_info, platform=Windows(:i686))
        @test artifact_hash("foo_txt", artifacts_toml; platform=Linux(:x86_64)) == hash2
        @test artifact_hash("foo_txt", artifacts_toml; platform=Windows(:i686)) == hash
        @test ensure_artifact_installed("foo_txt", artifacts_toml; platform=Linux(:x86_64)) == artifact_path(hash2)
        @test ensure_artifact_installed("foo_txt", artifacts_toml; platform=Windows(:i686)) == artifact_path(hash)

        # Next, check that we can get the download_info properly:
        meta = artifact_meta("foo_txt", artifacts_toml; platform=Windows(:i686))
        @test meta["download"][1]["url"] == "http://google.com/hello_world"
        @test meta["download"][2]["sha256"] == "a"^64
    end

    # Let's test some known-bad Artifacts.toml files
    badifact_dir = joinpath(@__DIR__, "artifacts", "bad")

    # First, parsing errors
    @test_logs (:error, r"contains no `git-tree-sha1`") artifact_meta("broken_artifact", joinpath(badifact_dir, "no_gitsha.toml"))
    @test_logs (:error, r"malformed, must be array or dict!") artifact_meta("broken_artifact", joinpath(badifact_dir, "not_a_table.toml"))

    # Next, test incorrect download errors
    if !Sys.iswindows()
        mktempdir() do dir
            with_artifacts_directory(dir) do
                @test artifact_meta("broken_artifact", joinpath(badifact_dir, "incorrect_gitsha.toml")) != nothing
                @test_logs (:error, r"Tree Hash Mismatch!") match_mode=:any begin
                    # Only warn on wrong tree hash for now (see Pkg.jl#1885)
                    # @test_throws ErrorException ensure_artifact_installed("broken_artifact", joinpath(badifact_dir, "incorrect_gitsha.toml"))
                    path = ensure_artifact_installed("broken_artifact", joinpath(badifact_dir, "incorrect_gitsha.toml"))
                    @test endswith(path, "0000000000000000000000000000000000000000")
                end
            end
        end
    end

    mktempdir() do dir
        with_artifacts_directory(dir) do
            @test artifact_meta("broken_artifact", joinpath(badifact_dir, "incorrect_sha256.toml")) != nothing
            @test_logs (:error, r"Hash Mismatch!") match_mode=:any begin
                @test_throws ErrorException ensure_artifact_installed("broken_artifact", joinpath(badifact_dir, "incorrect_sha256.toml"))
            end
        end
    end
end


@testset "Artifact archival" begin
    mktempdir() do art_dir
        with_artifacts_directory(art_dir) do
            hash = create_artifact(p -> touch(joinpath(p, "foo")))
            tarball_path = joinpath(art_dir, "foo.tar.gz")
            archive_artifact(hash, tarball_path)
            @test "foo" in list_tarball_files(tarball_path)

            # Test archiving something that doesn't exist fails
            remove_artifact(hash)
            @test_throws ErrorException archive_artifact(hash, tarball_path)
        end
    end
end

@testset "Artifact Usage" begin
    # Do a quick little install of our ArtifactTOMLSearch example
    include(joinpath(@__DIR__, "test_packages", "ArtifactTOMLSearch", "pkg.jl"))
    @test ATSMod.do_test()

    # Don't use `temp_pkg_dir()` here because we need `Pkg.test()` to run in the
    # same package context as the one we're running in right now.  Yes, this pollutes
    # the global artifact namespace and package list, but it should be harmless.
    mktempdir() do project_path
        with_pkg_env(project_path) do
            copy_test_package(project_path, "ArtifactInstallation")
            Pkg.activate(joinpath(project_path))
            add_this_pkg()
            Pkg.add(Pkg.Types.PackageSpec(
                name="ArtifactInstallation",
                uuid=Base.UUID("02111abe-2050-1119-117e-b30112b5bdc4"),
                path=joinpath(project_path, "ArtifactInstallation"),
            ))

            # Run test harness
            Pkg.test("ArtifactInstallation")

            # Also manually do it
            Core.eval(Module(:__anon__), quote
                using ArtifactInstallation
                do_test()
            end)
        end
    end

    # Ensure that `instantiate()` installs artifacts:
    temp_pkg_dir() do project_path
        copy_test_package(project_path, "ArtifactInstallation")
        Pkg.activate(joinpath(project_path, "ArtifactInstallation"))
        add_this_pkg()
        Pkg.instantiate(; verbose=true)

        # Manual test that artifact is installed by instantiate()
        artifacts_toml = joinpath(project_path, "ArtifactInstallation", "Artifacts.toml")
        c_simple_hash = artifact_hash("c_simple", artifacts_toml)
        @test artifact_exists(c_simple_hash)
    end

    # Ensure that porous platform coverage works with ensure_all_installed()
    temp_pkg_dir() do project_path
        copy_test_package(project_path, "ArtifactInstallation")
        artifacts_toml = joinpath(project_path, "ArtifactInstallation", "Artifacts.toml")

        # Install artifacts such that `c_simple` is not installed properly
        # because of the platform we requested, but `socrates` is.
        ensure_all_artifacts_installed(artifacts_toml; platform=Linux(:powerpc64le))

        # Test that c_simple doesn't even show up
        c_simple_hash = artifact_hash("c_simple", artifacts_toml; platform=Linux(:powerpc64le))
        @test c_simple_hash == nothing

        # Test that socrates shows up, but is not installed
        socrates_hash = artifact_hash("socrates", artifacts_toml; platform=Linux(:powerpc64le))
        @test !artifact_exists(socrates_hash)

        # Test that collapse_the_symlink is installed
        cts_hash = artifact_hash("collapse_the_symlink", artifacts_toml; platform=Linux(:powerpc64le))
        @test artifact_exists(cts_hash)
    end
end

@testset "Artifact GC collect delay" begin
    temp_pkg_dir() do tmpdir
        live_hash = create_artifact_chmod() do path
            open(joinpath(path, "README.md"), "w") do io
                print(io, "I will not go quietly into that dark night.")
            end
            open(joinpath(path, "binary.data"), "w") do io
                write(io, rand(UInt8, 1024))
            end
        end
        die_hash = create_artifact_chmod() do path
            open(joinpath(path, "README.md"), "w") do io
                print(io, "Let me sleep!")
            end
            open(joinpath(path, "binary.data"), "w") do io
                write(io, rand(UInt8, 1024))
            end
        end

        # We have created two separate artifacts
        @test live_hash != die_hash

        # Test that artifact_usage.toml does not exist
        usage_path = joinpath(Pkg.logdir(), "artifact_usage.toml")
        @test !isfile(usage_path)

        # We bind them here and now
        artifacts_toml = joinpath(tmpdir, "Artifacts.toml")
        bind_artifact!(artifacts_toml, "live", live_hash)
        bind_artifact!(artifacts_toml, "die", die_hash)

        # Now test that the usage file exists, and contains our Artifacts.toml
        usage = Pkg.TOML.parse(String(read(usage_path)))
        @test any(x -> startswith(x, artifacts_toml), keys(usage))

        # Test that a gc() doesn't remove anything
        @test artifact_exists(live_hash)
        @test artifact_exists(die_hash)
        Pkg.gc()
        @test artifact_exists(live_hash)
        @test artifact_exists(die_hash)

        # Test that unbinding the `die_hash` and running `gc()` again still doesn't
        # remove it, but it does add it to the orphan list
        unbind_artifact!(artifacts_toml, "die")
        Pkg.gc()
        @test artifact_exists(live_hash)
        @test artifact_exists(die_hash)

        orphaned_path = joinpath(Pkg.logdir(), "orphaned.toml")
        orphanage = Pkg.TOML.parse(String(read(orphaned_path)))
        @test any(x -> startswith(x, artifact_path(die_hash)), keys(orphanage))

        # Now, sleep for 0.2 seconds, then gc with a collect delay of 0.1 seconds
        # This should reap the `die_hash` immediately, as it has already been moved to
        # the orphaned list.
        sleep(0.2)
        Pkg.gc(;collect_delay=Millisecond(100))
        @test artifact_exists(live_hash)
        @test !artifact_exists(die_hash)

        # die_hash should still be listed within the orphan list, but one more gc() will
        # remove it; this is intentional and allows for robust removal scheduling.
        orphanage = Pkg.TOML.parse(String(read(orphaned_path)))
        @test any(x -> startswith(x, artifact_path(die_hash)), keys(orphanage))
        Pkg.gc()
        orphanage = Pkg.TOML.parse(String(read(orphaned_path)))
        @test !any(x -> startswith(x, artifact_path(die_hash)), keys(orphanage))

        # Next, unbind the live_hash, then run with collect_delay=0, and ensure that
        # things are cleaned up immediately.
        unbind_artifact!(artifacts_toml, "live")
        Pkg.gc(;collect_delay=Second(0))
        @test !artifact_exists(live_hash)
        @test !artifact_exists(die_hash)
    end
end

@testset "Override.toml" begin
    # We are going to test artifact overrides by creating an overlapping set of depots,
    # each with some artifacts installed within, then checking via things like
    # `artifact_path()` to ensure that our overrides are actually working.

    mktempdir() do depot_container
        depot1 = joinpath(depot_container, "depot1")
        depot2 = joinpath(depot_container, "depot2")
        depot3 = joinpath(depot_container, "depot3")

        make_foo(dir) = open(io -> print(io, "foo"), joinpath(dir, "foo"), "w")
        make_bar(dir) = open(io -> print(io, "bar"), joinpath(dir, "bar"), "w")
        make_baz(dir) = open(io -> print(io, "baz"), joinpath(dir, "baz"), "w")

        foo_hash = SHA1("2f42e2c1c1afd4ef8c66a2aaba5d5e1baddcab33")
        bar_hash = SHA1("64d0b4f8d9c004b862b38c4acfbd74988226995c")
        baz_hash = SHA1("087d8c93bff2f2b05f016bcd6ec653c8def76568")

        # First, create artifacts in each depot, with some overlap
        with_artifacts_directory(joinpath(depot3, "artifacts")) do
            @test create_artifact_chmod(make_foo) == foo_hash
            @test create_artifact_chmod(make_bar) == bar_hash
            @test create_artifact_chmod(make_baz) == baz_hash
        end
        with_artifacts_directory(joinpath(depot2, "artifacts")) do
            @test create_artifact_chmod(make_bar) == bar_hash
            @test create_artifact_chmod(make_baz) == baz_hash
        end
        with_artifacts_directory(joinpath(depot1, "artifacts")) do
            @test create_artifact_chmod(make_baz) == baz_hash
        end

        # Next, set up our depot path, with `depot1` as the "innermost" depot.
        old_depot_path = DEPOT_PATH
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, [depot1, depot2, depot3])

        # First sanity check; does our depot path searching code actually work properly?
        @test startswith(artifact_path(foo_hash), depot3)
        @test startswith(artifact_path(bar_hash), depot2)
        @test startswith(artifact_path(baz_hash), depot1)

        # Our `test/test_packages/ArtifactOverrideLoading` package contains some artifacts
        # that will not load unless they are properly overridden
        aol_uuid = Base.UUID("7b879065-7f74-5fa4-bdd5-9b7a15df8941")

        # Create an arbitrary absolute path for `barty`
        barty_override_path = abspath(joinpath(depot_container, "a_wild_barty_appears"))
        mkpath(barty_override_path)

        # Next, let's start spitting out some Overrides.toml files.  We'll make
        # one in `depot2`, then eventually create one in `depot1` to override these
        # overrides!
        open(joinpath(depot2, "artifacts", "Overrides.toml"), "w") do io
            overrides = Dict(
                # Override baz_hash to point to `bar_hash`
                bytes2hex(baz_hash.bytes) => bytes2hex(bar_hash.bytes),

                # Override "ArtifactOverrideLoading.arty" to point to `bar_hash` as well.
                # Override "ArtifactOverrideLoading.barty" to point to a location on disk
                string(aol_uuid) => Dict(
                    "arty" => bytes2hex(bar_hash.bytes),
                    "barty" => barty_override_path,
                )
            )
            TOML.print(io, overrides)
        end

        # Force Pkg to reload what it knows about artifact overrides
        Pkg.Artifacts.load_overrides(;force=true)

        # Verify that the hash-based override worked
        @test artifact_path(baz_hash) == artifact_path(bar_hash)
        @test !endswith(artifact_path(baz_hash), bytes2hex(baz_hash.bytes))

        # Verify that the name-based override worked; extract paths from module that
        # loads overridden package artifacts.
        Pkg.activate(depot_container) do
            copy_test_package(depot_container, "ArtifactOverrideLoading")
            add_this_pkg()
            Pkg.add(Pkg.Types.PackageSpec(
                name="ArtifactOverrideLoading",
                uuid=aol_uuid,
                path=joinpath(depot_container, "ArtifactOverrideLoading"),
            ))

            (arty_path, barty_path) = Core.eval(Module(:__anon__), quote
                using ArtifactOverrideLoading
                arty_path, barty_path
            end)

            @test arty_path == artifact_path(bar_hash)
            @test barty_path == barty_override_path
        end

        # Excellent.  Let's add another Overrides.toml, this time in `depot1`, to muck
        # with the two overrides we put in previously, as well as `foo_hash`.
        open(joinpath(depot1, "artifacts", "Overrides.toml"), "w") do io
            overrides = Dict(
                # Override `foo` to an absolute path, then remove all overrides on `baz`
                bytes2hex(foo_hash.bytes) => barty_override_path,
                bytes2hex(baz_hash.bytes) => "",

                # Override "ArtifactOverrideLoading.arty" to point to `barty_override_path` as well.
                string(aol_uuid) => Dict(
                    "arty" => barty_override_path,
                )
            )
            TOML.print(io, overrides)
        end

        # Force Pkg to reload what it knows about artifact overrides
        Pkg.Artifacts.load_overrides(;force=true)

        # Force Julia to re-load ArtifactOverrideLoading from scratch
        pkgid = Base.PkgId(aol_uuid, "ArtifactOverrideLoading")
        delete!(Base.loaded_modules, pkgid)

        # Verify that the hash-based overrides (and clears) worked
        @test artifact_path(foo_hash) == barty_override_path
        @test endswith(artifact_path(baz_hash), bytes2hex(baz_hash.bytes))

        # Verify that the name-based override worked; extract paths from module that
        # loads overridden package artifacts.
        Pkg.activate(depot_container) do
            (arty_path, barty_path) = Core.eval(Module(:__anon__), quote
                using ArtifactOverrideLoading
                arty_path, barty_path
            end)

            @test arty_path == barty_override_path
            @test barty_path == barty_override_path
        end

        # Finally, let's test some invalid overrides:
        function test_invalid_override(overrides::Dict, msg)
            open(joinpath(depot1, "artifacts", "Overrides.toml"), "w") do io
                TOML.print(io, overrides)
            end
            @test_logs (:error, msg) match_mode=:any Pkg.Artifacts.load_overrides(;force=true)
        end

        # Mapping to a non-absolute path or SHA1 hash
        test_invalid_override(
            Dict("0"^40 => "invalid override target"),
            r"must map to an absolute path or SHA1 hash!",
        )
        test_invalid_override(
            Dict("0"^41 => "1"^40),
            r"Invalid SHA1 hash",
        )
        test_invalid_override(
            Dict("invalid UUID" => Dict("0"^40 => "1"^40)),
            r"Invalid UUID",
        )
        test_invalid_override(
            Dict("0"^40 => ["not", "a", "string", "or", "dict"]),
            r"failed to parse entry",
        )
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, old_depot_path)
    end
end

end # module
