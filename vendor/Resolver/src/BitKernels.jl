# Every PkgInfo conflicts matrix is allocated with its row dimension padded
# to a whole number of 64-bit words (see padded_rows), so that column j
# occupies exactly the aligned chunk words X.chunks[(j-1)*W .+ (1:W)] where
# W = size(X, 1) >> 6. Class i of the package corresponds to bit i-1 of that
# span; the row after the last class holds the column's in-universe flag; any
# rows beyond that are padding and must remain zero. The helpers below are the
# word-parallel column primitives the filtering passes build on.
#
## What the flags mean
#
# A class carries two independent facts, and they are stored in two different
# places:
#
#   1. **in-universe** — "this class is still part of the problem". This is the
#      flag in the matrix: X[i, end] for class i, and X[end, j] for column j
#      (a partner's block of columns mirrors that partner's own class flags).
#      Three passes clear it, and all three of them mean "delete": the
#      installability prune (`mark_installable!`), reachability
#      (`mark_reachable!`) and redundancy elimination (`mark_necessary!`).
#      `drop_unmarked!` reads this flag and nothing else, and rebuilds each
#      matrix without whatever it says is gone.
#
#   2. **activated** — "this query admits some member of this class". Class
#      members are indistinguishable to everything in the registry, so a user
#      constraint can only forbid members; a class all of whose members it
#      forbids is *empty*, hence *deactivated*, and cannot be selected. This
#      fact is not in the matrix at all: it is `Universe.reps[p][i] == 0`,
#      per-resolve state, which `deactivations` turns into a per-package mask
#      for the passes that want it. `Universe`'s docstring says why it is kept
#      there rather than in a flag of its own.
#
# **Deactivation never implies deletion.** A deactivated class stays
# in-universe: it keeps its row, its column in every partner, and its
# dependency columns. It is the universe a later relaxation of whatever emptied
# it would need to find still there.
#
# The passes read the two facts differently, and deliberately so:
#
#   * `find_reachable` keeps, per package, every class some relaxation of the
#     query could put first, and stops at the first one it can install. A
#     deactivated class cannot be selected, so the walk has to continue past
#     it — while its dependencies are followed anyway, which is what keeps the
#     packages behind it in the universe. Its own drops clear the in-universe
#     flag.
#   * `mark_necessary!` takes deactivated classes off *both* sides of the
#     domination test: they may not be deleted (a relaxation would want them
#     back) and they may not dominate (domination says a better class will be
#     selected instead, which is worth nothing when that class cannot be).
#     The test itself reads only the rows, so a conflict against a deactivated
#     *partner* class still counts.
#   * `drop_unmarked!` reads the in-universe flag only. It never learns about
#     deactivation at all.
#
# The two must not be conflated, whichever way round. Treating an emptied class
# as not-in-universe would have `drop_unmarked!` delete it, so a relaxation of
# whatever emptied it would find it gone; and it would make
# `mark_necessary!`'s partner-column test — which ANDs in the partner's own
# in-universe flag — treat a conflict against an emptied partner class as
# vacuous, which can license a deletion that same relaxation needs undone.

# rows to allocate for a package with m classes:
# m class rows plus the flag row, rounded up to whole words
padded_rows(m::Int) = 64 * cld(m + 1, 64)

# number of 64-bit words per column
col_words(X::BitMatrix) = size(X, 1) >> 6

# copy column j of X into buf[1:W]
function col_copy!(buf::Vector{UInt64}, X::BitMatrix, j::Int)
    W = col_words(X)
    base = (j - 1) * W
    chunks = X.chunks
    @inbounds for w = 1:W
        buf[w] = chunks[base + w]
    end
    return buf
end

# does column j of X intersect the row set in buf?
function col_intersects(X::BitMatrix, j::Int, buf::Vector{UInt64})
    W = col_words(X)
    base = (j - 1) * W
    chunks = X.chunks
    @inbounds for w = 1:W
        iszero(chunks[base + w] & buf[w]) || return true
    end
    return false
end

# clear the bits of buf corresponding to rows above m (flag row & padding)
function clear_rows_above!(buf::Vector{UInt64}, m::Int)
    wt = (m + 63) >> 6
    @inbounds for w = wt + 1:length(buf)
        buf[w] = 0
    end
    r = m & 63
    if r != 0 && 1 ≤ wt ≤ length(buf)
        @inbounds buf[wt] &= (UInt64(1) << r) - 1
    end
    return buf
end

# copy len bits from the (word-aligned) column j of X into dest,
# starting at 0-based bit offset off
function copy_col_bits!(dest::Vector{UInt64}, off::Int, X::BitMatrix, j::Int, len::Int)
    W = col_words(X)
    base = (j - 1) * W
    src = X.chunks
    wd = (off >> 6) + 1
    sh = off & 63
    s = 0
    @inbounds while len > 0
        s += 1
        take = min(64, len)
        mask = take == 64 ? ~UInt64(0) : (UInt64(1) << take) - 1
        chunk = src[base + s] & mask
        dest[wd] = (dest[wd] & ~(mask << sh)) | (chunk << sh)
        hi = 64 - sh
        if sh != 0 && take > hi
            dest[wd + 1] = (dest[wd + 1] & ~(mask >> hi)) | (chunk >> hi)
        end
        len -= take
        wd += 1
    end
    return dest
end

# rows of a conflicts matrix are strided across the column spans, so the two
# primitives the interchangeability test needs read them bit by bit: a hash of
# row i over the first n columns, and exact equality of rows i and j over them

function row_hash(X::BitMatrix, i::Int, n::Int, W::Int)
    chunks = X.chunks
    wi = ((i - 1) >> 6) + 1
    bi = (i - 1) & 63
    h = zero(UInt)
    acc = UInt64(0)
    nb = 0
    @inbounds for k = 1:n
        acc |= ((chunks[(k - 1) * W + wi] >> bi) & 1) << nb
        nb += 1
        if nb == 64
            h = hash(acc, h)
            acc = UInt64(0)
            nb = 0
        end
    end
    nb > 0 && (h = hash(acc, h))
    return h
end

function rows_equal(X::BitMatrix, i::Int, j::Int, n::Int, W::Int)
    chunks = X.chunks
    wi = ((i - 1) >> 6) + 1
    bi = (i - 1) & 63
    wj = ((j - 1) >> 6) + 1
    bj = (j - 1) & 63
    @inbounds for k = 1:n
        base = (k - 1) * W
        ((chunks[base + wi] >> bi) & 1) ==
        ((chunks[base + wj] >> bj) & 1) || return false
    end
    return true
end

# highest set row ≤ hi in column j of X, or 0 if none
function col_max_upto(X::BitMatrix, j::Int, hi::Int)
    hi ≤ 0 && return 0
    W = col_words(X)
    base = (j - 1) * W
    chunks = X.chunks
    w = (hi + 63) >> 6
    @inbounds c = chunks[base + w]
    r = hi & 63
    r != 0 && (c &= (UInt64(1) << r) - 1)
    while true
        iszero(c) || return ((w - 1) << 6) + (64 - leading_zeros(c))
        w -= 1
        w == 0 && return 0
        @inbounds c = chunks[base + w]
    end
end

# lowest set row in lo:hi of column j of X, or 0 if none
function col_min_from(X::BitMatrix, j::Int, lo::Int, hi::Int)
    lo ≤ 0 && (lo = 1)
    hi < lo && return 0
    W = col_words(X)
    base = (j - 1) * W
    chunks = X.chunks
    wh = (hi + 63) >> 6
    w = ((lo - 1) >> 6) + 1
    @inbounds c = chunks[base + w] & (~UInt64(0) << ((lo - 1) & 63))
    while true
        if w == wh
            r = hi & 63
            r != 0 && (c &= (UInt64(1) << r) - 1)
        end
        iszero(c) || return ((w - 1) << 6) + trailing_zeros(c) + 1
        w == wh && return 0
        w += 1
        @inbounds c = chunks[base + w]
    end
end
