using Serialization

function save_pkg_info_file(
    info :: Dict{P,PkgInfo{P,V}},
    path :: AbstractString = tempname(),
) where {P,V}
    open(path, write=true) do io
        write_magic(io)
        serialize(io, P)
        serialize(io, V)
        pv = sort!(collect(keys(info)))
        pm = Dict{P,Int}(p => i for (i, p) in enumerate(pv))
        write_vals(io, pv)
        for p in pv
            d = info[p]
            write_vals(io, d.versions)
            # the matrix is indexed by the partition, so the partition has to
            # be in the file: without it there is no saying which version a row
            # stands for
            write_ints(io, d.classes)
            # a filtered artifact carries the versions redundancy elimination
            # removed, attached to the class that made them removable. They are
            # not in `versions` any more, so they are written as values
            write_int(io, count(!isempty, d.shadows))
            for (c, sh) in enumerate(d.shadows)
                isempty(sh) && continue
                write_int(io, c)
                write_vals(io, sh)
            end
            write_vals(io, pm, d.depends)
            write_vals(io, pm, sort!(collect(keys(d.interacts))))
            write_bits(io, d.conflicts)
        end
    end
    return path
end

function load_pkg_info_file(
    path :: AbstractString,
    :: Type{P⁺} = Any,
    :: Type{V⁺} = Any,
) where {P⁺,V⁺}
    open(path, read=true) do io
        read_magic(io)
        P = deserialize(io)
        V = deserialize(io)
        P <: P⁺ && V <: V⁺ || throw(ArgumentError("""
            Expected pkg info file for types package-version types \
            ($(P⁺),$(V⁺)), got ($P,$V) instead.
            """
        ))
        pv = read_vals(io, P)
        info = Dict{P,PkgInfo{P,V}}()
        for p in pv
            versions  = read_vals(io, V)
            classes   = read_ints(io)
            m         = maximum(classes; init = 0)
            shadows   = no_shadows(V, m)
            for _ = 1:read_int(io, Int)
                c = read_int(io, Int)
                shadows[c] = read_vals(io, V)
            end
            depends   = read_vals(io, pv)
            interacts = read_vals(io, pv)
            conflicts = read_bits(io, padded_rows(m))
            interacts = Dict{P, Int}(q => 0 for q in interacts)
            info[p] = PkgInfo{P,V}(versions, classes, class_members(classes, m),
                shadows, depends, interacts, conflicts)
        end
        # compute interacts dict values: one column block per partner *class*
        for (p, d) in info
            b = length(d.depends)
            for q in sort!(collect(keys(d.interacts)))
                d.interacts[q] = b
                b += nclasses(info[q])
            end
        end
        return info :: Dict{P,PkgInfo{P,V}} where {P<:P⁺,V<:V⁺}
    end
end

## bespoke de/serialization functions ##

const magic = "\xfa\x7d\xe1\0Resolver.jl PkgInfo File\0v4\0"

function write_magic(io::IO)
    write(io, magic)
end

function read_magic(io::IO)
    m = String(read(io, ncodeunits(magic)))
    m == magic && return
    error("""
    Unexpected package data format, magic doesn't match:
        $(repr(m)) != $(repr(magic))
    """)
end

# write LEB128 integer value
function write_int(io::IO, n::Integer)
    @assert n ≥ 0
    more = true
    while more
        b = (n % UInt8) & 0x7f
        n >>= 7
        more = !iszero(n)
        b |= UInt8(more) << 7
        write(io, b)
    end
end

# read LEB128 integer value
function read_int(io::IO, ::Type{T} = Int) where {T<:Integer}
    n::T = s = 0
    while true
        b = read(io, UInt8)
        n |= T(b & 0x7f) << s
        (b % Int8) ≥ 0 && break
        s += 7
    end
    return n
end

function write_ints(io::IO, v::Vector{<:Integer})
    write_int(io, length(v))
    for x in v
        write_int(io, x)
    end
end

function read_ints(io::IO)
    n = read_int(io, Int)
    return Int[read_int(io, Int) for _ = 1:n]
end

function write_vals(io::IO, v::Vector)
    write_int(io, length(v))
    for x in v
        s = x isa String ? x : string(x)
        write_int(io, ncodeunits(s))
        write(io, s)
    end
end

function read_vals(io::IO, ::Type{T}) where {T}
    n = read_int(io, Int)
    v = Vector{T}(undef, n)
    for i = 1:n
        l = read_int(io)
        s = String(read(io, l))
        v[i] = T === String ? s :
               T === Symbol ? Symbol(s) : parse(T, s)
    end
    return v
end

function write_vals(io::IO, inds::Dict{<:Any,<:Integer}, v::Vector)
    write_int(io, length(v))
    for x in v
        write_int(io, inds[x])
    end
end

function read_vals(io::IO, vals::Vector{T}) where {T}
    n = read_int(io)
    v = Vector{T}(undef, n)
    for i = 1:n
        j = read_int(io)
        v[i] = vals[j]
    end
    return v
end

function write_bits(io::IO, X::BitMatrix)
    l = length(X)
    write_int(io, l)
    bytes = @view(reinterpret(UInt8, X.chunks)[1:cld(l,8)])
    write(io, bytes)
end

function read_bits(io::IO, m::Int)
    l = read_int(io)
    n, r = divrem(l, m)
    iszero(r) || error("unexpected bit matrix length: $l not divisible by $m")
    X = BitMatrix(undef, m, n)
    read!(io, @view(reinterpret(UInt8, X.chunks)[1:cld(l,8)]))
    return X
end
