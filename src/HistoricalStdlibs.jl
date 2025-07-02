using Base: UUID

struct StdlibInfo
    name::String
    uuid::UUID

    # This can be `nothing` if it's an unregistered stdlib
    version::Union{Nothing, VersionNumber}

    deps::Vector{UUID}
    weakdeps::Vector{UUID}
end

const DictStdLibs = Dict{UUID, StdlibInfo}

# Julia standard libraries with duplicate entries removed so as to store only the
# first release in a set of releases that all contain the same set of stdlibs.
#
# This needs to be populated via HistoricalStdlibVersions.jl by consumers
# (e.g. BinaryBuilder) that want to use the "resolve things as if it were a
# different Julia version than what is currently running" feature.
const STDLIBS_BY_VERSION = Pair{VersionNumber, DictStdLibs}[]

# This is a list of stdlibs that must _always_ be treated as stdlibs,
# because they cannot be resolved in the registry; they have only ever existed within
# the Julia stdlib source tree, and because of that, trying to resolve them will fail.
const UNREGISTERED_STDLIBS = DictStdLibs()
