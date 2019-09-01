module Infos

export PackageInfo, ProjectInfo

using  UUIDs

###
### PackageInfo
###

Base.@kwdef struct PackageInfo
    name::String
    version::Union{Nothing,VersionNumber}
    ispinned::Bool
    isdeveloped::Bool
    source::String
    dependencies::Vector{UUID}
end

###
### ProjectInfo
###

Base.@kwdef struct ProjectInfo
    name::String
    uuid::UUID
    version::VersionNumber
    dependencies::Dict{String,UUID}
    path::String
end

end #module
