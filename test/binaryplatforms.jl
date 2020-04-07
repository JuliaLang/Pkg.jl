module BinaryPlatformTests
import ..Pkg # ensure we are using the correct Pkg

using Test, Pkg.BinaryPlatforms
import Pkg.BinaryPlatforms: platform_name

# The platform we're running on
const platform = platform_key_abi()

@testset "PlatformNames" begin
    # Ensure the platform type constructors are well behaved
    @testset "Platform constructors" begin
        @test_throws ArgumentError Linux(:not_a_platform)
        @test_throws ArgumentError Linux(:x86_64; libc=:crazy_libc)
        @test_throws ArgumentError Linux(:x86_64; libc=:glibc, call_abi=:crazy_abi)
        @test_throws ArgumentError Linux(:x86_64; libc=:glibc, call_abi=:eabihf)
        @test_throws ArgumentError Linux(:arm)
        @test_throws ArgumentError Linux(:armv7l; libc=:glibc, call_abi=:kekeke)
        @test_throws ArgumentError MacOS(:i686)
        @test_throws ArgumentError MacOS(:x86_64; libc=:glibc)
        @test_throws ArgumentError MacOS(:x86_64; call_abi=:eabihf)
        @test_throws ArgumentError Windows(:armv7l)
        @test_throws ArgumentError Windows(:x86_64; libc=:glibc)
        @test_throws ArgumentError Windows(:x86_64; call_abi=:eabihf)
        @test_throws ArgumentError FreeBSD(:not_a_platform)
        @test_throws ArgumentError FreeBSD(:x86_64; libc=:crazy_libc)
        @test_throws ArgumentError FreeBSD(:x86_64; call_abi=:crazy_abi)
        @test_throws ArgumentError FreeBSD(:x86_64; call_abi=:eabihf)

        @test_throws ArgumentError CompilerABI(;libgfortran_version=v"2")
        @test_throws ArgumentError CompilerABI(;libgfortran_version=v"99")
        @test_throws ArgumentError CompilerABI(;libstdcxx_version=v"3.3")
        @test_throws ArgumentError CompilerABI(;libstdcxx_version=v"3.5")
        @test_throws ArgumentError CompilerABI(;cxxstring_abi=:wut)

        # Test copy constructor
        cabi = CompilerABI(;
            libgfortran_version=v"3",
            libstdcxx_version=v"3.4.18",
            cxxstring_abi=:cxx03,
        )
        cabi2 = CompilerABI(cabi; cxxstring_abi=:cxx11)
        @test libgfortran_version(cabi) == libgfortran_version(cabi2)
        @test libstdcxx_version(cabi) == libstdcxx_version(cabi2)
        @test cxxstring_abi(cabi) != cxxstring_abi(cabi2)

        # Explicitly test that we can pass arguments to UnknownPlatform,
        # and it doesn't do anything.
        @test UnknownPlatform(:riscv; libc=:fuschia_libc) == UnknownPlatform()
    end

    @testset "Platform properties" begin
        # Test that we can get the name of various platforms
        for T in (Linux, MacOS, Windows, FreeBSD, UnknownPlatform)
            @test endswith(string(T), platform_name(T(:x86_64)))
        end

        # Test that we can get the arch of various platforms
        @test arch(Linux(:aarch64; libc=:musl)) == :aarch64
        @test arch(Windows(:i686)) == :i686
        @test arch(FreeBSD(:amd64)) == :x86_64
        @test arch(FreeBSD(:i386)) == :i686
        @test arch(UnknownPlatform(:ppc64le)) == nothing

        # Test that our platform_dlext stuff works
        @test platform_dlext(Linux(:x86_64)) == platform_dlext(Linux(:i686))
        @test platform_dlext(Windows(:x86_64)) == platform_dlext(Windows(:i686))
        @test platform_dlext(MacOS()) != platform_dlext(Linux(:armv7l))
        @test platform_dlext(FreeBSD(:x86_64)) == platform_dlext(Linux(:x86_64))
        @test platform_dlext(UnknownPlatform()) == "unknown"
        @test platform_dlext() == platform_dlext(platform)

        @test wordsize(Linux(:i686)) == wordsize(Linux(:armv7l)) == 32
        @test wordsize(MacOS()) == wordsize(Linux(:aarch64)) == 64
        @test wordsize(FreeBSD(:x86_64)) == wordsize(Linux(:powerpc64le)) == 64
        @test wordsize(UnknownPlatform(:x86_64)) == 0

        @test call_abi(Linux(:x86_64)) == nothing
        @test call_abi(Linux(:armv6l)) == :eabihf
        @test call_abi(Linux(:armv7l; call_abi=:eabihf)) == :eabihf
        @test call_abi(UnknownPlatform(;call_abi=:eabihf)) == nothing

        @test triplet(Windows(:i686)) == "i686-w64-mingw32"
        @test triplet(Linux(:x86_64; libc=:musl)) == "x86_64-linux-musl"
        @test triplet(Linux(:armv7l; libc=:musl)) == "armv7l-linux-musleabihf"
        @test triplet(Linux(:armv6l; libc=:musl, call_abi=:eabihf)) == "armv6l-linux-musleabihf"
        @test triplet(Linux(:x86_64)) == "x86_64-linux-gnu"
        @test triplet(Linux(:armv6l)) == "armv6l-linux-gnueabihf"
        @test triplet(MacOS()) == "x86_64-apple-darwin14"
        @test triplet(FreeBSD(:x86_64)) == "x86_64-unknown-freebsd11.1"
        @test triplet(FreeBSD(:i686)) == "i686-unknown-freebsd11.1"
        @test triplet(UnknownPlatform()) == "unknown-unknown-unknown"

        @test repr(Windows(:x86_64)) == "Windows(:x86_64)"
        @test repr(Linux(:x86_64; libc=:glibc, call_abi=nothing)) == "Linux(:x86_64, libc=:glibc)"
        @test repr(Linux(:armv7l; libc=:musl, call_abi=:eabihf)) == "Linux(:armv7l, libc=:musl, call_abi=:eabihf)"
        @test repr(MacOS()) == "MacOS(:x86_64)"
        @test repr(MacOS(compiler_abi=CompilerABI(cxxstring_abi=:cxx11))) == "MacOS(:x86_64, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))"
        @test repr(CompilerABI(;libgfortran_version=v"4", libstdcxx_version=v"3.4.24", cxxstring_abi=:cxx11)) == "CompilerABI(libgfortran_version=v\"4.0.0\", libstdcxx_version=v\"3.4.24\", cxxstring_abi=:cxx11)"
    end

    @testset "Valid DL paths" begin
        # Test some valid dynamic library paths
        @test valid_dl_path("libfoo.so.1.2.3", Linux(:x86_64))
        @test valid_dl_path("libfoo.1.2.3.so", Linux(:x86_64))
        @test valid_dl_path("libfoo-1.2.3.dll", Windows(:x86_64))
        @test valid_dl_path("libfoo.1.2.3.dylib", MacOS())
        @test !valid_dl_path("libfoo.dylib", Linux(:x86_64))
        @test !valid_dl_path("libfoo.so", Windows(:x86_64))
        @test !valid_dl_path("libfoo.dll", MacOS())
        @test !valid_dl_path("libfoo.so.1.2.3.", Linux(:x86_64))
        @test !valid_dl_path("libfoo.so.1.2a.3", Linux(:x86_64))
    end

    @testset "platform_key_abi parsing" begin
        # Make sure the platform_key_abi() with explicit triplet works
        @test platform_key_abi("x86_64-linux-gnu") == Linux(:x86_64)
        @test platform_key_abi("x86_64-linux-musl") == Linux(:x86_64, libc=:musl)
        @test platform_key_abi("i686-unknown-linux-gnu") == Linux(:i686)
        @test platform_key_abi("x86_64-apple-darwin14") == MacOS()
        @test platform_key_abi("x86_64-apple-darwin17.0.0") == MacOS()
        @test platform_key_abi("armv7l-pc-linux-gnueabihf") == Linux(:armv7l)
        @test platform_key_abi("armv7l-linux-musleabihf") == Linux(:armv7l, libc=:musl)
        @test platform_key_abi("armv6l-linux-gnueabihf") == Linux(:armv6l)
        # Test that the short name "arm" goes to `armv7l`
        @test platform_key_abi("arm-linux-gnueabihf") == Linux(:armv7l)
        @test platform_key_abi("aarch64-unknown-linux-gnu") == Linux(:aarch64)
        @test platform_key_abi("powerpc64le-linux-gnu") == Linux(:powerpc64le)
        @test platform_key_abi("ppc64le-linux-gnu") == Linux(:powerpc64le)
        @test platform_key_abi("x86_64-w64-mingw32") == Windows(:x86_64)
        @test platform_key_abi("i686-w64-mingw32") == Windows(:i686)
        @test platform_key_abi("x86_64-unknown-freebsd11.1") == FreeBSD(:x86_64)
        @test platform_key_abi("i686-unknown-freebsd11.1") == FreeBSD(:i686)
        @test platform_key_abi("amd64-unknown-freebsd12.0") == FreeBSD(:x86_64)
        @test platform_key_abi("i386-unknown-freebsd10.3") == FreeBSD(:i686)

        # Test inclusion of ABI stuff, both old-style and new-style
        @test platform_key_abi("x86_64-linux-gnu-gcc7") == Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"4"))
        @test platform_key_abi("x86_64-linux-gnu-gcc4-cxx11") == Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"3", cxxstring_abi=:cxx11))
        @test platform_key_abi("x86_64-linux-gnu-cxx11") == Linux(:x86_64, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))
        @test platform_key_abi("x86_64-linux-gnu-libgfortran3-cxx03") == Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"3", cxxstring_abi=:cxx03))
        @test platform_key_abi("x86_64-linux-gnu-libstdcxx26") == Linux(:x86_64, compiler_abi=CompilerABI(libstdcxx_version=v"3.4.26"))

        # Make sure some of these things are rejected
        function test_bad_platform(p_str)
            @test_logs (:warn, r"not an officially supported platform") begin
                @test platform_key_abi(p_str) == UnknownPlatform()
            end
        end

        test_bad_platform("totally FREEFORM text!!1!!!1!")
        test_bad_platform("invalid-triplet-here")
        test_bad_platform("aarch64-linux-gnueabihf")
        test_bad_platform("x86_64-w32-mingw64")
    end

    @testset "platforms_match()" begin
        # Just do a quick combinatorial sweep for completeness' sake for platform matching
        for libgfortran_version in (nothing, v"3", v"5"),
            libstdcxx_version in (nothing, v"3.4.18", v"3.4.26"),
            cxxstring_abi in (nothing, :cxx03, :cxx11)

            cabi = CompilerABI(;
                libgfortran_version=libgfortran_version,
                libstdcxx_version=libstdcxx_version,
                cxxstring_abi=cxxstring_abi,
            )
            @test platforms_match(Linux(:x86_64), Linux(:x86_64, compiler_abi=cabi))
            @test platforms_match(Linux(:x86_64, compiler_abi=cabi), Linux(:x86_64))

            # Also test auto-string-parsing
            @test platforms_match(triplet(Linux(:x86_64)), Linux(:x86_64, compiler_abi=cabi))
            @test platforms_match(Linux(:x86_64), triplet(Linux(:x86_64, compiler_abi=cabi)))
        end

        # Ensure many of these things do NOT match
        @test !platforms_match(Linux(:x86_64), Linux(:i686))
        @test !platforms_match(Linux(:x86_64), Windows(:x86_64))
        @test !platforms_match(Linux(:x86_64), MacOS())
        @test !platforms_match(Linux(:x86_64), UnknownPlatform())

        # Make some explicitly non-matching cabi's
        base_cabi = CompilerABI(;
            libgfortran_version=v"5",
            cxxstring_abi=:cxx11,
        )
        for arch in (:x86_64, :i686, :aarch64, :armv6l, :armv7l),
            cabi in (
                CompilerABI(libgfortran_version=v"3"),
                CompilerABI(cxxstring_abi=:cxx03),
                CompilerABI(libgfortran_version=v"4", cxxstring_abi=:cxx11),
                CompilerABI(libgfortran_version=v"3", cxxstring_abi=:cxx03),
            )

            @test !platforms_match(Linux(arch, compiler_abi=base_cabi), Linux(arch, compiler_abi=cabi))
        end
    end

    @testset "DL name/version parsing" begin
        # Make sure our version parsing code is working
        @test parse_dl_name_version("libgfortran.dll", Windows(:x86_64)) == ("libgfortran", nothing)
        @test parse_dl_name_version("libgfortran-3.dll", Windows(:x86_64)) == ("libgfortran", v"3")
        @test parse_dl_name_version("libgfortran-3.4.dll", Windows(:x86_64)) == ("libgfortran", v"3.4")
        @test parse_dl_name_version("libgfortran-3.4a.dll", Windows(:x86_64)) == ("libgfortran-3.4a", nothing)
        @test_throws ArgumentError parse_dl_name_version("libgfortran", Windows(:x86_64))
        @test parse_dl_name_version("libgfortran.dylib", MacOS(:x86_64)) == ("libgfortran", nothing)
        @test parse_dl_name_version("libgfortran.3.dylib", MacOS(:x86_64)) == ("libgfortran", v"3")
        @test parse_dl_name_version("libgfortran.3.4.dylib", MacOS(:x86_64)) == ("libgfortran", v"3.4")
        @test parse_dl_name_version("libgfortran.3.4a.dylib", MacOS(:x86_64)) == ("libgfortran.3.4a", nothing)
        @test_throws ArgumentError parse_dl_name_version("libgfortran", MacOS(:x86_64))
        @test parse_dl_name_version("libgfortran.so", Linux(:x86_64)) == ("libgfortran", nothing)
        @test parse_dl_name_version("libgfortran.so.3", Linux(:x86_64)) == ("libgfortran", v"3")
        @test parse_dl_name_version("libgfortran.so.3.4", Linux(:x86_64)) == ("libgfortran", v"3.4")
        @test_throws ArgumentError parse_dl_name_version("libgfortran.so.3.4a", Linux(:x86_64))
        @test_throws ArgumentError parse_dl_name_version("libgfortran", Linux(:x86_64))
    end

    @testset "Sys.is* overloading" begin
        # Test that we can indeed ask if something is linux or windows, etc...
        @test Sys.islinux(Linux(:aarch64))
        @test !Sys.islinux(Windows(:x86_64))
        @test Sys.iswindows(Windows(:i686))
        @test !Sys.iswindows(Linux(:x86_64))
        @test Sys.isapple(MacOS())
        @test !Sys.isapple(Linux(:powerpc64le))
        @test Sys.isbsd(MacOS())
        @test Sys.isbsd(FreeBSD(:x86_64))
        @test !Sys.isbsd(Linux(:powerpc64le; libc=:musl))
    end

    @testset "Compiler ABI detection" begin
        @test detect_libgfortran_version("libgfortran.so.5", Linux(:x86_64)) == v"5"
        @test detect_libgfortran_version("libgfortran.4.dylib", MacOS()) == v"4"
        @test detect_libgfortran_version("libgfortran-3.dll", Windows(:x86_64)) == v"3"
        @test_logs (:warn, r"Unable to determine libgfortran version") begin
            @test detect_libgfortran_version("blah.so", Linux(:aarch64)) == nothing
        end

        # Let's check and ensure that we can autodetect the currently-running Julia process
        @test detect_libgfortran_version() != nothing

        # We run these to get coverage, but we can't test anything, because we could be built
        # with `clang`, which wouldn't have any `libstdc++` constraints at all
        detect_libstdcxx_version()
        detect_cxxstring_abi()
    end
end

@testset "select_platform" begin
    platforms = Dict(
        # Typical binning test
        Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"3")) => "linux4",
        Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"4")) => "linux7",
        Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"5")) => "linux8",

        # Ambiguity test
        Linux(:aarch64, compiler_abi=CompilerABI(libgfortran_version=v"3")) => "linux4",
        Linux(:aarch64, compiler_abi=CompilerABI(libgfortran_version=v"3", libstdcxx_version=v"3.4.18")) => "linux5",

        MacOS(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"3")) => "mac4",
        Windows(:x86_64, compiler_abi=CompilerABI(cxxstring_abi=:cxx11)) => "win",
    )

    @test select_platform(platforms, Linux(:x86_64)) == "linux8"
    @test select_platform(platforms, Linux(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"4"))) == "linux7"

    # Ambiguity test
    @test select_platform(platforms, Linux(:aarch64)) == "linux5"
    @test select_platform(platforms, Linux(:aarch64; compiler_abi=CompilerABI(libgfortran_version=v"3"))) == "linux5"
    @test select_platform(platforms, Linux(:aarch64; compiler_abi=CompilerABI(libgfortran_version=v"4"))) == nothing

    @test select_platform(platforms, MacOS(:x86_64)) == "mac4"
    @test select_platform(platforms, MacOS(:x86_64, compiler_abi=CompilerABI(libgfortran_version=v"4"))) == nothing

    @test select_platform(platforms, Windows(:x86_64, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))) == "win"
    @test select_platform(platforms, Windows(:x86_64, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))) == nothing

    # Poor little guy
    @test select_platform(platforms, FreeBSD(:x86_64)) == nothing
end


end # module
