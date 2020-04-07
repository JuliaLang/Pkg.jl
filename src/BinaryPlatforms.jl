module BinaryPlatforms

export platform_key_abi, platform_dlext, valid_dl_path, arch, libc, compiler_abi,
       libgfortran_version, libstdcxx_version, cxxstring_abi, parse_dl_name_version,
       detect_libgfortran_version, detect_libstdcxx_version, detect_cxxstring_abi,
       call_abi, wordsize, triplet, select_platform, platforms_match,
       CompilerABI, Platform, UnknownPlatform, Linux, MacOS, Windows, FreeBSD
import Base: show
import Libdl

abstract type Platform end

"""
    UnknownPlatform

A placeholder `Platform` that signifies an unknown platform.
"""
struct UnknownPlatform <: Platform
    # Just swallow up whatever arguments get passed to you
    UnknownPlatform(args...; kwargs...) = new()
end

# We need to track our compiler ABI compatibility.
struct CompilerABI
    # libgfortran SOVERSION we're linked against (if any)
    libgfortran_version::Union{Nothing,VersionNumber}

    # libstdc++ SOVERSION we're linked against (if any)
    libstdcxx_version::Union{Nothing,VersionNumber}

    # Whether we're using cxx11abi strings, not using them, or don't care
    # This is only relevant when linked against `libstdc++`, when linked against
    # libc++ or none (because it's not C++ code) we don't care.
    # Valid Symbol values are `:cxx03` and `:cxx11`
    cxxstring_abi::Union{Nothing,Symbol}

    function CompilerABI(;libgfortran_version::Union{Nothing, VersionNumber} = nothing,
                         libstdcxx_version::Union{Nothing, VersionNumber} = nothing,
                         cxxstring_abi::Union{Nothing, Symbol} = nothing)
        if libgfortran_version !== nothing && (libgfortran_version < v"3" ||
                                              libgfortran_version >= v"6")
            throw(ArgumentError("Unsupported libgfortran '$libgfortran_version'"))
        end

        if libstdcxx_version !== nothing && (libstdcxx_version < v"3.4.0" ||
                                            libstdcxx_version >= v"3.5")
            throw(ArgumentError("Unsupported libstdc++ '$libstdcxx_version'"))
        end

        if cxxstring_abi !== nothing && !in(cxxstring_abi, [:cxx03, :cxx11])
            throw(ArgumentError("Unsupported string ABI '$cxxstring_abi'"))
        end

        return new(libgfortran_version, libstdcxx_version, cxxstring_abi)
    end
end

# Easy replacement constructor
function CompilerABI(cabi::CompilerABI; libgfortran_version=nothing,
                                        libstdcxx_version=nothing,
                                        cxxstring_abi=nothing)
    lgv = something(libgfortran_version, Some(cabi.libgfortran_version))
    lsv = something(libstdcxx_version, Some(cabi.libstdcxx_version))
    ca = something(cxxstring_abi, Some(cabi.cxxstring_abi))
    return CompilerABI(;libgfortran_version=lgv, libstdcxx_version=lsv, cxxstring_abi=ca)
end

libgfortran_version(cabi::CompilerABI) = cabi.libgfortran_version
libstdcxx_version(cabi::CompilerABI) = cabi.libstdcxx_version
cxxstring_abi(cabi::CompilerABI) = cabi.cxxstring_abi

function show(io::IO, cabi::CompilerABI)
    args = String[]
    if cabi.libgfortran_version !== nothing
        push!(args, "libgfortran_version=$(repr(cabi.libgfortran_version))")
    end
    if cabi.libstdcxx_version !== nothing
        push!(args, "libstdcxx_version=$(repr(cabi.libstdcxx_version))")
    end
    if cabi.cxxstring_abi !== nothing
        push!(args, "cxxstring_abi=$(repr(cabi.cxxstring_abi))")
    end
    write(io, "CompilerABI($(join(args, ", ")))")
end

struct Linux <: Platform
    arch::Symbol
    libc::Union{Nothing,Symbol}
    call_abi::Union{Nothing,Symbol}
    compiler_abi::CompilerABI

    function Linux(arch::Symbol;
                   libc::Union{Nothing,Symbol}=nothing,
                   call_abi::Union{Nothing,Symbol}=nothing,
                   compiler_abi::CompilerABI=CompilerABI())
        if !in(arch, [:i686, :x86_64, :aarch64, :powerpc64le, :armv6l, :armv7l])
            throw(ArgumentError("Unsupported architecture '$arch' for Linux"))
        end

        # The default libc on Linux is glibc
        if libc === nothing
            libc = :glibc
        end

        if !in(libc, [:glibc, :musl])
            throw(ArgumentError("Unsupported libc '$libc' for Linux"))
        end

        # Auto-map the `call_abi` to be `eabihf` on armv6l/armv7l
        if call_abi === nothing && arch in (:armv6l, :armv7l)
            call_abi = :eabihf
        end

        if !in(call_abi, [:eabihf, nothing])
            throw(ArgumentError("Unsupported calling abi '$call_abi' for Linux"))
        end

        # If we're constructing for armv7l/armv6l, we MUST have the eabihf abi
        if arch in (:armv6l, :armv7l) && call_abi !== :eabihf
            throw(ArgumentError("armv6l/armv7l Linux must use eabihf, not '$call_abi'"))
        end
        # ...and vice-versa
        if !(arch in (:armv6l, :armv7l)) && call_abi === :eabihf
            throw(ArgumentError("eabihf Linux is only supported on armv6l/armv7l, not '$arch'!"))
        end

        return new(arch, libc, call_abi, compiler_abi)
    end
end

struct MacOS <: Platform
    arch::Symbol
    libc::Nothing
    call_abi::Nothing
    compiler_abi::CompilerABI

    # Provide defaults for everything because there's really only one MacOS
    # target right now.  Maybe someday iOS.  :fingers_crossed:
    function MacOS(arch::Symbol=:x86_64;
                   libc::Union{Nothing,Symbol}=nothing,
                   call_abi::Union{Nothing,Symbol}=nothing,
                   compiler_abi::CompilerABI=CompilerABI())
        if arch !== :x86_64
            throw(ArgumentError("Unsupported architecture '$arch' for macOS"))
        end
        if libc !== nothing
            throw(ArgumentError("Unsupported libc '$libc' for macOS"))
        end
        if call_abi !== nothing
            throw(ArgumentError("Unsupported abi '$call_abi' for macOS"))
        end

        return new(arch, libc, call_abi, compiler_abi)
    end
end

struct Windows <: Platform
    arch::Symbol
    libc::Nothing
    call_abi::Nothing
    compiler_abi::CompilerABI

    function Windows(arch::Symbol;
                     libc::Union{Nothing,Symbol}=nothing,
                     call_abi::Union{Nothing,Symbol}=nothing,
                     compiler_abi::CompilerABI=CompilerABI())
        if !in(arch, [:i686, :x86_64])
            throw(ArgumentError("Unsupported architecture '$arch' for Windows"))
        end
        # We only support the one libc/abi on Windows, so no need to play
        # around with "default" values.
        if libc !== nothing
            throw(ArgumentError("Unsupported libc '$libc' for Windows"))
        end
        if call_abi !== nothing
            throw(ArgumentError("Unsupported abi '$call_abi' for Windows"))
        end

        return new(arch, libc, call_abi, compiler_abi)
    end
end

struct FreeBSD <: Platform
    arch::Symbol
    libc::Nothing
    call_abi::Union{Nothing,Symbol}
    compiler_abi::CompilerABI

    function FreeBSD(arch::Symbol=:x86_64;
                     libc::Union{Nothing,Symbol}=nothing,
                     call_abi::Union{Nothing,Symbol}=nothing,
                     compiler_abi::CompilerABI=CompilerABI())
        # `uname` on FreeBSD reports its architecture as amd64 and i386 instead of x86_64
        # and i686, respectively. In the off chance that Julia hasn't done the mapping for
        # us, we'll do it here just in case.
        if arch === :amd64
            arch = :x86_64
        elseif arch === :i386
            arch = :i686
        elseif !in(arch, [:i686, :x86_64, :aarch64, :powerpc64le, :armv6l, :armv7l])
            throw(ArgumentError("Unsupported architecture '$arch' for FreeBSD"))
        end

        # The only libc we support on FreeBSD is the blank libc, which corresponds to
        # FreeBSD's default libc
        if libc !== nothing
            throw(ArgumentError("Unsupported libc '$libc' for FreeBSD"))
        end

        # Auto-map the `call_abi` to be `eabihf` on armv6l/armv7l
        if call_abi === nothing && arch in (:armv6l, :armv7l)
            call_abi = :eabihf
        end

        if !in(call_abi, [:eabihf, nothing])
            throw(ArgumentError("Unsupported calling abi '$call_abi' for FreeBSD"))
        end

        # If we're constructing for armv7l, we MUST have the eabihf abi
        if arch in (:armv6l, :armv7l) && call_abi !== :eabihf
            throw(ArgumentError("armv6l/armv7l FreeBSD must use eabihf, not '$call_abi'"))
        end
        # ...and vice-versa
        if !(arch in (:armv6l, :armv7l)) && call_abi === :eabihf
            throw(ArgumentError("eabihf FreeBSD is supported only on armv6l/armv7l, not '$arch'!"))
        end

        return new(arch, libc, call_abi, compiler_abi)
    end
end

"""
    platform_name(p::Platform)

Get the "platform name" of the given platform.  E.g. returns "Linux" for a
`Linux` object, or "Windows" for a `Windows` object.
"""
platform_name(p::Linux) = "Linux"
platform_name(p::MacOS) = "MacOS"
platform_name(p::Windows) = "Windows"
platform_name(p::FreeBSD) = "FreeBSD"
platform_name(p::UnknownPlatform) = "UnknownPlatform"

"""
    arch(p::Platform)

Get the architecture for the given `Platform` object as a `Symbol`.

# Examples
```jldoctest
julia> arch(Linux(:aarch64))
:aarch64

julia> arch(MacOS())
:x86_64
```
"""
arch(p::Platform) = p.arch
arch(u::UnknownPlatform) = nothing

"""
    libc(p::Platform)

Get the libc for the given `Platform` object as a `Symbol`.

# Examples
```jldoctest
julia> libc(Linux(:aarch64))
:glibc

julia> libc(FreeBSD(:x86_64))
```
"""
libc(p::Platform) = p.libc
libc(u::UnknownPlatform) = nothing

"""
   call_abi(p::Platform)

Get the calling ABI for the given `Platform` object, returns either `nothing` (which
signifies a "default choice") or a `Symbol`.

# Examples
```jldoctest
julia> call_abi(Linux(:x86_64))

julia> call_abi(FreeBSD(:armv7l))
:eabihf
```
"""
call_abi(p::Platform) = p.call_abi
call_abi(u::UnknownPlatform) = nothing

"""
    compiler_abi(p::Platform)

Get the compiler ABI object for the given `Platform`
# Examples
```jldoctest
julia> compiler_abi(Linux(:x86_64))
CompilerABI()
```
"""
compiler_abi(p::Platform) = p.compiler_abi
compiler_abi(p::UnknownPlatform) = CompilerABI()

# Also break out CompilerABI getters for our platforms
libgfortran_version(p::Platform) = libgfortran_version(compiler_abi(p))
libstdcxx_version(p::Platform) = libstdcxx_version(compiler_abi(p))
cxxstring_abi(p::Platform) = cxxstring_abi(compiler_abi(p))

"""
    wordsize(platform)

Get the word size for the given `Platform` object.

# Examples
```jldoctest
julia> wordsize(Linux(:armv7l))
32

julia> wordsize(MacOS())
64
```
"""
wordsize(p::Platform) = (arch(p) === :i686 || arch(p) === :armv7l) ? 32 : 64
wordsize(u::UnknownPlatform) = 0

"""
    triplet(platform)

Get the target triplet for the given `Platform` object as a `String`.

# Examples
```jldoctest
julia> triplet(MacOS())
"x86_64-apple-darwin14"

julia> triplet(Windows(:i686))
"i686-w64-mingw32"

julia> triplet(Linux(:armv7l; compiler_abi=CompilerABI(;libgfortran_version=v"3")))
"armv7l-linux-gnueabihf-libgfortran3"
```
"""
triplet(p::Platform) = string(
    arch_str(p),
    vendor_str(p),
    libc_str(p),
    call_abi_str(p),
    compiler_abi_str(p),
)
vendor_str(p::Windows) = "-w64-mingw32"
vendor_str(p::MacOS) = "-apple-darwin14"
vendor_str(p::Linux) = "-linux"
vendor_str(p::FreeBSD) = "-unknown-freebsd11.1"

# Special-case UnknownPlatform
triplet(p::UnknownPlatform) = "unknown-unknown-unknown"

# Helper functions for Linux and FreeBSD libc/abi mishmashes
arch_str(p::Platform) = string(arch(p))
function libc_str(p::Platform)
    if libc(p) === nothing
        return ""
    elseif libc(p) === :glibc
        return "-gnu"
    else
        return "-$(libc(p))"
    end
end
call_abi_str(p::Platform) = (call_abi(p) === nothing) ? "" : string(call_abi(p))
function compiler_abi_str(cabi::CompilerABI)
    str = ""
    if cabi.libgfortran_version !== nothing
        str *= "-libgfortran$(cabi.libgfortran_version.major)"
    end

    if cabi.libstdcxx_version !== nothing
        str *= "-libstdcxx$(libstdcxx_version(cabi).patch)"
    end

    if cabi.cxxstring_abi !== nothing
        str *= "-$(cabi.cxxstring_abi)"
    end
    return str
end
compiler_abi_str(p::Platform) = compiler_abi_str(compiler_abi(p))

Sys.isapple(p::Platform) = p isa MacOS
Sys.islinux(p::Platform) = p isa Linux
Sys.iswindows(p::Platform) = p isa Windows
Sys.isbsd(p::Platform) = (p isa FreeBSD) || (p isa MacOS)


"""
    platform_key_abi(machine::AbstractString)

Returns the platform key for the current platform, or any other though the
the use of the `machine` parameter.
"""
function platform_key_abi(machine::AbstractString)
    # We're going to build a mondo regex here to parse everything:
    arch_mapping = Dict(
        :x86_64 => "(x86_|amd)64",
        :i686 => "i\\d86",
        :aarch64 => "aarch64",
        :armv7l => "arm(v7l)?", # if we just see `arm-linux-gnueabihf`, we assume it's `armv7l`
        :armv6l => "armv6l",
        :powerpc64le => "p(ower)?pc64le",
    )
    platform_mapping = Dict(
        :darwin => "-apple-darwin[\\d\\.]*",
        :freebsd => "-(.*-)?freebsd[\\d\\.]*",
        :mingw32 => "-w64-mingw32",
        :linux => "-(.*-)?linux",
    )
    libc_mapping = Dict(
        :libc_nothing => "",
        :glibc => "-gnu",
        :musl => "-musl",
    )
    call_abi_mapping = Dict(
        :call_abi_nothing => "",
        :eabihf => "eabihf",
    )
    libgfortran_version_mapping = Dict(
        :libgfortran_nothing => "",
        :libgfortran3 => "(-libgfortran3)|(-gcc4)", # support old-style `gccX` versioning
        :libgfortran4 => "(-libgfortran4)|(-gcc7)",
        :libgfortran5 => "(-libgfortran5)|(-gcc8)",
    )
    libstdcxx_version_mapping = Dict(
        :libstdcxx_nothing => "",
        # This is sadly easier than parsing out the digit directly
        (Symbol("libstdcxx$(idx)") => "-libstdcxx$(idx)" for idx in 18:26)...,
    )
    cxxstring_abi_mapping = Dict(
        :cxxstring_nothing => "",
        :cxx03 => "-cxx03",
        :cxx11 => "-cxx11",
    )

    # Helper function to collapse dictionary of mappings down into a regex of
    # named capture groups joined by "|" operators
    c(mapping) = string("(",join(["(?<$k>$v)" for (k, v) in mapping], "|"), ")")

    triplet_regex = Regex(string(
        "^",
        c(arch_mapping),
        c(platform_mapping),
        c(libc_mapping),
        c(call_abi_mapping),
        c(libgfortran_version_mapping),
        c(libstdcxx_version_mapping),
        c(cxxstring_abi_mapping),
        "\$",
    ))

    m = match(triplet_regex, machine)
    if m !== nothing
        # Helper function to find the single named field within the giant regex
        # that is not `nothing` for each mapping we give it.
        get_field(m, mapping) = begin
            for k in keys(mapping)
                if m[k] !== nothing
                    strk = string(k)
                    # Convert our sentinel `nothing` values to actual `nothing`
                    if endswith(strk, "_nothing")
                        return nothing
                    end
                    # Convert libgfortran/libstdcxx version numbers
                    if startswith(strk, "libgfortran")
                        return VersionNumber(parse(Int,strk[12:end]))
                    elseif startswith(strk, "libstdcxx")
                        return VersionNumber(3, 4, parse(Int,strk[10:end]))
                    else
                        return k
                    end
                end
            end
        end

        # Extract the information we're interested in:
        arch = get_field(m, arch_mapping)
        platform = get_field(m, platform_mapping)
        libc = get_field(m, libc_mapping)
        call_abi = get_field(m, call_abi_mapping)
        libgfortran_version = get_field(m, libgfortran_version_mapping)
        libstdcxx_version = get_field(m, libstdcxx_version_mapping)
        cxxstring_abi = get_field(m, cxxstring_abi_mapping)

        # First, figure out what platform we're dealing with, then sub that off
        # to the appropriate constructor.  If a constructor runs into trouble,
        # catch the error and return `UnknownPlatform()` here to be nicer to client code.
        ctors = Dict(:darwin => MacOS, :mingw32 => Windows, :freebsd => FreeBSD, :linux => Linux)
        try
            T = ctors[platform]
            compiler_abi = CompilerABI(;
                libgfortran_version=libgfortran_version,
                libstdcxx_version=libstdcxx_version,
                cxxstring_abi=cxxstring_abi
            )
            return T(arch, libc=libc, call_abi=call_abi, compiler_abi=compiler_abi)
        catch
        end
    end

    @warn("Platform `$(machine)` is not an officially supported platform")
    return UnknownPlatform()
end


# Define show() for these Platform objects for two reasons:
#  - I don't like the `BinaryProvider.` at the beginning of the types;
#    it's unnecessary as these are exported
#  - I like to auto-expand non-`nothing` arguments
function show(io::IO, p::Platform)
    write(io, "$(platform_name(p))($(repr(arch(p)))")

    if libc(p) !== nothing
        write(io, ", libc=$(repr(libc(p)))")
    end
    if call_abi(p) !== nothing
        write(io, ", call_abi=$(repr(call_abi(p)))")
    end
    if compiler_abi(p) != CompilerABI()
        write(io, ", compiler_abi=$(repr(compiler_abi(p)))")
    end
    write(io, ")")
end


"""
    platform_dlext(platform::Platform = platform_key_abi())

Return the dynamic library extension for the given platform, defaulting to the
currently running platform.  E.g. returns "so" for a Linux-based platform,
"dll" for a Windows-based platform, etc...
"""
platform_dlext(::Linux) = "so"
platform_dlext(::FreeBSD) = "so"
platform_dlext(::MacOS) = "dylib"
platform_dlext(::Windows) = "dll"
platform_dlext(::UnknownPlatform) = "unknown"
platform_dlext() = platform_dlext(platform_key_abi())

"""
    parse_dl_name_version(path::AbstractString, platform::Platform)

Given a path to a dynamic library, parse out what information we can
from the filename.  E.g. given something like "lib/libfoo.so.3.2",
this function returns `"libfoo", v"3.2"`.  If the path name is not a
valid dynamic library, this method throws an error.  If no soversion
can be extracted from the filename, as in "libbar.so" this method
returns `"libbar", nothing`.
"""
function parse_dl_name_version(path::AbstractString, platform::Platform)
    dlext_regexes = Dict(
        # On Linux, libraries look like `libnettle.so.6.3.0`
        "so" => r"^(.*?).so((?:\.[\d]+)*)$",
        # On OSX, libraries look like `libnettle.6.3.dylib`
        "dylib" => r"^(.*?)((?:\.[\d]+)*).dylib$",
        # On Windows, libraries look like `libnettle-6.dll`
        "dll" => r"^(.*?)(?:-((?:[\.\d]+)*))?.dll$"
    )

    # Use the regex that matches this platform
    dlregex = dlext_regexes[platform_dlext(platform)]
    m = match(dlregex, basename(path))
    if m === nothing
        throw(ArgumentError("Invalid dynamic library path '$path'"))
    end

    # Extract name and version
    name = m.captures[1]
    version = m.captures[2]
    if version === nothing || isempty(version)
        version = nothing
    else
        version = VersionNumber(strip(version, '.'))
    end
    return name, version
end

"""
    valid_dl_path(path::AbstractString, platform::Platform)

Return `true` if the given `path` ends in a valid dynamic library filename.
E.g. returns `true` for a path like `"usr/lib/libfoo.so.3.5"`, but returns
`false` for a path like `"libbar.so.f.a"`.
"""
function valid_dl_path(path::AbstractString, platform::Platform)
    try
        parse_dl_name_version(path, platform)
        return true
    catch
        return false
    end
end

"""
    detect_libgfortran_version(libgfortran_name::AbstractString)

Examines the given libgfortran SONAME to see what version of GCC corresponds
to the given libgfortran version.
"""
function detect_libgfortran_version(libgfortran_name::AbstractString, platform::Platform = default_platkey)
    name, version = parse_dl_name_version(libgfortran_name, platform)
    if version === nothing
        # Even though we complain about this; we allow it to continue, in the hopes
        # that we shall march on to a BRIGHTER TOMORROW, one in which we are not shackled
        # by the constraints of libgfortran compiler ABIs on our precious programming
        # languages; one where the mistakes of yesterday are mere memories and not
        # continual maintenance burdens upon the children of tomorrow; one where numeric
        # code can be cleanly implemented in a modern language and not bestowed onto the
        # next generation by grizzled ancients, documented only with a faded yellow
        # sticky note that says simply "good luck".
        @warn("Unable to determine libgfortran version from '$(libgfortran_name)'")
    end
    return version
end

"""
    detect_libgfortran_version()

Inspects the current Julia process to determine the libgfortran version this Julia is
linked against (if any).
"""
function detect_libgfortran_version(;platform::Platform = default_platkey)
    libgfortran_paths = filter(x -> occursin("libgfortran", x), Libdl.dllist())
    if isempty(libgfortran_paths)
        # One day, I hope to not be linking against libgfortran in base Julia
        return nothing
    end
    return detect_libgfortran_version(first(libgfortran_paths), platform)
end

"""
    detect_libstdcxx_version()

Inspects the currently running Julia process to find out what version of libstdc++
it is linked against (if any).
"""
function detect_libstdcxx_version()
    libstdcxx_paths = filter(x -> occursin("libstdc++", x), Libdl.dllist())
    if isempty(libstdcxx_paths)
        # This can happen if we were built by clang, so we don't link against
        # libstdc++ at all.
        return nothing
    end

    # Brute-force our way through GLIBCXX_* symbols to discover which version we're linked against
    hdl = Libdl.dlopen(first(libstdcxx_paths))
    for minor_version in 26:-1:18
        if Libdl.dlsym(hdl, "GLIBCXX_3.4.$(minor_version)"; throw_error=false) !== nothing
            Libdl.dlclose(hdl)
            return VersionNumber("3.4.$(minor_version)")
        end
    end
    Libdl.dlclose(hdl)
    return nothing
end

"""
    detect_cxxstring_abi()

Inspects the currently running Julia process to see what version of the C++11 string ABI
it was compiled with (this is only relevant if compiled with `g++`; `clang` has no
incompatibilities yet, bless its heart).  In reality, this actually checks for symbols
within LLVM, but that is close enough for our purposes, as you can't mix configurations
between Julia and LLVM; they must match.
"""
function detect_cxxstring_abi()
    # First, if we're not linked against libstdc++, then early-exit because this doesn't matter.
    libstdcxx_paths = filter(x -> occursin("libstdc++", x), Libdl.dllist())
    if isempty(libstdcxx_paths)
        # We were probably built by `clang`; we don't link against `libstdc++`` at all.
        return nothing
    end

    function open_libllvm(f::Function)
        for lib_name in ("libLLVM", "LLVM", "libLLVMSupport")
            hdl = Libdl.dlopen_e(lib_name)
            if hdl != C_NULL
                try
                    return f(hdl)
                finally
                    Libdl.dlclose(hdl)
                end
            end
        end
        error("Unable to open libLLVM!")
    end

    return open_libllvm() do hdl
        # Check for llvm::sys::getProcessTriple(), first without cxx11 tag:
        if Libdl.dlsym_e(hdl, "_ZN4llvm3sys16getProcessTripleEv") != C_NULL
            return :cxx03
        elseif Libdl.dlsym_e(hdl, "_ZN4llvm3sys16getProcessTripleB5cxx11Ev") != C_NULL
            return :cxx11
        else
            @warn("Unable to find llvm::sys::getProcessTriple() in libLLVM!")
            return nothing
        end
    end
end

function detect_compiler_abi(platform::Platform=default_platkey)
    return CompilerABI(;
        libgfortran_version=detect_libgfortran_version(;platform=platform),
        libstdcxx_version=detect_libstdcxx_version(),
        cxxstring_abi=detect_cxxstring_abi(),
    )
end


# Cache the default platform_key_abi() since that's by far the most common way
# we call platform_key_abi(), and we don't want to parse the same thing over
# and over and over again.  Note that we manually slap on a compiler abi
# string onto the end of Sys.MACHINE, like we expect our triplets to be encoded.
# Note futher that manually pass in an incomplete platform_key_abi() to the `detect_*()`
# calls, because we need to know things about dynamic library naming rules and whatnot.
default_platkey = platform_key_abi(string(
    Sys.MACHINE,
    compiler_abi_str(detect_compiler_abi(platform_key_abi(Sys.MACHINE))),
))
function platform_key_abi()
    global default_platkey
    return default_platkey
end

function platforms_match(a::Platform, b::Platform)
    # Check to see if a and b  satisfy the rigid constraints first, these are
    # things that are simple equality checks:
    function rigid_constraints(a, b)
        return (typeof(a) <: typeof(b) || typeof(b) <: typeof(a)) &&
               (arch(a) == arch(b)) && (libc(a) == libc(b)) &&
               (call_abi(a) == call_abi(b))
    end

    # The flexible constraints are ones that can do equals, but also have things
    # like "any" values, etc....
    function flexible_constraints(a, b)
        ac = compiler_abi(a)
        bc = compiler_abi(b)
        gcc_match = (ac.libgfortran_version === nothing
                  || bc.libgfortran_version === nothing
                  || ac.libgfortran_version == bc.libgfortran_version)
        cxx_match = (ac.cxxstring_abi === nothing
                  || bc.cxxstring_abi === nothing
                  || ac.cxxstring_abi == bc.cxxstring_abi)
        return gcc_match && cxx_match
    end

    return rigid_constraints(a, b) && flexible_constraints(a, b)
end

function platforms_match(a::AbstractString, b::Platform)
    @nospecialize b
    return platforms_match(platform_key_abi(a), b)
end
function platforms_match(a::Platform, b::AbstractString)
    @nospecialize a
    return platforms_match(a, platform_key_abi(b))
end
platforms_match(a::AbstractString, b::AbstractString) = platforms_match(platform_key_abi(a), platform_key_abi(b))

"""
    select_platform(download_info::Dict, platform::Platform = platform_key_abi())

Given a `download_info` dictionary mapping platforms to some value, choose
the value whose key best matches `platform`, returning `nothing` if no matches
can be found.

Platform attributes such as architecture, libc, calling ABI, etc... must all
match exactly, however attributes such as compiler ABI can have wildcards
within them such as `nothing` which matches any version of GCC.
"""
function select_platform(download_info::Dict, platform::Platform = platform_key_abi())
    @nospecialize platform
    ps = collect(filter(p -> platforms_match(p, platform), keys(download_info)))

    if isempty(ps)
        return nothing
    end

    # At this point, we may have multiple possibilities.  E.g. if, in the future,
    # Julia can be built without a direct dependency on libgfortran, we may match
    # multiple tarballs that vary only within their libgfortran ABI.  To narrow it
    # down, we just sort by triplet, then pick the last one.  This has the effect
    # of generally choosing the latest release (e.g. a `libgfortran5` tarball
    # rather than a `libgfortran3` tarball)
    p = last(sort(ps, by = p -> triplet(p)))
    return download_info[p]
end

end # module
