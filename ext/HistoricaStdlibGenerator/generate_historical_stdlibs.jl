#!/usr/bin/env julia

using Downloads, JSON3, Base.BinaryPlatforms, Scratch, SHA, Pkg
using Base: UUID

# Download versions.json, start iterating over Julia versions
versions_json_url = "https://julialang-s3.julialang.org/bin/versions.json"
num_concurrent_downloads = 8

@info("Downloading versions.json...")
json_buff = IOBuffer()
Downloads.download(versions_json_url, json_buff)
versions_json = JSON3.read(String(take!(json_buff)))

# Collect all versions that are >= 1.0.0, and are a stable release
versions = filter(versions_json) do (v, d)
    if VersionNumber(string(v)) < v"1.0.0"
        return false
    end
    if !d["stable"]
        return false
    end
    return true
end

# Build download URLs for each one, and then tack on the next release as well
function select_url_hash(data, host = HostPlatform())
    d = first(filter(f -> platforms_match(f.triplet, host), data.files))
    return (d.url, d.sha256)
end
version_urls = sort(select_url_hash.(values(versions)), by = pair -> pair[1])

function generate_nightly_url(major, minor, host = HostPlatform())
    # Map arch
    arch_str = Dict("x86_64" => "x64", "i686" => "x86", "aarch64" => "aarch64", "armv7l" => "armv7l", "ppc64le" => "ppc64le")[arch(host)]
    # Map OS name
    os_str = Dict("linux" => "linux", "windows" => "winnt", "macos" => "macos", "freebsd" => "freebsd")[os(host)]    
    # Map wordsize tag
    wordsize_str = Dict("x86_64" => "64", "i686" => "32", "aarch64" => "aarch64", "armv7l" => "armv7l", "ppc64le" => "ppc64")[arch(host)]

    return string(
        "https://julialangnightlies-s3.julialang.org/bin/",
        # linux/
        os_str, "/",
        # x64/
        arch_str, "/",
        # 1.6/
        string(major), ".", string(minor), "/",
        "julia-latest-",
        # linux64
        os(host), wordsize_str,
        ".tar.gz",
    )
end
highest_release = maximum(VersionNumber.(string.(keys(versions))))
next_release_url = generate_nightly_url(highest_release.major, highest_release.minor + 1)
push!(version_urls, (next_release_url, ""))
@info("Identified $(length(version_urls)) versions to try...")

# Next, we're going to download each of these to a scratch space
scratch_dir = @get_scratch!("julia_installers")

# Ensure we always download the nightly
rm(joinpath(scratch_dir, basename(last(version_urls)[1])); force=true)

# Helper function to print out stdlibs from a Julia installation
function get_stdlibs(scratch_dir, julia_installer_name)
    installer_path = joinpath(scratch_dir, julia_installer_name)
    mktempdir() do dir
        @info("Extracting $(julia_installer_name)")
        run(`tar -C $(dir) --strip-components=1 -zxf $(installer_path)`)

        jlexe = joinpath(dir, "bin", @static Sys.iswindows() ? "julia.exe" : "julia")
        jlflags = ["--startup-file=no", "-O0"]
        jlvers = VersionNumber(readchomp(`$(jlexe) $(jlflags) -e 'print(VERSION)'`))
        jlvers = VersionNumber(jlvers.major, jlvers.minor, jlvers.patch)
        @info("Auto-detected Julia version $(jlvers)")

        if jlvers < v"1.1"
            stdlibs_str = readchomp(`$(jlexe) $(jlflags) -e 'import Pkg; println(repr(Pkg.Types.gather_stdlib_uuids()))'`)
        else
            stdlibs_str = readchomp(`$(jlexe) $(jlflags) -e 'import Pkg; println(repr(Pkg.Types.load_stdlib()))'`)
        end
        return (jlvers, stdlibs_str)
    end
end

jobs = Channel()
versions_dict = Dict()

@sync begin
    # Feeder task
    @async begin
        for (url, hash) in version_urls
            put!(jobs, (url, hash))
        end
        close(jobs)
    end

    # Consumer tasks
    for _ in 1:num_concurrent_downloads
        @async begin
            for (url, hash) in jobs
                fname = joinpath(scratch_dir, basename(url))
                if !isfile(fname)
                    @info("Downloading $(url)")
                    Downloads.download(url, fname)
                end

                if !isempty(hash)
                    calc_hash = bytes2hex(open(io -> sha256(io), fname, "r"))
                    if calc_hash != hash
                        @error("Hash mismatch on $(fname)")
                    end
                end

                version, stdlibs = get_stdlibs(scratch_dir, basename(url))
                versions_dict[version] = eval(Meta.parse(stdlibs))
            end
        end
    end
end

# Next, drop versions that are the same as the one "before" them:
sorted_versions = sort(collect(keys(versions_dict)))
versions_to_drop = VersionNumber[]
for idx in 2:length(sorted_versions)
    if versions_dict[sorted_versions[idx-1]] == versions_dict[sorted_versions[idx]]
        push!(versions_to_drop, sorted_versions[idx])
    end
end
for v in versions_to_drop
    delete!(versions_dict, v)
end

# Next, figure out which stdlibs are actually unresolvable, because they've never been registered
all_stdlibs = Dict{UUID,String}()
for (julia_ver, stdlibs) in versions_dict
    merge!(all_stdlibs, stdlibs)
end

registries = Pkg.Registry.reachable_registries()
unregistered_stdlibs = filter(all_stdlibs) do (uuid, name)
    return !any(haskey(reg.pkgs, uuid) for reg in registries)
end

# Helper function for getting these printed out in a nicely-sorted order
function print_sorted(io::IO, d::Dict)
    println(io, "Dict(")
    for pair in sort(collect(d), by = kv-> kv[2])
        println(io, "        ", pair, ",")
    end
    println(io, "    ),")
end

output_fname = joinpath(dirname(dirname(@__DIR__)), "src", "HistoricalStdlibs.jl")
@info("Outputting to $(output_fname)")
sorted_versions = sort(collect(keys(versions_dict)))
open(output_fname, "w") do io
    print(io, """
    ## This file autogenerated by ext/HistoricalStdlibGenerator/generate_historical_stdlibs.jl

    using Base: UUID

    # Julia standard libraries with duplicate entries removed so as to store only the
    # first release in a set of releases that all contain the same set of stdlibs.
    const STDLIBS_BY_VERSION = [
    """)
    for v in sorted_versions
        print(io, "    $(repr(v)) => ")
        print_sorted(io, versions_dict[v])
    end
    println(io, "]")

    print(io, """
    # Next, we also embed a list of stdlibs that must _always_ be treated as stdlibs,
    # because they cannot be resolved in the registry; they have only ever existed within
    # the Julia stdlib source tree, and because of that, trying to resolve them will fail.
    const UNREGISTERED_STDLIBS = Dict(
    """)
    for (uuid, name) in unregistered_stdlibs
        println(io, "    $(repr(uuid)) => $(repr(name)),")
    end
    println(io, ")")
end
