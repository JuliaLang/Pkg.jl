module PlatformEngineTests
import ..Pkg # ensure we are using the correct Pkg

using Test, Pkg.PlatformEngines, Pkg.BinaryPlatforms, SHA

# Explicitly probe platform engines in verbose mode to get coverage and make
# CI debugging easier
probe_platform_engines!(;verbose=true)

@testset "Tarball listing parsing" begin
    fake_7z_output = """
	7-Zip [64] 9.20  Copyright (c) 1999-2010 Igor Pavlov  2010-11-18
	p7zip Version 9.20 (locale=en_US.UTF-8,Utf16=on,HugeFiles=on,4 CPUs)
	Listing archive:
	--
	Path =
	Type = tar
	   Date      Time    Attr         Size   Compressed  Name
	------------------- ----- ------------ ------------  ------------------------
	2017-04-10 14:45:00 D....            0            0  bin
	2017-04-10 14:44:59 .....          211          512  bin/socrates
	------------------- ----- ------------ ------------  ------------------------
									   211          512  1 files, 1 folders
	"""
	@test parse_7z_list(fake_7z_output) == ["bin/socrates"]


	fake_tar_output = """
	bin/
	bin/socrates
	"""
	@test parse_tar_list(fake_tar_output) == normpath.(["bin/socrates"])
end

@testset "Packaging" begin
    # Gotta set this guy up beforehand
    tarball_path = nothing
    tarball_hash = nothing

    mktempdir() do prefix
        # Create random files
        mkpath(joinpath(prefix, "bin"))
        mkpath(joinpath(prefix, "lib"))
        mkpath(joinpath(prefix, "etc"))
        bar_path = joinpath(prefix, "bin", "bar.sh")
        open(bar_path, "w") do f
            write(f, "#!/bin/sh\n")
            write(f, "echo yolo\n")
        end
        baz_path = joinpath(prefix, "lib", "baz.so")
        open(baz_path, "w") do f
            write(f, "this is not an actual .so\n")
        end

        qux_path = joinpath(prefix, "etc", "qux.conf")
        open(qux_path, "w") do f
            write(f, "use_julia=true\n")
        end

        # Next, package it up as a .tar.gz file
        mktempdir() do output_dir
            tarball_path =  joinpath(output_dir, "foo.tar.gz")
            package(prefix, tarball_path)
            @test isfile(tarball_path)

            # Test that we can inspect the contents of the tarball
            contents = list_tarball_files(tarball_path)
            @test joinpath("bin", "bar.sh") in contents
            @test joinpath("lib", "baz.so") in contents
            @test joinpath("etc", "qux.conf") in contents
        end
    end

end


@testset "Verification" begin
    mktempdir() do prefix
        foo_path = joinpath(prefix, "foo")
        open(foo_path, "w") do file
            write(file, "test")
        end
        foo_hash = bytes2hex(sha256("test"))

        # Check that verifying with the right hash works
        @test_logs (:info, r"No hash cache found") match_mode=:any begin
            ret, status = verify(foo_path, foo_hash; verbose=true, report_cache_status=true)
            @test ret == true
            @test status == :hash_cache_missing
        end

        # Check that it created a .sha256 file
        @test isfile("$(foo_path).sha256")

        # Check that it verifies the second time around properly
        @test_logs (:info, r"Hash cache is consistent") match_mode=:any begin
            ret, status = verify(foo_path, foo_hash; verbose=true, report_cache_status=true)
            @test ret == true
            @test status == :hash_cache_consistent
        end

        # Sleep for imprecise filesystems
        sleep(2)

        # Get coverage of messing with different parts of the verification chain
        touch(foo_path)
        @test_logs (:info, r"File has been modified") match_mode=:any begin
            ret, status = verify(foo_path, foo_hash; verbose=true, report_cache_status=true)
            @test ret == true
            @test status == :file_modified
        end

        # Ensure that we print an error when verification fails
        rm("$(foo_path).sha256"; force=true)
        @test_logs (:error, r"Hash Mismatch!") match_mode=:any begin
            @test !verify(foo_path, "0"^64; verbose=true)
        end

        # Ensure that incorrect lengths cause an exception
        @test_throws ErrorException verify(foo_path, "0"^65; verbose=true)

        # Ensure that messing with the hash file works properly
        touch(foo_path)
        @test verify(foo_path, foo_hash; verbose=true)
        open("$(foo_path).sha256", "w") do file
            write(file, "this is not the right hash")
        end
        @test_logs (:info, r"hash cache invalidated") match_mode=:any begin
            ret, status = verify(foo_path, foo_hash; verbose=true, report_cache_status=true)
            @test ret == true
            @test status == :hash_cache_mismatch
        end

        # Ensure that messing with the actual file works properly
        open("$(foo_path)", "w") do file
            write(file, "this is not the right content")
        end

        # Delete hash cache file to force re-verification
        rm("$(foo_path).sha256"; force=true)
        @test_logs (:error, r"Hash Mismatch!") match_mode=:any begin
            ret, status = verify(foo_path, foo_hash; verbose=true, report_cache_status=true)
            @test ret == false
            @test status == :hash_mismatch
        end
    end
end


const socrates_urls = [
    "https://github.com/staticfloat/small_bin/raw/f1a92f5eafbd30a0c6a8efb6947485b0f6d1bec3/socrates.tar.gz" =>
    "e65d2f13f2085f2c279830e863292312a72930fee5ba3c792b14c33ce5c5cc58",
    "https://github.com/staticfloat/small_bin/raw/f1a92f5eafbd30a0c6a8efb6947485b0f6d1bec3/socrates.tar.bz2" =>
    "13fc17b97be41763b02cbb80e9d048302cec3bd3d446c2ed6e8210bddcd3ac76",
    "https://github.com/staticfloat/small_bin/raw/f1a92f5eafbd30a0c6a8efb6947485b0f6d1bec3/socrates.tar.xz" =>
    "61bcf109fcb749ee7b6a570a6057602c08c836b6f81091eab7aa5f5870ec6475",
]
const socrates_hash = "adcbcf15674eafe8905093183d9ab997cbfba9056fc7dde8bfa5a22dfcfb4967"

@testset "Downloading" begin
    for (url, hash) in socrates_urls
        mktempdir() do prefix
            tarball_path = joinpath(prefix, "download_target.tar$(splitext(url)[2])")

            target_dir = joinpath(prefix, "target")
            download_verify_unpack(url, hash, target_dir; tarball_path=tarball_path, verbose=true)

            # Test downloading a second time, to get the "already exists" path
            download_verify_unpack(url, hash, target_dir; tarball_path=tarball_path, verbose=true)

            # And a third time, after corrupting it, to get the "redownloading" path
            open(tarball_path, "w") do io
                println(io, "corruptify")
            end
            download_verify_unpack(url, hash, target_dir; tarball_path=tarball_path, verbose=true, force=true)

            # Test that it has the contents we expect
            socrates_path = joinpath(target_dir, "bin", "socrates")
            @test isfile(socrates_path)
            unpacked_hash = open(socrates_path) do f
                bytes2hex(sha256(f))
            end
            @test unpacked_hash == socrates_hash
        end
    end
end

const collapse_url = "https://github.com/staticfloat/small_bin/raw/master/collapse_the_symlink/collapse_the_symlink.tar.gz"
const collapse_hash = "956c1201405f64d3465cc28cb0dec9d63c11a08cad28c381e13bb22e1fc469d3"
@testset "Copyderef unpacking" begin
    withenv("BINARYPROVIDER_COPYDEREF" => "true") do
        mktempdir() do prefix
            target_dir = joinpath(prefix, "target")
            download_verify_unpack(collapse_url, collapse_hash, target_dir; verbose=true)

            # Test that we get the files we expect
            @test isfile(joinpath(target_dir, "collapse_the_symlink", "foo"))
            @test isfile(joinpath(target_dir, "collapse_the_symlink", "foo.1"))
            @test isfile(joinpath(target_dir, "collapse_the_symlink", "foo.1.1"))

            # Test that these are definitely not links
            @test !islink(joinpath(target_dir, "collapse_the_symlink", "foo"))
            @test !islink(joinpath(target_dir, "collapse_the_symlink", "foo.1.1"))

            # Test that broken symlinks get transparently dropped
            @test !ispath(joinpath(target_dir, "collapse_the_symlink", "broken"))
        end
    end
end

@testset "Download GitHub API #88" begin
    mktempdir() do tmp
        PlatformEngines.download("https://api.github.com/repos/JuliaPackaging/BinaryProvider.jl/tarball/c2a4fc38f29eb81d66e3322e585d0199722e5d71", joinpath(tmp, "BinaryProvider"); verbose=true)
        @test isfile(joinpath(tmp, "BinaryProvider"))
    end
end

@testset "Authentication Header Hooks" begin
    @test PlatformEngines.get_auth_header("https://foo.bar/baz") == nothing

    old = nothing
    haskey(ENV, "JULIA_PKG_SERVER") && (old = ENV["JULIA_PKG_SERVER"])

    push!(Base.DEPOT_PATH, ".")

    ENV["JULIA_PKG_SERVER"] = ""

    test_server_dir(url, server, ::Nothing) =
        @test PlatformEngines.get_server_dir(url, server) == nothing
    test_server_dir(url, server, domain) =
        @test PlatformEngines.get_server_dir(url, server) ==
            joinpath(Pkg.depots1(), "servers", domain)

    @testset "get_server_dir" begin
        test_server_dir("https://foo.bar/baz/a", nothing, nothing)
        test_server_dir("https://foo.bar/baz/a", "https://bar", nothing)
        test_server_dir("https://foo.bar/baz/a", "foo.bar", nothing)
        test_server_dir("https://foo.bar/bazx", "https://foo.bar/baz", nothing)
        test_server_dir("https://foo.bar/baz/a", "https://foo.bar", "foo.bar")
        test_server_dir("https://foo.bar/baz", "https://foo.bar/baz", "foo.bar")
        test_server_dir("https://foo.bar/baz/a", "https://foo.bar/baz", "foo.bar")
        test_server_dir("https://foo.bar/baz/a", "https://foo.bar/baz", "foo.bar")
    end

    called = 0
    dispose = PlatformEngines.register_auth_error_handler("https://foo.bar/baz", function (url, svr, err)
        called += 1
        return true, called < 3
    end)

    @test PlatformEngines.get_auth_header("https://foo.bar/baz") == nothing
    @test called == 0

    ENV["JULIA_PKG_SERVER"] = "https://foo.bar"

    @test PlatformEngines.get_auth_header("https://foo.bar/baz") == nothing
    @test called == 3

    dispose()

    @test PlatformEngines.get_auth_header("https://foo.bar/baz") == nothing
    @test called == 3

    dispose()

    ENV["JULIA_PKG_SERVER"] = "https://foo.bar/baz"

    @test PlatformEngines.get_auth_header("https://foo.bar/baz/a") == nothing
    @test called == 3

    old === nothing ? delete!(ENV, "JULIA_PKG_SERVER") : (ENV["JULIA_PKG_SERVER"] = old)
    pop!(Base.DEPOT_PATH)
end

end # module
