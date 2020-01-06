# This file is a part of Julia. License is MIT: https://julialang.org/license

################
# VersionBound #
################
struct VersionBound
    t::NTuple{3,UInt32}
    n::Int
    function VersionBound(tin::NTuple{n,Integer}) where n
        n <= 3 || throw(ArgumentError("VersionBound: you can only specify major, minor and patch versions"))
        n == 0 && return new((0,           0,      0), n)
        n == 1 && return new((tin[1],      0,      0), n)
        n == 2 && return new((tin[1], tin[2],      0), n)
        n == 3 && return new((tin[1], tin[2], tin[3]), n)
        error("invalid $n")
    end
end
VersionBound(t::Integer...) = VersionBound(t)
VersionBound(v::VersionNumber) = VersionBound(v.major, v.minor, v.patch)

Base.getindex(b::VersionBound, i::Int) = b.t[i]

function ≲(v::VersionNumber, b::VersionBound)
    b.n == 0 && return true
    b.n == 1 && return v.major <= b[1]
    b.n == 2 && return (v.major, v.minor) <= (b[1], b[2])
    return (v.major, v.minor, v.patch) <= (b[1], b[2], b[3])
end

function ≲(b::VersionBound, v::VersionNumber)
    b.n == 0 && return true
    b.n == 1 && return v.major >= b[1]
    b.n == 2 && return (v.major, v.minor) >= (b[1], b[2])
    return (v.major, v.minor, v.patch) >= (b[1], b[2], b[3])
end

≳(v::VersionNumber, b::VersionBound) = v ≲ b
≳(b::VersionBound, v::VersionNumber) = b ≲ v

function isless_ll(a::VersionBound, b::VersionBound)
    m, n = a.n, b.n
    for i = 1:min(m, n)
        a[i] < b[i] && return true
        a[i] > b[i] && return false
    end
    return m < n
end

stricterlower(a::VersionBound, b::VersionBound) = isless_ll(a, b) ? b : a

# Comparison between two upper bounds
function isless_uu(a::VersionBound, b::VersionBound)
    m, n = a.n, b.n
    for i = 1:min(m, n)
        a[i] < b[i] && return true
        a[i] > b[i] && return false
    end
    return m > n
end

stricterupper(a::VersionBound, b::VersionBound) = isless_uu(a, b) ? a : b

# `isjoinable` compares an upper bound of a range with the lower bound of the next range
# to determine if they can be joined, as in [1.5-2.8, 2.5-3] -> [1.5-3]. Used by `union!`.
# The equal-length-bounds case is special since e.g. `1.5` can be joined with `1.6`,
# `2.3.4` can be joined with `2.3.5` etc.

function isjoinable(up::VersionBound, lo::VersionBound)
    up.n == 0 && lo.n == 0 && return true
    if up.n == lo.n
        n = up.n
        for i = 1:(n - 1)
            up[i] > lo[i] && return true
            up[i] < lo[i] && return false
        end
        up[n] < lo[n] - 1 && return false
        return true
    else
        l = min(up.n, lo.n)
        for i = 1:l
            up[i] > lo[i] && return true
            up[i] < lo[i] && return false
        end
    end
    return true
end

Base.hash(r::VersionBound, h::UInt) = hash(hash(r.t, h), r.n)

VersionBound(s::AbstractString) =
    s == "*" ? VersionBound() : VersionBound(map(x -> parse(Int, x), split(s, '.'))...)

################
# VersionRange #
################
struct VersionRange
    lower::VersionBound
    upper::VersionBound
    # NOTE: ranges are allowed to be empty; they are ignored by VersionSpec anyway
    function VersionRange(lo::VersionBound, hi::VersionBound)
        # lo.t == hi.t implies that digits past min(lo.n, hi.n) are zero
        # lo.n < hi.n example: 1.2-1.2.0 => 1.2.0
        # lo.n > hi.n example: 1.2.0-1.2 => 1.2
        lo.t == hi.t && (lo = hi)
        return new(lo, hi)
    end
end
VersionRange(b::VersionBound=VersionBound()) = VersionRange(b, b)
VersionRange(t::Integer...)                  = VersionRange(VersionBound(t...))
VersionRange(v::VersionNumber)               = VersionRange(VersionBound(v))

function VersionRange(s::AbstractString)
    m = match(r"^\s*v?((?:\d+(?:\.\d+)?(?:\.\d+)?)|\*)(?:\s*-\s*v?((?:\d+(?:\.\d+)?(?:\.\d+)?)|\*))?\s*$", s)
    m === nothing && throw(ArgumentError("invalid version range: $(repr(s))"))
    lower = VersionBound(m.captures[1])
    upper = m.captures[2] !== nothing ? VersionBound(m.captures[2]) : lower
    return VersionRange(lower, upper)
end

function Base.isempty(r::VersionRange)
    for i = 1:min(r.lower.n, r.upper.n)
        r.lower[i] > r.upper[i] && return true
        r.lower[i] < r.upper[i] && return false
    end
    return false
end

function Base.print(io::IO, r::VersionRange)
    m, n = r.lower.n, r.upper.n
    if (m, n) == (0, 0)
        print(io, '*')
    elseif m == 0
        print(io, "0-")
        join(io, r.upper.t, '.')
    elseif n == 0
        join(io, r.lower.t, '.')
        print(io, "-*")
    else
        join(io, r.lower.t[1:m], '.')
        if r.lower != r.upper
            print(io, '-')
            join(io, r.upper.t[1:n], '.')
        end
    end
end
Base.show(io::IO, r::VersionRange) = print(io, "VersionRange(\"", r, "\")")

Base.in(v::VersionNumber, r::VersionRange) = r.lower ≲ v ≲ r.upper

Base.intersect(a::VersionRange, b::VersionRange) = VersionRange(stricterlower(a.lower, b.lower), stricterupper(a.upper, b.upper))

function Base.union!(ranges::Vector{<:VersionRange})
    l = length(ranges)
    l == 0 && return ranges

    sort!(ranges, lt=(a, b) -> (isless_ll(a.lower, b.lower) || (a.lower == b.lower && isless_uu(a.upper, b.upper))))

    k0 = 1
    ks = findfirst(!isempty, ranges)
    ks === nothing && return empty!(ranges)

    lo, up, k0 = ranges[ks].lower, ranges[ks].upper, 1
    for k = (ks + 1):l
        isempty(ranges[k]) && continue
        lo1, up1 = ranges[k].lower, ranges[k].upper
        if isjoinable(up, lo1)
            isless_uu(up, up1) && (up = up1)
            continue
        end
        vr = VersionRange(lo, up)
        @assert !isempty(vr)
        ranges[k0] = vr
        k0 += 1
        lo, up = lo1, up1
    end
    vr = VersionRange(lo, up)
    if !isempty(vr)
        ranges[k0] = vr
        k0 += 1
    end
    resize!(ranges, k0 - 1)
    return ranges
end

###############
# VersionSpec #
###############
struct VersionSpec
    ranges::Vector{VersionRange}
    VersionSpec(r::Vector{<:VersionRange}) = new(union!(r))
    VersionSpec(vs::VersionSpec) = new(copy(vs.ranges))
end

VersionSpec() = VersionSpec(VersionRange())
VersionSpec(v::VersionNumber) = VersionSpec(VersionRange(v))
VersionSpec(r::VersionRange) = VersionSpec(VersionRange[r])
VersionSpec(s::AbstractString) = VersionSpec(VersionRange(s))
VersionSpec(v::AbstractVector) = VersionSpec(map(VersionRange, v))

# Hot code
function Base.in(v::VersionNumber, s::VersionSpec)
    for r in s.ranges
        v in r && return true
    end
    return false
end

Base.copy(vs::VersionSpec) = VersionSpec(vs)

const empty_versionspec = VersionSpec(VersionRange[])
# Windows console doesn't like Unicode
const _empty_symbol = @static Sys.iswindows() ? "empty" : "∅"

Base.isempty(s::VersionSpec) = all(isempty, s.ranges)
@assert isempty(empty_versionspec)
# Hot code, measure performance before changing
function Base.intersect(A::VersionSpec, B::VersionSpec)
    (isempty(A) || isempty(B)) && return copy(empty_versionspec)
    ranges = Vector{VersionRange}(undef, length(A.ranges) * length(B.ranges))
    i = 1
    @inbounds for a in A.ranges, b in B.ranges
        ranges[i] = intersect(a, b)
        i += 1
    end
    VersionSpec(ranges)
end
Base.intersect(a::VersionNumber, B::VersionSpec) = a in B ? VersionSpec(a) : empty_versionspec
Base.intersect(A::VersionSpec, b::VersionNumber) = intersect(b, A)

Base.union(A::VersionSpec, B::VersionSpec) = union!(copy(A), B)
function Base.union!(A::VersionSpec, B::VersionSpec)
    A == B && return A
    append!(A.ranges, B.ranges)
    union!(A.ranges)
    return A
end

Base.:(==)(A::VersionSpec, B::VersionSpec) = A.ranges == B.ranges
Base.hash(s::VersionSpec, h::UInt) = hash(s.ranges, h + (0x2fd2ca6efa023f44 % UInt))

function Base.print(io::IO, s::VersionSpec)
    isempty(s) && return print(io, _empty_symbol)
    length(s.ranges) == 1 && return print(io, s.ranges[1])
    print(io, '[')
    for i = 1:length(s.ranges)
        1 < i && print(io, ", ")
        print(io, s.ranges[i])
    end
    print(io, ']')
end
Base.show(io::IO, s::VersionSpec) = print(io, "VersionSpec(\"", s, "\")")


###################
# Semver notation #
###################

function semver_spec(spec::String)
    next = parse_spec1(spec, 1)
    isnothing(next) && error("found no version specification")
    ranges = [next[1]]
    next = parse_spec1(spec, next[2])
    while !isnothing(next)
        push!(ranges, next[1])
        next = parse_spec1(spec, next[2])
    end
    return VersionSpec(ranges)
end


# Parser of version specification
# -------------------------------

function parse_spec1(spec::String, i::Int)
    # parse specifier
    i = skipws(spec, i)
    next = parse_specifier(spec, i)
    isnothing(next) && return
    specifier, i = next

    # parse version number
    next = parse_vernum(spec, i)
    isnothing(next) && error("found no version number")
    ver, i = next
    next = iterate(spec, i)
    if isnothing(next) || next[1] == ','
        isnothing(next) || (i = next[2])  # comsume comma
        specifier == '?' && (specifier = '^')  # implicit caret
    elseif isspace(next[1])
        i = skipws(spec, next[2])
        next = iterate(spec, i)
        if isnothing(next) || next[1] == ','
            isnothing(next) || (i = next[2])  # consume comma
            specifier == '?' && (specifier = '^')  # implicit caret
        elseif next[1] == '-'
            specifier == '?' || error("invalid hyphen specifier syntax")
            specifier = '-'
            next = iterate(spec, next[2])
            isnothing(next) && error("incomplete hyphen specifier")
            isspace(next[1]) || error("no space after hyphen specifier")
            i = next[2]
        else
            error("unrecognizable character: $(repr(next[1]))")
        end
    elseif next[1] == '-'
        error("no space before hyphen specifier")
    else
        error("unrecognizable character: $(repr(next[1]))")
    end

    # if not a hyphen specifier, parsing ends.
    specifier == '-' || return interpret_spec(specifier, ver), i

    # parse version number after hyphen
    i = skipws(spec, i)
    next = parse_vernum(spec, i)
    isnothing(next) && error("incomplete hyphen specifier")
    ver2, i = next
    i = skipws(spec, i)
    next = iterate(spec, i)
    !isnothing(next) && next[1] == ',' && (i = next[2])
    return interpret_spec(specifier, ver, ver2), i
end

function parse_specifier(spec::String, i::Int)
    next = iterate(spec, i)
    isnothing(next) && return
    specifier = next[1]
    if isdigit(specifier)
        # implicit caret or hyphen
        specifier = '?'
    elseif specifier ∈ ('^', '~', '=', '≤', '≥')
        # caret, tilde, equal, or one-character inequal
        i = skipws(spec, next[2])
    elseif specifier ∈ ('<', '>')
        # one- or two-character inequal
        i = next[2]
        next = iterate(spec, i)
        if !isnothing(next) && next[1] == '='
            specifier = specifier == '<' ? '≤' : '≥'
            i = next[2]
        end
        i = skipws(spec, i)
    else
        error("invalid version specifier: $(repr(specifier))")
    end
    return specifier, i
end

function parse_vernum(str::String, i::Int)
    # ignore 'v' if any
    next = iterate(str, i)
    isnothing(next) && return
    next[1] == 'v' && (i = next[2])

    # major
    next = parse_decimal(str, i)
    isnothing(next) && return
    major, i = next
    next = iterate(str, i)
    !isnothing(next) && next[1] == '.' ||
        return (ndigits = 1, major = major, minor = 0, patch = 0), i
    i = next[2]

    # minor
    next = parse_decimal(str, i)
    isnothing(next) && error("incomplete version number")
    minor, i = next
    next = iterate(str, i)
    !isnothing(next) && next[1] == '.' ||
        return (ndigits = 2, major = major, minor = minor, patch = 0), i
    i = next[2]

    # patch
    next = parse_decimal(str, i)
    isnothing(next) && error("incomplete version number")
    patch, i = next
    return (ndigits = 3, major = major, minor = minor, patch = patch), i
end

function parse_decimal(str::String, i::Int)
    num = 0
    next = iterate(str, i)
    !isnothing(next) && isdigit(next[1]) || return
    while !isnothing(next) && isdigit(next[1])
        c, i = next
        # TODO: check overflow
        num = 10num + Int(c - '0')
        next = iterate(str, i)
    end
    return num, i
end

function skipws(s::String, i::Int)
    next = iterate(s, i)
    while !isnothing(next) && isspace(next[1])
        i = next[2]
        next = iterate(s, i)
    end
    return i
end


# Interpreter of version specification
# ------------------------------------

function check_version(v::NamedTuple)
    @assert 1 ≤ v.ndigits ≤ 3  # this never happens
    if v.ndigits == 3 && v.major == v.minor == v.patch == 0
        error("invalid version: 0.0.0")
    end
end

# unary specifier
function interpret_spec(specifier::Char, ver::NamedTuple)
    check_version(ver)
    n = ver.ndigits
    major, minor, patch = ver.major, ver.minor, ver.patch
    b = VersionBound(major, minor, patch)
    lo = VersionBound(0, 0, 0)
    up = VersionBound()
    if specifier == '^'
        lo = b
        up = n == 1 || major != 0 ? VersionBound(major) :
             n == 2 || minor != 0 ? VersionBound(0, minor) :
             VersionBound(0, 0, patch)
    elseif specifier == '~'
        lo = b
        up = n == 1 ? VersionBound(major) : VersionBound(major, minor)
    elseif specifier == '='
        lo = up = b
    elseif specifier == '≤'
        up = b
    elseif specifier == '<'
        up = patch == 0 && minor == 0 ? VersionBound(major-1) :
             patch == 0 && minor != 0 ? VersionBound(major, minor-1) :
             VersionBound(major, minor, patch-1)
    elseif specifier == '≥'
        lo = b
    elseif specifier == '>'
        lo = patch == 0 && minor == 0 ? VersionBound(major+1) :
             patch == 0 && minor != 0 ? VersionBound(major, minor+1) :
             VersionBound(major, minor, patch+1)
    else
        @assert false
    end
    return VersionRange(lo, up)
end

# binary specifier
function interpret_spec(specifier::Char, ver1::NamedTuple, ver2::NamedTuple)
    check_version(ver1)
    check_version(ver2)
    @assert specifier == '-'  # the only supported binary specifier
    n = ver1.ndigits
    major, minor, patch = ver1.major, ver1.minor, ver1.patch
    lo = n == 1 ? VersionBound(major) :
         n == 2 ? VersionBound(major, minor) :
         VersionBound(major, minor, patch)
    n = ver2.ndigits
    major, minor, patch = ver2.major, ver2.minor, ver2.patch
    up = n == 1 ? VersionBound(major) :
         n == 2 ? VersionBound(major, minor) :
         VersionBound(major, minor, patch)
    return VersionRange(lo, up)
end
