module Compress

import Pkg.TOML
import Pkg.Types: VersionSpec, compress_versions

function load_versions(path::String)
    versions_file = joinpath(dirname(path), "Versions.toml")
    versions_dict = TOML.parsefile(versions_file)
    sort!([VersionNumber(v) for v in keys(versions_dict)])
end

function load(path::String,
    versions::Vector{VersionNumber} = load_versions(path))
    compressed = TOML.parsefile(path)
    uncompressed = Dict{VersionNumber,Dict{Any,Any}}()
    for (vers, data) in compressed
        vs = VersionSpec(vers)
        for v in versions
            v in vs || continue
            merge!(get!(uncompressed, v, Dict()), deepcopy(data))
        end
    end
    return uncompressed
end

function compress(path::String, uncompressed::Dict,
    versions::Vector{VersionNumber} = load_versions(path))
    inverted = Dict()
    for (ver, data) in uncompressed, (key, val) in data
        val isa TOML.TYPE || (val = string(val))
        push!(get!(inverted, key => val, VersionNumber[]), ver)
    end
    compressed = Dict()
    for ((k, v), vers) in inverted
        for r in compress_versions(versions, sort!(vers)).ranges
            get!(compressed, string(r), Dict{String,Any}())[k] = v
        end
    end
    return compressed
end

function save(path::String, uncompressed::Dict,
    versions::Vector{VersionNumber} = load_versions(path))
    compressed = compress(path, uncompressed)
    open(path, write=true) do io
        TOML.print(io, compressed, sorted=true)
    end
end

end # module
