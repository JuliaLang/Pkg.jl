module ArtifactTests

using Test, Pkg.Artifacts, Pkg.BinaryPlatforms
import Pkg.Artifacts: pack_platform!, unpack_platform
import Base: SHA1

include("utils.jl")

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
        @test unpack_platform(meta, "foo", "<in-memory-Artifact.toml>") == p
    end
end

@testset "Artifact Creation" begin
    # We're going to ensure that our artifact creation does in fact give git-tree-sha1's.
    creators = [
        # First we will test creating a single file
        (path -> begin
            open(joinpath(path, "foo"), "w") do io
                println(io, "Hello, world!")
            end
        end, "f2df5266567842bbb8a06acca56bcabf813cd73f"),

        # Next we will test creating multiple files
        (path -> begin
            open(joinpath(path, "foo1"), "w") do io
                println(io, "Hello")
            end
            open(joinpath(path, "foo2"), "w") do io
                println(io, "world!")
            end
        end, "abc89fcdb081326006a95d0d920fa9eccd1527df"),

        # Finally, we will have nested directories and all that good stuff
        (path -> begin
            mkpath(joinpath(path, "bar", "bar"))
            open(joinpath(path, "bar", "bar", "foo1"), "w") do io
                println(io, "Hello")
            end
            open(joinpath(path, "bar", "foo2"), "w") do io
                println(io, "world!")
            end
            open(joinpath(path, "foo3"), "w") do io
                println(io, "baz!")
            end
        end, "519a927bb33bd87fe1bdd95db2fe055dbd100f7c"),
    ]

    # Use the following code snippet to figure out the correct gitsha's:
    # for (creator, blah) in creators
    #     mktempdir() do path
    #         creator(path)
    #         cd(path) do
    #             read(`git init .`)
    #             read(`git add . `)
    #             read(`git commit -m "foo"`)
    #             hash = chomp(String(read(`git log -1 --pretty='%T' HEAD`)))
    #             println(hash)
    #         end
    #     end
    # end

    for (creator, known_hash) in creators
        # Create artifact
        hash = create_artifact(creator)
        
        # Ensure it hashes to the correct gitsha:
        @test hash.bytes == hex2bytes(known_hash)

        # Test that we can look it up and that it sits in the right place
        @test basename(dirname(artifact_path(hash))) == "artifacts"
        @test basename(artifact_path(hash)) == known_hash
        @test artifact_exists(hash)

        # Test that the artifact verifies
        @test verify_artifact(hash)
    end
end

@testset "Artifact.toml Utilities" begin
    # First, let's test our ability to find Artifact.toml files;
    ATS = joinpath(@__DIR__, "test_packages", "ArtifactTOMLSearch")
    test_modules = [
        joinpath(ATS, "pkg.jl") =>  joinpath(ATS, "Artifact.toml"),
        joinpath(ATS, "sub_module", "pkg.jl") =>  joinpath(ATS, "Artifact.toml"),
        joinpath(ATS, "sub_package", "pkg.jl") =>  joinpath(ATS, "sub_package", "Artifact.toml"),
        joinpath(@__DIR__, "test_packages", "BasicSandbox", "src", "Foo.jl") => nothing,
    ]
    for (test_src, artifact_toml) in test_modules
        # Test that the Artifact.toml that was found is what we expected
        @test find_artifact_toml(test_src) == artifact_toml

        # Load `arty` and check its gitsha
        if artifact_toml !== nothing
            arty_hash = SHA1("43563e7631a7eafae1f9f8d9d332e3de44ad7239")
            @test artifact_hash("arty", artifact_toml) == arty_hash

            # Ensure it's installable (we uninstall first, to make sure)
            remove_artifact(arty_hash)
            @test !artifact_exists(arty_hash)

            @test ensure_artifact_installed("arty", artifact_toml) == artifact_path(arty_hash)
            @test verify_artifact(arty_hash)

            # Make sure doing it twice "just works"
            @test ensure_artifact_installed("arty", artifact_toml) == artifact_path(arty_hash)

            # clean up after thyself
            remove_artifact(arty_hash)
            @test !verify_artifact(arty_hash)
        end
    end

    # Test binding/unbinding
    mktempdir() do path
        hash = create_artifact() do path
            open(joinpath(path, "foo.txt"), "w") do io
                println(io, "hello, world!")
            end
        end

        # Bind this artifact to something
        artifact_toml = joinpath(path, "Artifact.toml")
        @test artifact_hash("foo_txt", artifact_toml) == nothing
        bind_artifact("foo_txt", hash, artifact_toml)

        # Test that this binding worked
        @test artifact_hash("foo_txt", artifact_toml) == hash
        @test ensure_artifact_installed("foo_txt", artifact_toml) == artifact_path(hash)

        # Test that we can overwrite bindings
        hash2 = create_artifact() do path
            open(joinpath(path, "foo.txt"), "w") do io
                println(io, "goodbye, world!")
            end
        end
        @test_throws ErrorException bind_artifact("foo_txt", hash2, artifact_toml)
        @test artifact_hash("foo_txt", artifact_toml) == hash
        bind_artifact("foo_txt", hash2, artifact_toml; force=true)
        @test artifact_hash("foo_txt", artifact_toml) == hash2

        # Test that we can un-bind
        unbind_artifact("foo_txt", artifact_toml)
        @test artifact_hash("foo_txt", artifact_toml) == nothing

        # Test platform-specific binding and providing download_info
        download_info = [
            ("http://google.com/hello_world", "0"^64),
            ("http://microsoft.com/hello_world", "a"^64),
        ]

        # First, test the binding of things with various platforms and overwriting and such works properly
        bind_artifact("foo_txt", hash, artifact_toml; download_info=download_info, platform=Linux(:x86_64))
        @test artifact_hash("foo_txt", artifact_toml; platform=Linux(:x86_64)) == hash
        @test artifact_hash("foo_txt", artifact_toml; platform=MacOS()) == nothing
        @test_throws ErrorException bind_artifact("foo_txt", hash2, artifact_toml; download_info=download_info, platform=Linux(:x86_64))
        bind_artifact("foo_txt", hash2, artifact_toml; download_info=download_info, platform=Linux(:x86_64), force=true)
        bind_artifact("foo_txt", hash, artifact_toml; download_info=download_info, platform=Windows(:i686))
        @test artifact_hash("foo_txt", artifact_toml; platform=Linux(:x86_64)) == hash2
        @test artifact_hash("foo_txt", artifact_toml; platform=Windows(:i686)) == hash

        # Next, check that we can get the download_info properly:
        meta = artifact_meta("foo_txt", artifact_toml; platform=Windows(:i686))
        @test meta["download"][1]["url"] == "http://google.com/hello_world"
        @test meta["download"][2]["sha256"] == "a"^64
    end
end


@testset "Artifact Usage" begin
    # Do a quick little install of our ArtifactTOMLSearch example
    include(joinpath(@__DIR__, "test_packages", "ArtifactTOMLSearch", "pkg.jl"))
    @test ATSMod.do_test()

    temp_pkg_dir() do project_path
        Pkg.activate(project_path)
        add_test_package("ArtifactInstallation", Base.UUID("02111abe-2050-1119-117e-b30112b5bdc4"))

        # Run test harness
        Pkg.test("ArtifactInstallation")

        # Also manually do it
        @eval begin
            using ArtifactInstallation
            @test invokeArtifactInstallation.do_test()
        end
    end
end

end # module
