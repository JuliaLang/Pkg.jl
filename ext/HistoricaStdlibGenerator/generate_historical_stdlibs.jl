#!/usr/bin/env julia

using Downloads, JSON3, Base.BinaryPlatforms, Scratch, SHA, Pkg, TOML
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

function generate_nightly_url(jlver, host = HostPlatform())
    # Map arch
    arch_str = Dict("x86_64" => "x64", "i686" => "x86", "aarch64" => "aarch64", "armv7l" => "armv7l", "ppc64le" => "ppc64le")[arch(host)]
    # Map OS name
    os_str = Dict("linux" => "linux", "windows" => "winnt", "macos" => "mac", "freebsd" => "freebsd")[os(host)]
    # Map wordsize tag
    wordsize_str = Dict("x86_64" => "64", "i686" => "32", "aarch64" => "aarch64", "armv7l" => "armv7l", "ppc64le" => "ppc64")[arch(host)]

    # If `jlver` is nothing, we don't namespace by version and just get the absolute latest version
    ver_str = ""
    if jlver !== nothing
        ver_str = string(jlver.major, ".", jlver.minor, "/")
    end

    return string(
        "https://julialangnightlies-s3.julialang.org/bin/",
        # linux/
        os_str, "/",
        # x64/
        arch_str, "/",
        # 1.6/ (or nothing, if `jlver === nothing`)
        ver_str,
        "julia-latest-",
        # linux64
        os_str, wordsize_str,
        ".tar.gz",
    )
end
highest_release = maximum(VersionNumber.(string.(keys(versions))))
next_release = VersionNumber(highest_release.major, highest_release.minor + 1, 0)
push!(version_urls, (generate_nightly_url(next_release), ""))
push!(version_urls, (generate_nightly_url(nothing),      ""))
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
        mount_dir = joinpath(dir, "mount_dir")
        try
            if endswith(installer_path, ".dmg")
                mkdir(mount_dir)
                # Try to mount many times, as this seems to fail randomly
                mount_cmd = `hdiutil mount $(installer_path) -mountpoint $(mount_dir)`
                tries = 0
                while !success(mount_cmd)
                    if tries > 10
                        error("Unable to mount via hdiutil!")
                    end
                    sleep(0.1)
                    tries += 1
                end
                #@show readdir(mount_dir; join=true)
                app_dir = first(filter(d -> startswith(basename(d), "Julia-"), readdir(mount_dir; join=true)))
                symlink(joinpath(app_dir, "Contents", "Resources", "julia", "bin"), joinpath(dir, "bin"))
            elseif endswith(installer_path, ".exe")
                error("This script doesn't work with `.exe` downloads")
            else
                run(`tar -C $(dir) --strip-components=1 -zxf $(installer_path)`)
            end

            jlexe = joinpath(dir, "bin", @static Sys.iswindows() ? "julia.exe" : "julia")
            jlflags = ["--startup-file=no", "-O0"]
            jlvers = VersionNumber(readchomp(`$(jlexe) $(jlflags) -e 'print(VERSION)'`))
            jlvers = VersionNumber(jlvers.major, jlvers.minor, jlvers.patch)
            @info("Auto-detected Julia version $(jlvers)")

            if jlvers < v"1.1"
                stdlibs_str = readchomp(`$(jlexe) $(jlflags) -e 'import Pkg; print(repr(Pkg.Types.gather_stdlib_uuids()))'`)
            else
                stdlibs_str = readchomp(`$(jlexe) $(jlflags) -e 'import Pkg; print(repr(Pkg.Types.load_stdlib()))'`)
            end

            # This will give us a dictionary of UUID => (name, version) mappings for all standard libraries
            if jlvers < v"1.8-"
                stdlibs = Dict{Base.UUID, Tuple{AbstractString,Any}}(uuid => (name, nothing) for (uuid, name) in eval(Meta.parse(stdlibs_str)))

                # We're going to try and get versions for each stdlib:
                stdlib_path = readchomp(`$(jlexe) $(jlflags) -e 'import Pkg; print(Pkg.Types.stdlib_path(""))'`)
                for uuid in keys(stdlibs)
                    # If this stdlib has a `Project.toml`, try to parse it for its version field
                    name = first(stdlibs[uuid])
                    project_path = joinpath(stdlib_path, name, "Project.toml")
                    if isfile(project_path)
                        d = TOML.parsefile(project_path)
                        if haskey(d, "version")
                            stdlibs[uuid] = (name, VersionNumber(d["version"]))
                        end
                    end
                end
            else
                stdlibs = Dict{Base.UUID, Tuple}(uuid => (name, version) for (uuid, (name, version)) in eval(Meta.parse(stdlibs_str)))
            end

            return (jlvers, stdlibs)
        finally
            # Clean up mounted directories
            if isdir(mount_dir)
                unmount_cmd = `hdiutil detach $(mount_dir)`
                tries = 0
                while !success(unmount_cmd)
                    if tries > 10
                        error("Unable to unmount $(mount_dir)")
                    end
                    sleep(0.1)
                    tries += 1
                end
            end
        end
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
                try
                    # We might try to download two files that have the same basename
                    url_tag = bytes2hex(sha256(url))
                    fname = joinpath(scratch_dir, string(url_tag, "-", basename(url)))
                    if !isfile(fname)
                        @info("Downloading $(url)")
                        Downloads.download(url, fname)
                    end

                    if !isempty(hash)
                        calc_hash = bytes2hex(open(io -> sha256(io), fname, "r"))
                        if calc_hash != hash
                            @error("Hash mismatch on $(fname); deleting and re-downloading")
                            rm(fname; force=true)
                            Downloads.download(url, fname)
                            calc_hash = bytes2hex(open(io -> sha256(io), fname, "r"))
                            if calc_hash != hash
                                @error("Hash mismatch on $(fname); re-download failed!")
                                continue
                            end
                        end
                    end

                    version, stdlibs = get_stdlibs(scratch_dir, basename(fname))
                    versions_dict[version] = stdlibs
                catch e
                    if isa(e, InterruptException)
                        rethrow()
                    end
                    @error(e, exception=(e, catch_backtrace()))
                end
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
all_stdlibs = Dict{UUID,Tuple}()
for (julia_ver, stdlibs) in versions_dict
    merge!(all_stdlibs, stdlibs)
end

registries = Pkg.Registry.reachable_registries()
_unregistered_stdlibs_with_vers = filter(all_stdlibs) do (uuid, name)
    return !any(haskey(reg.pkgs, uuid) for reg in registries)
end

# For each entry in `UNREGISTERED_STDLIBS`, set the version number to `nothing`
unregistered_stdlibs = Dict((k, (v[1], nothing)) for (k, v) in pairs(_unregistered_stdlibs_with_vers))

# Helper function for getting these printed out in a nicely-sorted order
function print_sorted(io::IO, d::Dict; indent::Int=0)
    println(io, "Dict{UUID,Tuple{String,Union{VersionNumber,Nothing}}}(")
    for pair in sort(collect(d), by = kv-> kv[2][1])
        println(io, " "^indent, repr(pair[1]), " => ", repr(pair[2]), ",")
    end
    print(io, " "^(max(indent - 4, 0)), ")")
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
        print_sorted(io, versions_dict[v]; indent=8)
        println(io, ",")
    end
    println(io, "]")

    print(io, """
    # Next, we also embed a list of stdlibs that must _always_ be treated as stdlibs,
    # because they cannot be resolved in the registry; they have only ever existed within
    # the Julia stdlib source tree, and because of that, trying to resolve them will fail.
    const UNREGISTERED_STDLIBS = """)
    print_sorted(io, unregistered_stdlibs; indent=4)
    println(io)
end
