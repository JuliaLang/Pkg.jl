using Base: UUID

struct StdlibInfo
    name::String
    uuid::UUID

    # This can be `nothing` if it's an unregistered stdlib
    version::Union{Nothing, VersionNumber}

    deps::Vector{UUID}
    weakdeps::Vector{UUID}
end

# Base info struct for stdlib segments (excludes version)
Base.@kwdef struct StdlibBaseInfo
    name::String
    uuid::UUID
    deps::Vector{UUID} = UUID[]
    weakdeps::Vector{UUID} = UUID[]
end

# Segment struct that combines base info with version ranges
Base.@kwdef struct StdlibSegment
    base_info::StdlibBaseInfo
    version_ranges::Vector{Pair{Tuple{VersionNumber, VersionNumber}, Union{Nothing, VersionNumber}}}
end

const DictStdLibs = Dict{UUID, StdlibInfo}

# Load the compressed version map data structure
include(joinpath(@__DIR__, "..", "data", "version_map_compressed.jl"))

# Populated by HistoricalStdlibVersions.jl, used if we have a version later than we know about
const STDLIBS_BY_VERSION = Pair{VersionNumber, DictStdLibs}[]

"""
    query_stdlib_segments(julia_version::VersionNumber) -> DictStdLibs

Query the compressed stdlib segments to build a dictionary of stdlib info
for the given Julia version. Returns a Dict{UUID, StdlibInfo} containing
all stdlibs available for that Julia version.
"""
function query_stdlib_segments(julia_version::VersionNumber)
    result = DictStdLibs()

    # Normalize the julia_version to just major.minor.patch
    jv = VersionNumber(julia_version.major, julia_version.minor, julia_version.patch)

    # Iterate through all stdlib UUIDs in the segments
    for (uuid, segments) in STDLIB_SEGMENTS
        # For each stdlib, find the segment and version range that matches
        for segment in segments
            for (range, pkg_version) in segment.version_ranges
                min_v, max_v = range
                # Check if julia_version falls within this range
                if jv >= min_v && jv <= max_v
                    # Found the matching range, create StdlibInfo
                    result[uuid] = StdlibInfo(
                        segment.base_info.name,
                        segment.base_info.uuid,
                        pkg_version,
                        segment.base_info.deps,
                        segment.base_info.weakdeps
                    )
                    @goto next_stdlib
                end
            end
        end
        @label next_stdlib
    end

    return result
end

"""
    version_covered_by_segments(julia_version::VersionNumber) -> Bool

Check if the given Julia version is covered by at least one stdlib in STDLIB_SEGMENTS.
Returns false if the version is outside all recorded ranges, indicating we should
fall back to STDLIBS_BY_VERSION.
"""
function version_covered_by_segments(julia_version::VersionNumber)
    # Normalize the julia_version to just major.minor.patch
    jv = VersionNumber(julia_version.major, julia_version.minor, julia_version.patch)

    # Check if any stdlib has a range that covers this version
    for (uuid, segments) in STDLIB_SEGMENTS
        for segment in segments
            for (range, pkg_version) in segment.version_ranges
                min_v, max_v = range
                if jv >= min_v && jv <= max_v
                    return true
                end
            end
        end
    end

    return false
end
