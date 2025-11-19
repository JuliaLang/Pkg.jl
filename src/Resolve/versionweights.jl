# This file is a part of Julia. License is MIT: https://julialang.org/license

# The numeric type used to determine how the different
# versions of a package should be weighed
struct VersionWeight
    major::Int64
    minor::Int64
    patch::Int64
end
VersionWeight(major::Integer, minor::Integer) = VersionWeight(major, minor, 0)
VersionWeight(major::Integer) = VersionWeight(major, 0)
VersionWeight() = VersionWeight(0)
VersionWeight(vn::VersionNumber) = VersionWeight(vn.major, vn.minor, vn.patch)

Base.zero(::Type{VersionWeight}) = VersionWeight()

Base.typemin(::Type{VersionWeight}) = (x = typemin(Int64); VersionWeight(x, x, x))

Base.:(-)(a::VersionWeight, b::VersionWeight) =
    VersionWeight(a.major - b.major, a.minor - b.minor, a.patch - b.patch)

Base.:(+)(a::VersionWeight, b::VersionWeight) =
    VersionWeight(a.major + b.major, a.minor + b.minor, a.patch + b.patch)

Base.:(-)(a::VersionWeight) =
    VersionWeight(-a.major, -a.minor, -a.patch)

function Base.isless(a::VersionWeight, b::VersionWeight)
    return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
end

Base.abs(a::VersionWeight) =
    VersionWeight(abs(a.major), abs(a.minor), abs(a.patch))

# This isn't nice, but it's for debugging only anyway
function Base.show(io::IO, a::VersionWeight)
    print(io, "(", a.major)
    a == VersionWeight(a.major) && @goto done
    print(io, ".", a.minor)
    a == VersionWeight(a.major, a.minor) && @goto done
    print(io, ".", a.patch)
    @label done
    return print(io, ")")
end
