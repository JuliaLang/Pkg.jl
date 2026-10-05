"""
    Universe{P,V}

The universe a single resolve is run against: one
[`PkgInfo`](@ref Resolver.PkgInfo) per package, plus `reps` — per package, per
class, the index into that package's `versions` of the member the class stands
for under this query, or `0` when the query admits none of them.

`info` carries the package universe ([`pkg_info`](@ref Resolver.pkg_info)) and
`reps` carries everything the query determines about it. A user constraint acts
by forbidding *members* of classes. Class members are indistinguishable to
everything in the registry, so forbidding some of them only changes which one
stands for the class; forbidding all of them leaves the class **empty**, hence
**deactivated** — it cannot be selected.

Deactivated classes are **not** deleted. They stay in the matrices as the
columns a later relaxation of whatever emptied them would need, and the passes
read the deactivation the way they read a conflict with an always-present
version: reachability continues its prefix past a deactivated class while still
following its dependencies, redundancy elimination neither deletes one nor lets
one license a deletion, and the SAT instance forbids each of them with one
relaxable unit clause. BitKernels.jl's header spells out how a class's
*in-universe* flag in the matrix and its *activated* state here divide the work.

## Why deactivation is read off `reps`

`reps` has to exist regardless: a class's representative is what names the
version in the answer, and it is what the class competes at when the classes
are ranked. A class the query admits no member of simply has no representative,
so "unavailable for this query" costs nothing extra to represent. A second flag
bit in the matrix would work equally well; it would just encode a fact `reps`
already carries.

## Why the query's state is separate from the artifact

The invariant worth protecting is that the artifact `info` is
*query-independent*: it is a function of the registry alone, `PkgInfoFiles`
writes and reads it, and one of them answers every query, whatever that query
constrains or prefers. `reps` is the opposite — one query's worth of state,
recomputed per resolve.

Keeping the two in separate values is what makes that invariant checkable
rather than merely intended. Were `reps` a field of `PkgInfo`, the persisted
type would contain query state: serialization would have to know to skip it,
and a freshly loaded artifact would carry a field whose only honest value is
"not computed yet" — with `0`, which means *deactivated*, as its natural
uninitialized value, so forgetting to fill it in yields a universe where
nothing can be selected rather than an error. Whatever shape this ends up
taking, that is the property it has to preserve: nothing a query decides may
be reachable from the thing that gets cached and shared.
"""
struct Universe{P,V}
    info :: Dict{P, PkgInfo{P,V}}
    reps :: Dict{P, Vector{Int}}
    # per package, `(key_Q, key_∅)` per class: the version rank the class
    # competes at under this query, and the rank of its best member with
    # nothing forbidden. The filter's licence to delete is a comparison of the
    # two (see the relaxation-stability page). Carried alongside `reps` and
    # renumbered with it.
    ranks :: Union{Nothing, Tuple{Dict{P,Vector{Int}}, Dict{P,Vector{Int}}}}
end

Universe{P,V}(
    info :: Dict{P, PkgInfo{P,V}},
    reps :: Dict{P, Vector{Int}},
) where {P,V} = Universe{P,V}(info, reps, nothing)

# the universe an unconstrained query makes of an artifact: every class stands
# for its first member (the canonical order's best), nothing is deactivated
default_reps(info::AbstractDict{P, PkgInfo{P,V}}) where {P,V} =
    Dict{P,Vector{Int}}(
        p => Int[first(mem) for mem in info_p.members]
        for (p, info_p) in info)

Universe(info::Dict{P, PkgInfo{P,V}}) where {P,V} =
    Universe{P,V}(info, default_reps(info))
Universe(info::AbstractDict{P, PkgInfo{P,V}}) where {P,V} =
    Universe{P,V}(Dict{P, PkgInfo{P,V}}(info), default_reps(info))

# per package, a mask of its deactivated (empty) classes — only for the
# packages that have one, so that an unconstrained resolve, where there are
# none at all, does no per-class work downstream
function deactivations(univ::Universe{P,V}) where {P,V}
    deact = Dict{P,BitVector}()
    for (p, reps_p) in univ.reps
        any(iszero, reps_p) || continue
        deact[p] = BitVector(iszero(r) for r in reps_p)
    end
    return isempty(deact) ? EmptyDict{P,BitVector}() : deact
end

"""
    version_permutations(info, order) :: Union{Nothing, Dict{P, Vector{Int}}}

Per package, the permutation that puts its versions into the ordering `order`
asks for: `perm[r]` is the index, in the T1 version list, of the `r`-th best
version. Only the packages that actually need reordering get an entry, and the
whole result is `nothing` when none of them do — so the *canonical* order, which
is the one the T1 artifact carries, costs nothing.

`order` is `nothing` for the canonical order, or a callable mapping a package to
a `lt` comparator over its versions (`lt(u, v)` = "u is preferred to v"). The
ordering is the one query knob that is not a *constraint*: it does not change
which solutions are valid, only which valid solution is optimal. That is why it
is a `resolve` parameter rather than part of the [`Problem`](@ref), and why the
T1 artifact can be built and cached without knowing it (see the manual's Theory
section, on order-free deletion and on interchangeability classes being
ordering-independent while the representative choice is not).

This is the ordering of *versions*; what the universe is laid out in is the
ordering of *classes* it induces, which is
[`class_ranking`](@ref Resolver.class_ranking)'s business.
"""
version_permutations(
    info  :: AbstractDict{P, PkgInfo{P,V}},
    order :: Nothing,
) where {P,V} = nothing

function version_permutations(
    info  :: AbstractDict{P, PkgInfo{P,V}},
    order,
) where {P,V}
    perms = Dict{P, Vector{Int}}()
    for (p, info_p) in info
        vers = info_p.versions
        lt = order(p)
        # the common case by far — a comparator that agrees with the canonical
        # order, e.g. "newest first" on a registry that already lists versions
        # that way — is detected in one linear pass and costs nothing more
        issorted(vers; lt) && continue
        perms[p] = sortperm(vers; lt, alg = MergeSort)
    end
    return isempty(perms) ? nothing : perms
end

"""
    SparsePerm <: AbstractVector{Int}

A permutation of `1:n` stored as the positions it moves: the pairs
`(i, p[i])` for every `i` with `p[i] != i`, ascending in `i`. A permutation
close to the identity costs what it displaces rather than what it spans, and
the identity costs nothing at all.

Indexing is a search over those pairs — short, since there are few — and
`invperm` is the pairs swapped and re-sorted, so neither direction ever touches
the positions that did not move.
"""
struct SparsePerm <: AbstractVector{Int}
    n     :: Int
    moved :: Vector{Tuple{Int,Int}}
end

Base.size(p::SparsePerm) = (p.n,)

Base.@propagate_inbounds function Base.getindex(p::SparsePerm, i::Int)
    @boundscheck checkbounds(p, i)
    k = searchsortedfirst(p.moved, i; by = first)
    return @inbounds k ≤ length(p.moved) && p.moved[k][1] == i ? p.moved[k][2] : i
end

Base.invperm(p::SparsePerm) =
    SparsePerm(p.n, sort!(Tuple{Int,Int}[(j, i) for (i, j) in p.moved]))

"""
    class_ranking(info, prob, perms) :: (reps, perms′)

What a query makes of an artifact's classes, before anything is materialized:
per package, which member each class stands for (`reps`, a version index per
class, `0` for a class with no admissible member) and how the classes have to be
reordered to be in rank order (`perms′`, an entry per package that needs it,
`nothing` when none does).

**Representative.** A class's members are indistinguishable to the registry, so
the only thing a user constraint can do to a class is forbid some of its
members. What is left, the class *admits*; the best of those in the active
version ordering — `perms`, see
[`version_permutations`](@ref Resolver.version_permutations) — represents it.
A class admitting nothing is empty, hence deactivated, and has no
representative.

**Rank.** A class ranks where the member it stands for ranks, because that is
the version choosing it yields: a class whose best member is forbidden competes
at its best *admissible* member, and can therefore fall behind classes it
outranks in the artifact. An empty class ranks where its best member would, the
position it would compete from if the constraint that emptied it were lifted.
Every class's key is a distinct version rank, so this is a total order.

Both outputs are per-resolve state: the partition they index is the registry's,
but which member stands for a class, and hence how the classes are ordered,
belongs to the query.
"""
class_ranking(
    info  :: AbstractDict{P, PkgInfo{P,V}},
    prob  :: Problem{P} = Problem(P[]),
    perms :: Union{Nothing, AbstractDict{P, Vector{Int}}} = nothing,
) where {P,V} = class_ranking_keys(info, prob, perms, false)[1:2]

# `class_ranking` plus, when `want_keys`, the two per-class rank keys the
# filter's deletion rules compare: `key_Q` (what `key` below already is) and
# `key_∅`, the rank of the class's best member ignoring the query's
# exclusions. Both are returned in the *post-permutation* class layout, like
# `reps` after `copy_ranked!` — i.e. permuted by `perms′` where there is one.
function class_ranking_keys(
    info  :: AbstractDict{P, PkgInfo{P,V}},
    prob  :: Problem{P},
    perms :: Union{Nothing, AbstractDict{P, Vector{Int}}},
    want_keys :: Bool,
) where {P,V}
    excl = exclusion_masks(info, prob)
    reps = Dict{P, Vector{Int}}()
    perms′ = Dict{P, SparsePerm}()
    keys_q = want_keys ? Dict{P, Vector{Int}}() : nothing
    keys_0 = want_keys ? Dict{P, Vector{Int}}() : nothing
    ord = Int[] # scratch: the class order, read out into a `SparsePerm`
    key = Int[] # scratch: per class, the rank of the member it competes at
    key0 = Int[] # scratch: per class, the rank of its best member, period
    for (p, info_p) in info
        m = nclasses(info_p)          # one entry of `reps` and `key` per class
        nv = length(info_p.versions)  # ... walking this many versions to fill them
        cls = info_p.classes
        e = get(excl, p, nothing)
        perm = perms === nothing ? nothing : get(perms, p, nothing)
        reps_p = zeros(Int, m)
        resize!(key, m)
        fill!(key, 0)
        # walk the versions best first, so the first admissible member of a
        # class found is the one the active order ranks best. i indexes
        # versions, j the class each one is in
        for r = 1:nv
            i = perm === nothing ? r : perm[r]
            j = cls[i]
            reps_p[j] == 0 || continue
            e === nothing || !e[i] || continue
            reps_p[j] = i
            key[j] = r
        end
        if any(iszero, reps_p)
            # the empty classes rank where their best member would
            for r = 1:nv
                j = cls[perm === nothing ? r : perm[r]]
                key[j] == 0 || continue
                key[j] = r
            end
        end
        reps[p] = reps_p
        # the class order this query puts the package in, as what it displaces:
        # sorted into scratch, then walked, so a package that moves nothing
        # allocates nothing and one that moves two classes carries two pairs
        cperm = nothing
        if !issorted(key)
            resize!(ord, m)
            sortperm!(ord, key)
            moved = Tuple{Int,Int}[]
            for r = 1:m
                @inbounds ord[r] == r || push!(moved, (r, ord[r]))
            end
            cperm = SparsePerm(m, moved)
            perms′[p] = cperm
        end
        if want_keys
            # key_∅: the rank of each class's best member, exclusions ignored
            resize!(key0, m)
            fill!(key0, 0)
            for r = 1:nv
                j = cls[perm === nothing ? r : perm[r]]
                key0[j] == 0 || continue
                key0[j] = r
            end
            keys_q[p] = cperm === nothing ? copy(key) : key[cperm]
            keys_0[p] = cperm === nothing ? copy(key0) : key0[cperm]
        end
    end
    return reps, isempty(perms′) ? nothing : perms′,
        want_keys ? (keys_q, keys_0) : nothing
end

"""
    prepare_pkg_info(info, prob, [info′]; order = nothing) :: Universe

The per-resolve half of preprocessing, run on a T1 artifact (see
[`pkg_info`](@ref Resolver.pkg_info)) to produce the universe the SAT instance
is built over. Two steps:

1. **Rank** each package's classes for this query (`class_ranking`): pick the
   member each class stands for and lay the classes out in the order those
   members put them in. Under the canonical ordering and no constraints this is
   the layout the artifact already has, and costs nothing.
2. **Filter** the result for reachability and redundancy against the actual
   requirements and constraints (`filter_pkg_info!`).

Filtering has to come second: both of its passes are stated in terms of the rank
order, so the layout has to exist first.

The user's constraints reach the matrices through nothing but step 1's
representatives. A constrained query and an unconstrained one produce the same
matrices, up to the class reordering their representatives induce; the whole of
what a constraint does is empty classes, and an empty class is deactivated
rather than deleted, split or rewritten. That is what makes a class's
deactivation the only thing there is to relax.

The result is a fresh universe — `info` is left untouched, so a T1 artifact
stays reusable across resolves — unless the caller passes its own scratch dict
as `info′`, or `info` itself when it owns it (which reordering rules out, since
it rebuilds the matrices).
"""
prepare_pkg_info(
    info  :: AbstractDict{P, PkgInfo{P,V}},
    prob  :: Problem{P},
    info′ :: Dict{P, PkgInfo{P,V}} = Dict{P, PkgInfo{P,V}}();
    order = nothing, # nothing = canonical, else package -> `lt` comparator
) where {P,V} =
    filter_pkg_info!(rank_pkg_info(info, prob, info′; order), prob)

# step 1 on its own: the query's universe before anything is filtered out of
# it. This is where a constraint's entire effect lands — the representatives
# and the class order they induce — so it is also the shape in which "no user
# constraint reaches a matrix" is a statement one can check.
function rank_pkg_info(
    info  :: AbstractDict{P, PkgInfo{P,V}},
    prob  :: Problem{P} = Problem(P[]),
    info′ :: Dict{P, PkgInfo{P,V}} = Dict{P, PkgInfo{P,V}}();
    order = nothing,
) where {P,V}
    perms = version_permutations(info, order)
    reps, cperms, keys = class_ranking_keys(
        info, prob, perms, true)
    # reordering reads every matrix while writing a differently laid out one,
    # so the in-place shortcut is only available when nothing moves
    cperms === nothing || info′ !== info ||
        (info′ = Dict{P, PkgInfo{P,V}}())
    univ = Universe{P,V}(info′, Dict{P, Vector{Int}}(), keys)
    return copy_ranked!(univ, info, reps, cperms)
end

# Copy `info` into `univ`, laid out in the class order `perms` gives (the order
# it already has when that is `nothing`), with every class and column marked
# active — deactivation is `univ.reps`, not a flag, precisely so that the
# filtering passes below can tell "nothing can choose this class" apart from
# "this class is not in the universe". When the destination dict is the source,
# only the flags are normalized.
function copy_ranked!(
    univ  :: Universe{P,V},
    info  :: AbstractDict{P, PkgInfo{P,V}},
    reps  :: Dict{P, Vector{Int}},
    perms :: Union{Nothing, AbstractDict{P, SparsePerm}} = nothing,
) where {P,V}
    info′ = univ.info
    reps′ = univ.reps
    src = Int[] # scratch: output column => source column
    for (p, info_p) in info
        X = info_p.conflicts
        m = nclasses(info_p)
        n = size(X, 2) - 1
        if info′ === info
            @assert perms === nothing
            X[1:m, end] .= true
            X[m+1, 1:n] .= true
            reps′[p] = reps[p]
            continue
        end
        perm = perms === nothing ? nothing : get(perms, p, nothing)
        # a reordered partner's interaction block is indexed by that partner's
        # classes, so its columns move with them; every other column stays put
        cols = nothing
        if perms !== nothing
            for (q, off) in info_p.interacts
                perm_q = get(perms, q, nothing)
                perm_q === nothing && continue
                if cols === nothing
                    cols = resize!(src, n)
                    for j = 1:n
                        cols[j] = j
                    end
                end
                for (r, j) in enumerate(perm_q)
                    cols[off + r] = off + j
                end
            end
        end
        X′ = perm === nothing && cols === nothing ? copy(X) :
             relaid_conflicts(X, m, n, perm, cols)
        X′[1:m, end] .= true
        X′[m+1, 1:n] .= true
        if perm === nothing
            info′[p] = PkgInfo(
                copy(info_p.versions), copy(info_p.classes),
                copy(info_p.members), copy(info_p.shadows),
                copy(info_p.depends), copy(info_p.interacts), X′)
            reps′[p] = copy(reps[p])
        else
            # the partition follows the classes: class `r` of the new layout is
            # class `perm[r]` of the old one
            inv = invperm(perm)
            info′[p] = PkgInfo(
                copy(info_p.versions), Int[inv[i] for i in info_p.classes],
                info_p.members[perm], info_p.shadows[perm],
                copy(info_p.depends), copy(info_p.interacts), X′)
            reps′[p] = reps[p][perm]
        end
    end
    return univ
end

# A conflicts matrix laid out under a reordering: row `r` reads source row
# `perm[r]` (this package's classes) and column `j` reads source column
# `cols[j]` (a reordered partner's block); `nothing` for either means unchanged.
# Only the class rows of the `n` conflict columns are written — the caller
# sets the flag row and the class-flag column. Columns whose rows do not move
# are blitted word by word, which is the whole matrix whenever only partners
# were reordered.
function relaid_conflicts(
    X    :: BitMatrix,
    m    :: Int,
    n    :: Int,
    perm :: Union{Nothing, AbstractVector{Int}},
    cols :: Union{Nothing, Vector{Int}},
)
    X′ = falses(size(X, 1), n + 1)
    W = col_words(X)
    ch = X.chunks
    ch′ = X′.chunks
    @inbounds for r = 1:n
        j = cols === nothing ? r : cols[r]
        base = (j - 1) * W
        base′ = (r - 1) * W
        if perm === nothing
            for w = 1:W
                ch′[base′ + w] = ch[base + w]
            end
        else
            for i′ = 1:m
                i = perm[i′]
                b = (ch[base + ((i - 1) >> 6) + 1] >> ((i - 1) & 63)) & 1
                ch′[base′ + ((i′ - 1) >> 6) + 1] |= b << ((i′ - 1) & 63)
            end
        end
    end
    return X′
end

# the unconstrained case, filtered in place: ranking an unconstrained query
# moves no class, so this is `Universe(info)` plus the rank keys the passes
# compare — which even here are not both the same, since two members of one
# class still give it one `key_∅`
function filter_pkg_info!(
    info :: Dict{P, PkgInfo{P,V}},
    reqs :: SetOrVec{P} = keys(info),
) where {P,V}
    prob = Problem(collect(reqs))
    return filter_pkg_info!(rank_pkg_info(info, prob, info), prob)
end

function filter_pkg_info!(
    univ :: Universe{P,V},
    prob :: Problem{P},
) where {P,V}
    info = univ.info
    reqs = prob.reqs
    # the query's constraints reach the passes below as the *deactivated*
    # classes and nothing else — no exclusion column, no virtual package, no
    # row of their own — because a class its members all fail is the only mark
    # a constraint can leave on a universe whose rows are classes. the masks
    # are index-based, so they are rebuilt after every deletion round; only the
    # packages with an empty class cost anything
    #
    # the installability prune first: it needs no reachability marks and it is
    # what makes the deletions safe — dropping a package while a kept class
    # still depends on it would leave a dangling name. then redundancy
    # elimination — it needs no reachability marks and does most of the
    # shrinking — then alternate reachability and redundancy until neither
    # deletes anything: each deleted class can expose more of both kinds
    # of pruning, and every round preserves the resolved answer (see the
    # theory docs on iterating the filter). requirement packages survive
    # filtering unless they have no installable class at all — nothing
    # can satisfy those — so the requirements remain valid across rounds.
    # rounds strictly shrink the total class count, so the loop terminates
    mark_installable!(info)
    mark_necessary!(info, deactivations(univ), univ.ranks)
    drop_unmarked!(univ)
    while true
        total = sum(nclasses(i) for i in values(info); init = 0)
        deact = deactivations(univ)
        mark_reachable!(info, reqs, deact, univ.ranks)
        # a prefix walk is arc-consistent by construction — it steps past any
        # class that depends on a package with no installable class — but the
        # possibly-best set keeps classes from outside any one prefix, which
        # carries no such guarantee and can leave `depends` naming a package
        # this round empties. Restore the invariant explicitly.
        mark_installable!(info)
        mark_necessary!(info, deact, univ.ranks)
        drop_unmarked!(univ)
        sum(nclasses(i) for i in values(info); init = 0) < total ||
            break
    end
    return univ
end

# the interned tables the reachability walk reads: packages as integer indices,
# so the fixpoint below hashes no package names.
function reach_tables(info::Dict{P, PkgInfo{P,V}}) where {P,V}
    pkgs = sort!(collect(keys(info)))
    N = length(pkgs)
    ix = Dict{P,Int}(p => i for (i, p) in enumerate(pkgs))
    infos = Vector{PkgInfo{P,V}}(undef, N)
    ncls = Vector{Int}(undef, N)
    deps = Vector{Vector{Int}}(undef, N)
    # (partner id, partner's class block offset in p's matrix,
    #  p's class block offset in the partner's matrix)
    partners = Vector{Vector{NTuple{3,Int}}}(undef, N)
    for p = 1:N
        info_p = info[pkgs[p]]
        infos[p] = info_p
        ncls[p] = nclasses(info_p)
        deps[p] = Int[get(ix, q, 0) for q in info_p.depends]
        partners[p] = sort!(NTuple{3,Int}[
            (ix[q], b, info[q].interacts[pkgs[p]]) for (q, b) in info_p.interacts])
    end
    return (; pkgs, N, ix, infos, ncls, deps, partners)
end

function mark_reachable!(
    info  :: Dict{P, PkgInfo{P,V}},
    reqs  :: SetOrVec{P},
    deact :: AbstractDict{P, BitVector},
    # the per-package `(key_Q, key_∅)` vectors the walk compares
    ranks :: Tuple{Dict{P,Vector{Int}}, Dict{P,Vector{Int}}},
) where {P,V}
    for (_, info_p) in info
        info_p.conflicts[1:nclasses(info_p), end] .= false
    end
    return find_reachable(info, reqs, deact, ranks[1], ranks[2])
end

"""
    find_reachable(info, reqs, deact, kq, k0)

Flag, in each package's matrix, the classes that some relaxation of this query
could reach — where a relaxation is the same query with any of its requirements
or constraint sources dropped. `kq` gives per class the rank of the best member
this query admits (`typemax` if it admits none) and `k0` the rank of its best
member, period.

Relaxing a constraint only moves a class earlier, so `k0(c) ≤ key_R(c) ≤ kq(c)`
for every relaxation `R`. A class `c` can therefore be the best of a candidate
set `C` under some relaxation exactly when no `c′ ∈ C` has `kq(c′) < k0(c)`:
otherwise `c′` at its worst still precedes `c` at its best. Writing
`t = min{kq(c′) : c′ ∈ C}`, those classes are `{c ∈ C : k0(c) ≤ t}`.

A package's flagged classes are the possibly-best classes of whatever it has
not been forced past, and being forced past one — a conflict with a flagged
class, nothing selectable in it, a dependency on a package with nothing
selectable — recomputes that set, to a fixpoint. The result already contains
the classes this query alone would reach, so there is nothing to union it with —
Theorem D of the manual's relaxation-stability page proves that.
"""
function find_reachable(
    info  :: Dict{P, PkgInfo{P,V}},
    reqs  :: SetOrVec{P},
    deact :: AbstractDict{P, BitVector},
    kq    :: Dict{P, Vector{Int}},
    k0    :: Dict{P, Vector{Int}},
    tb    = reach_tables(info),
) where {P,V}
    pkgs, N, ix, infos, ncls, deps, partners =
        tb.pkgs, tb.N, tb.ix, tb.infos, tb.ncls, tb.deps, tb.partners

    # ---------------------------------------------------------------- layout
    # Everything per-class is flat: `coff[p]` offsets the key arrays, `soff[p]`
    # the bitset words. One allocation each instead of one per package.
    coff = Vector{Int}(undef, N + 1); coff[1] = 0
    soff = Vector{Int}(undef, N + 1); soff[1] = 0
    cw   = Vector{Int}(undef, N)  # words per column of p's matrix
    # the matrices' backing words, hoisted: the walk reads them by package id
    # thousands of times and has no other use for the wrappers
    chunks = Vector{Vector{UInt64}}(undef, N)
    for p = 1:N
        coff[p+1] = coff[p] + ncls[p]
        soff[p+1] = soff[p] + cld(ncls[p], 64)
        X = infos[p].conflicts
        cw[p] = col_words(X)
        chunks[p] = X.chunks
    end
    M = coff[N+1]
    KQ = Vector{Int}(undef, M) # key_Q, typemax where the query empties the class
    K0 = Vector{Int}(undef, M) # key_∅
    # The classes in key_∅ order, per package — `nothing` when that is the
    # layout order already, which is exactly when nothing here is demoted.
    ord0 = Vector{Union{Nothing,Vector{Int}}}(nothing, N)
    for p = 1:N
        m = ncls[p]
        o = coff[p]
        d = get(deact, pkgs[p], nothing)
        a, b = kq[pkgs[p]], k0[pkgs[p]]
        @inbounds for c = 1:m
            KQ[o+c] = d !== nothing && d[c] ? typemax(Int) : a[c]
            K0[o+c] = b[c]
        end
        issorted(b) || (ord0[p] = sortperm(b))
    end

    # ------------------------------------------------------------ reverse deps
    # `p` saturating pushes every class of every package that depends on `p`.
    # Which classes those are is already in the dependee's matrix — its
    # dependency column for `p` — so the walk needs only the static edge list,
    # not the incremental (package => classes) map it used to accumulate.
    nrd = zeros(Int, N + 1)
    for p = 1:N, q in deps[p]
        q == 0 || (nrd[q+1] += 1)
    end
    rdoff = cumsum!(nrd, nrd)
    rdpkg = Vector{Int}(undef, rdoff[N+1])
    rdcol = Vector{Int}(undef, rdoff[N+1])
    fill = copy(rdoff)
    for p = 1:N, (k, q) in enumerate(deps[p])
        q == 0 && continue
        fill[q] += 1
        rdpkg[fill[q]] = p
        rdcol[fill[q]] = k
    end

    # ----------------------------------------------------------------- state
    # S(p), the kept set, is a prefix in key_∅ order — `iK0[p]` is how far along
    # that order it reaches. It is stored as a bitset anyway because the
    # conflict scan wants to AND it against a partner's column, but no scan of
    # it ever runs past `smax[p]`, its highest layout index.
    Sw = zeros(UInt64, soff[N+1]) # kept
    Pw = zeros(UInt64, soff[N+1]) # forced past
    npushed = zeros(Int, N)       # count, so saturation is O(1)
    smax = zeros(Int, N)          # highest layout index in S(p)
    iKQ = ones(Int, N)            # into layout order: min key_Q still unpushed
    iK0 = ones(Int, N)            # into key_∅ order: how far S(p) reaches
    seeded = falses(N)
    indirty = falses(N)
    addq  = Tuple{Int,Int}[]  # classes newly in S, to be processed
    dirty = Int[]             # packages whose candidate set shrank

    @inline getbit(A, b, c) =
        @inbounds (A[b + ((c - 1) >> 6) + 1] >> ((c - 1) & 63)) & 1 != 0
    @inline setbit!(A, b, c) =
        @inbounds A[b + ((c - 1) >> 6) + 1] |= UInt64(1) << ((c - 1) & 63)

    function add!(p::Int, c::Int)
        b = soff[p]
        getbit(Sw, b, c) && return
        setbit!(Sw, b, c)
        c > smax[p] && (smax[p] = c)
        push!(addq, (p, c))
        return
    end

    function mark_pushed!(p::Int, c::Int)
        b = soff[p]
        getbit(Pw, b, c) && return
        setbit!(Pw, b, c)
        npushed[p] += 1
        # a class something had to step past is still one the universe keeps —
        # that is what "keep the first class, then the next" means
        add!(p, c)
        if !indirty[p]
            indirty[p] = true
            push!(dirty, p)
        end
        return
    end

    # every class of every dependee that depends on a saturated `p`
    function saturate!(p::Int)
        @inbounds for t = rdoff[p]+1:rdoff[p+1]
            q, k = rdpkg[t], rdcol[t]
            smax[q] == 0 && continue
            Yc = chunks[q]
            base = (k - 1) * cw[q]
            b = soff[q]
            for w = 1:cld(smax[q], 64)
                z = Yc[base + w] & Sw[b + w] & ~Pw[b + w]
                while !iszero(z)
                    c = ((w - 1) << 6) + trailing_zeros(z) + 1
                    z &= z - 1
                    mark_pushed!(q, c)
                end
            end
        end
        return
    end

    # S(p) ⊇ possibly-best of (all classes − pushed).
    #
    # `mkq`, the smallest key_Q among the classes not yet pushed, only rises,
    # and the possibly-best set `{c : key_∅(c) ≤ mkq}` only grows: both pointers
    # advance monotonically and neither order is ever rescanned. The layout
    # order already sorts the *active* classes by key_Q — it was built as
    # `sortperm(key_Q)` — so finding `mkq` is a walk along it skipping the
    # deactivated and the pushed, with no second permutation to maintain.
    function refresh!(p::Int)
        m = ncls[p]
        o, b = coff[p], soff[p]
        i = iKQ[p]
        @inbounds while i ≤ m && (KQ[o+i] == typemax(Int) || getbit(Pw, b, i))
            i += 1
        end
        iKQ[p] = i
        # no active class left to rest on: every class is possibly-best, since
        # a relaxation that revives one of them revives it at its own key_∅
        mkq = i > m ? typemax(Int) : @inbounds KQ[o+i]
        j = iK0[p]
        ord = ord0[p]
        if ord === nothing
            @inbounds while j ≤ m && K0[o+j] ≤ mkq
                add!(p, j)
                j += 1
            end
        else
            @inbounds while j ≤ m && K0[o+ord[j]] ≤ mkq
                add!(p, ord[j])
                j += 1
            end
        end
        iK0[p] = j
        # saturated: conflicts can force p to be uninstallable, so every class
        # that depends on p has to be stepped past too
        npushed[p] == m && saturate!(p)
        return
    end

    function seed!(p::Int)
        seeded[p] && return
        seeded[p] = true
        if !indirty[p]
            indirty[p] = true
            push!(dirty, p)
        end
        return
    end

    for p in reqs
        i = get(ix, p, 0)
        i == 0 || seed!(i)
    end

    while !isempty(dirty) || !isempty(addq)
        while !isempty(dirty)
            r = pop!(dirty)
            indirty[r] = false
            refresh!(r)
        end
        isempty(addq) && continue
        p, c = pop!(addq)
        info_p = infos[p]
        o = coff[p]
        # a class this query admits nothing of cannot be rested on
        @inbounds KQ[o+c] == typemax(Int) && mark_pushed!(p, c)
        # dependencies
        @inbounds for (k, q) in enumerate(deps[p])
            info_p.conflicts[c, k] || continue
            if q == 0
                mark_pushed!(p, c) # nothing installable to depend on
                continue
            end
            seed!(q)
            npushed[q] == ncls[q] && mark_pushed!(p, c)
        end
        # conflicts against the partner's kept classes. the partner-side column
        # of p@c is contiguous, so this is a mask AND — bounded by the partner's
        # highest kept class, which is what keeps it off the tail of the column
        @inbounds for (q, _b, cq) in partners[p]
            # nothing of q is kept yet, so nothing of q can be conflicted with
            smax[q] == 0 && continue
            Yc = chunks[q]
            base = (cq + c - 1) * cw[q]
            bq = soff[q]
            hit = false
            for w = 1:cld(smax[q], 64)
                x = Yc[base + w] & Sw[bq + w]
                iszero(x) && continue
                hit = true
                # only the conflicting classes that have not already been
                # stepped past need visiting; without this mask every class
                # added to S(p) re-walks every conflict q had already absorbed
                z = x & ~Pw[bq + w]
                while !iszero(z)
                    k = ((w - 1) << 6) + trailing_zeros(z) + 1
                    z &= z - 1
                    mark_pushed!(q, k)
                end
            end
            hit && mark_pushed!(p, c)
        end
    end

    # the kept set goes straight into each matrix's flag column, OR-ed over
    # whatever the query's own prefix already marked there: `Sw`'s words are
    # laid out exactly like the column's, and its bits stop below the flag row
    for p = 1:N
        m = ncls[p]
        m == 0 && continue
        W = cw[p]
        base = (size(infos[p].conflicts, 2) - 1) * W
        Xc = chunks[p]
        b = soff[p]
        @inbounds for w = 1:cld(m, 64)
            Xc[base + w] |= Sw[b + w]
        end
    end
    return nothing
end

function mark_installable!(
    info :: Dict{P, <: PkgInfo{P}},
) where {P}
    # a package with no in-universe classes cannot be installed, so no class
    # depending on it can be either: take those out too, and repeat until
    # nothing more goes, since each removal can empty another package (the
    # literature calls this arc consistency). It is a sound approximation of
    # deleting the classes no valid solution contains (see the theory docs),
    # and it is also what keeps `depends` from naming a package that
    # `drop_unmarked!` deletes as empty
    #
    # a dependency naming a package that is not in `info` at all counts the
    # same way: it cannot be satisfied either, and a deletion elsewhere (an
    # earlier `drop_unmarked!`, say) is exactly how one comes about. `info`
    # does not change here, so the absentees are found once
    absent = Set{P}()
    for info_p in values(info), q in info_p.depends
        haskey(info, q) || push!(absent, q)
    end
    empties = Set{P}()
    while true
        empty!(empties)
        union!(empties, absent)
        for (p, info_p) in info
            X = info_p.conflicts
            any(X[i, end] for i = 1:nclasses(info_p)) && continue
            push!(empties, p)
        end
        isempty(empties) && return info
        dirty = false
        for info_p in values(info)
            X = info_p.conflicts
            for (k, q) in enumerate(info_p.depends)
                q in empties || continue
                # q is uninstallable, drop the p@i that depend on it
                for i = 1:nclasses(info_p)
                    X[i, end] || continue
                    X[i, k] || continue
                    X[i, end] = false
                    dirty = true
                end
            end
        end
        dirty || return info
    end
end

function mark_necessary!(
    info  :: Dict{P, PkgInfo{P,V}},
    deact :: AbstractDict{P, BitVector} = EmptyDict{P,BitVector}(),
    # the per-package `(key_Q, key_∅)` vectors the domination rule compares
    ranks :: Union{Nothing, Tuple{Dict{P,Vector{Int}}, Dict{P,Vector{Int}}}} = nothing,
) where {P,V}
    # intern packages as integer indices so that the work loop below
    # hashes no package names (sorted so the processing order — and with
    # it any order-dependent tie — is deterministic)
    pkgs = sort!(collect(keys(info)))
    N = length(pkgs)
    ix = Dict{P,Int}(p => i for (i, p) in enumerate(pkgs))
    infos = Vector{PkgInfo{P,V}}(undef, N)
    ncls = Vector{Int}(undef, N)
    partners = Vector{Vector{NTuple{3,Int}}}(undef, N)
    # interned deactivation masks (nothing: nothing empty here, the norm)
    deacts = Vector{Union{Nothing,BitVector}}(nothing, N)
    # interned rank keys
    kqv = Vector{Union{Nothing,Vector{Int}}}(nothing, N)
    k0v = Vector{Union{Nothing,Vector{Int}}}(nothing, N)
    for p = 1:N
        info_p = info[pkgs[p]]
        infos[p] = info_p
        ncls[p] = nclasses(info_p)
        deacts[p] = get(deact, pkgs[p], nothing)
        if ranks !== nothing
            kqv[p] = ranks[1][pkgs[p]]
            k0v[p] = ranks[2][pkgs[p]]
        end
        # (partner id, partner's class block offset in p's matrix,
        #  p's class block offset in the partner's matrix)
        prt = NTuple{3,Int}[
            (ix[q], b, info[q].interacts[pkgs[p]])
            for (q, b) in info_p.interacts
        ]
        partners[p] = sort!(prt)
    end
    # some work buffers
    A = UInt64[]        # candidate class mask
    D = UInt64[]        # per-class domination candidate masks
    T = UInt64[]        # mask of classes still tracked by the sweep
    R = Int[]           # redundant indices vector
    F = Bool[]          # per class, whether its shadow list is ours to grow
    # scratch: suffix masks of the classes
    # ordered by key_∅, so "the classes whose best possible rank is worse than
    # t" is one mask lookup
    S = UInt64[]
    k0s = Int[]

    # the classes redundancy may reason about: the in-universe ones, less the
    # deactivated ones — the pass is the one place that reads *both* per-class
    # bits (see BitKernels.jl's header). a deactivated class must not be
    # *deleted* — the relaxation that would want it back has to find it still
    # there — and it must not *dominate*, because domination says "this better
    # class will be chosen instead", which is worth nothing when the better
    # class is one nothing can choose. dropping them from the candidate set
    # does both — it takes them off both sides of the test — and it keeps the
    # test itself activation-free: what a row says is compared in full,
    # including conflicts against partner classes this query happens to have
    # emptied
    function candidates!(A::Vector{UInt64}, p::Int)
        info_p = infos[p]
        X = info_p.conflicts
        resize!(A, col_words(X))
        col_copy!(A, X, size(X, 2))
        clear_rows_above!(A, ncls[p])
        d = deacts[p]
        if d !== nothing
            dc = d.chunks
            @inbounds for w = 1:min(length(A), length(dc))
                A[w] &= ~dc[w]
            end
        end
        return A
    end

    # initialize active column flags
    for p = 1:N
        info_p = infos[p]
        X = info_p.conflicts
        m = ncls[p]
        n = size(X, 2) - 1
        candidates!(A, p)
        for j = 1:n
            # we don't have to look at columns that have no
            # conflicts for any candidate class of the package
            X[m+1, j] = col_intersects(X, j, A)
        end
        # conflict columns for deleted partner classes are also
        # irrelevant: no model over the surviving classes can include
        # the partner, so the conflict cannot constrain anything.
        # a partner class that is merely *deactivated* is a different
        # matter — it is still in the universe, so the conflict still
        # counts, and the flag it is read from does not know about
        # deactivation precisely so that it does
        for (q, b, c) in partners[p]
            Y = infos[q].conflicts
            for k = 1:ncls[q]
                X[m+1, b+k] &= Y[k, end]
            end
        end
    end
    # process every package once, cheapest first (stable sort breaks ties
    # by name); packages woken by a partner's deletions are appended to
    # the queue unless already pending
    queue = sort!(collect(1:N), by = p -> length(partners[p]))
    inwork = trues(N)
    head = 1
    while head ≤ length(queue)
        p = queue[head]
        head += 1
        inwork[p] || continue
        inwork[p] = false
        # get conflicts & dimensions
        info_p = infos[p]
        X = info_p.conflicts
        m = ncls[p]
        m > 1 || continue # unique class cannot be redundant
        n = size(X, 2) - 1
        W = col_words(X)
        # candidate class mask
        candidates!(A, p)
        nact = 0
        @inbounds for w = 1:W
            nact += count_ones(A[w])
        end
        nact > 1 || continue # unique class cannot be redundant
        # find redundant classes: i < j and X[i, k] => X[j, k] for all
        # active k means an earlier class is strictly more compatible,
        # therefore i will always be chosen instead of j. the candidates
        # dominated by i are the candidate classes worse than i that have a
        # constraint in every column i does. sweep the active columns
        # once, restricting the candidates of every class with a bit in
        # the column to the column's row set; classes whose candidate
        # set empties drop out of the sweep. a class dominated only by
        # dominated classes is also dominated by their (transitively
        # live) dominators, so batching over the initial candidate set finds
        # exactly the sequentially dominated classes.
        resize!(D, m * W)
        resize!(T, W)
        copyto!(T, A)
        # the candidate set of `i` is not "the classes worse than i" but "the
        # classes whose *best possible* rank is worse than i's current one" —
        # key_∅(j) > key_Q(i), the one order fact a relaxation cannot reverse
        # (see the relaxation-stability page).'
        # Build the suffix masks of the classes sorted by key_∅ once per
        # package; `S[(k-1)*W+1 : k*W]` is the mask of the classes at position
        # k and later, and the block at k = m+1 is empty.
        kq_p = kqv[p]
        k0_p = k0v[p]
        if kq_p !== nothing
            ord = sortperm(k0_p)
            resize!(k0s, m)
            for k = 1:m
                k0s[k] = k0_p[ord[k]]
            end
            resize!(S, (m + 1) * W)
            fill!(S, UInt64(0))
            @inbounds for k = m:-1:1
                base = (k - 1) * W
                nb = k * W
                for w = 1:W
                    S[base + w] = S[nb + w]
                end
                j = ord[k]
                S[base + ((j - 1) >> 6) + 1] |= UInt64(1) << ((j - 1) & 63)
            end
        end
        @inbounds for w = 1:W
            c = A[w]
            while !iszero(c)
                i = ((w - 1) << 6) + trailing_zeros(c) + 1
                c &= c - 1
                # candidates of i: candidate classes worse than i
                o = (i - 1) * W
                if kq_p === nothing
                    for w′ = 1:W
                        D[o + w′] = A[w′]
                    end
                    wt = i >> 6
                    for w′ = 1:min(wt, W)
                        D[o + w′] = 0
                    end
                    r = i & 63
                    if r != 0 && wt < W
                        D[o + wt + 1] &= ~((UInt64(1) << r) - 1)
                    end
                else
                    # key_∅(j) > key_Q(i) implies j > i (key_∅(j) ≤ key_Q(j)
                    # and key_Q is ascending), so this is a subset of the
                    # candidate set "every class worse than i"
                    kk = searchsortedlast(k0s, kq_p[i]) + 1
                    sb = (kk - 1) * W
                    for w′ = 1:W
                        D[o + w′] = A[w′] & S[sb + w′]
                    end
                end
                live = UInt64(0)
                for w′ = 1:W
                    live |= D[o + w′]
                end
                iszero(live) && (T[w] &= ~(UInt64(1) << ((i - 1) & 63)))
            end
        end
        prev = -1 # chunk base of the previous active column
        for k = 1:n
            X[m+1, k] || continue # inactive column
            base = (k - 1) * W
            # compat bounds are ranges, so identical adjacent columns are
            # common — and re-ANDing an identical column changes nothing
            if prev ≥ 0
                same = true
                @inbounds for w = 1:W
                    if X.chunks[base + w] != X.chunks[prev + w]
                        same = false
                        break
                    end
                end
                same && continue
            end
            prev = base
            @inbounds for w = 1:W
                c = X.chunks[base + w] & T[w]
                while !iszero(c)
                    i = ((w - 1) << 6) + trailing_zeros(c) + 1
                    c &= c - 1
                    o = (i - 1) * W
                    live = UInt64(0)
                    for w′ = 1:W
                        live |= (D[o + w′] &= X.chunks[base + w′])
                    end
                    iszero(live) && (T[w] &= ~(UInt64(1) << ((i - 1) & 63)))
                end
            end
        end
        # union of all candidate sets = the dominated classes
        fill!(T, UInt64(0)) # reuse as the union accumulator
        @inbounds for w = 1:W
            c = A[w]
            while !iszero(c)
                i = ((w - 1) << 6) + trailing_zeros(c) + 1
                c &= c - 1
                o = (i - 1) * W
                for w′ = 1:W
                    T[w′] |= D[o + w′]
                end
            end
        end
        empty!(R)
        @inbounds for w = 1:W
            c = T[w]
            while !iszero(c)
                push!(R, ((w - 1) << 6) + trailing_zeros(c) + 1)
                c &= c - 1
            end
        end
        isempty(R) && continue
        # (D3) of the theory page's *Shadows*: a class this query emptied is on
        # neither side of the domination test. `candidates!` takes it out of
        # `A`, and every `D[i]` is a subset of `A`, so the dominator side holds
        # by construction; the deleted side is worth asserting, since a
        # deactivated class deleted here is one the relaxation that emptied it
        # would find gone
        dp = deacts[p]
        dp === nothing || @assert !any(dp[j] for j in R if j ≤ length(dp))
        # hand each deleted class's versions, and whatever it was already
        # shadowing, to *every* surviving class that dominates it — not to one
        # claimant. What a report may say about a deleted version is read off
        # its dominators together (the widening ω of the theory page's
        # *Shadows*): it joins a range a line rules out where one of them is
        # there and a range a line admits only where all of them are, so a
        # shadow list that remembered one dominator would be admitting the
        # version wherever that one is admitted, which another dominator may
        # refuse. Recording every dominator is what (D0)–(D2) ask of the
        # substrate, and Lemma 36 is the argument that this loop provides them.
        #
        # A dominator deleted in this same round needs no chasing: `j ∈ D[i]`
        # is "every active column i has a bit in, j has too", which is
        # transitive (and the rank side of it is transitive as well, since
        # key_∅ ≤ key_Q pointwise), so the survivors that dominate a deleted
        # claimant already dominate everything the claimant does. A host
        # deleted in a *later* round is the case the `sh[j]` append covers: it
        # hands what it was shadowing to each of its own dominators, which is
        # the chain of deletions Lemma 36 walks.
        #
        # the lists are replaced rather than grown in place: `copy_ranked!`
        # shares them with the artifact it copied, which must not learn about
        # this query
        sh = info_p.shadows
        vers = info_p.versions
        mem = info_p.members
        resize!(F, m)
        fill!(F, false)
        nosh = V[] # one empty list for every class on its way out
        @inbounds for w = 1:W
            c = A[w] & ~T[w] # the candidates this round leaves standing
            while !iszero(c)
                i = ((w - 1) << 6) + trailing_zeros(c) + 1
                c &= c - 1
                o = (i - 1) * W
                for w′ = 1:W
                    d = D[o + w′]
                    iszero(d) && continue
                    if !F[i]
                        sh[i] = copy(sh[i])
                        F[i] = true
                    end
                    while !iszero(d)
                        j = ((w′ - 1) << 6) + trailing_zeros(d) + 1
                        d &= d - 1
                        for k in mem[j]
                            push!(sh[i], vers[k])
                        end
                        # what `j` was holding may have reached `i` already, by
                        # another host going with it: a version is named by
                        # every class that dominated it, and two of those can
                        # be deleted in the same round
                        for v in sh[j]
                            v in sh[i] || push!(sh[i], v)
                        end
                    end
                end
            end
        end
        for j in R
            sh[j] = nosh
        end
        # deactivate redundant classes
        X[R, end] .= false
        for (q, b, c) in partners[p]
            infos[q].conflicts[ncls[q] + 1, c .+ R] .= false
            if !inwork[q] # can create new redundancies
                inwork[q] = true
                push!(queue, q)
            end
        end
    end
end

drop_unmarked!(univ::Universe) = drop_unmarked!(univ.info, univ.reps, univ.ranks)

function drop_unmarked!(
    info :: Dict{P, <: PkgInfo{P}},
    reps :: Union{Nothing, Dict{P, Vector{Int}}} = nothing,
    # renumbered with `reps`; the *values* are ranks in the
    # artifact's version order and are never rewritten, only subset, so the
    # comparisons they support survive deletion
    ranks :: Union{Nothing, Tuple{Dict{P,Vector{Int}}, Dict{P,Vector{Int}}}} = nothing,
) where {P}
    # This pass reads the *in-universe* bit and nothing else: it knows about
    # the deleting passes' verdicts and knows nothing about deactivation, which
    # is exactly why deactivation is not stored as that bit — an emptied class
    # must come out of here intact (see BitKernels.jl's header). `reps` is
    # carried along only to be renumbered with the classes it indexes.
    #
    # first pass: per package, compute the kept classes and kept columns
    # from the (definitive) class flags — all of it before any package
    # is rebuilt, since kept columns are read off the partners' matrices
    masks = Dict{P, Tuple{BitVector, BitVector}}()
    A = UInt64[] # active class mask buffer
    for (p, info_p) in info
        X = info_p.conflicts
        m = nclasses(info_p)
        n = size(X, 2) - 1
        W = col_words(X)
        # active classes
        I = X[1:m, end]
        resize!(A, W)
        col_copy!(A, X, n + 1)
        clear_rows_above!(A, m)
        # kept columns: dependency columns some active class depends
        # on, and conflict columns of active partner classes — a
        # partner's column block must stay aligned with its class list,
        # so kept partner classes keep their columns even if empty
        K = falses(n)
        for k = 1:length(info_p.depends)
            K[k] = col_intersects(X, k, A)
        end
        for (q, b) in info_p.interacts
            Y = info[q].conflicts
            copy_col_bits!(K.chunks, b, Y, size(Y, 2), nclasses(info[q]))
        end
        masks[p] = (I, K)
    end
    # save original class counts (the matrices are rebuilt in place)
    N = Dict{P,Int}(p => nclasses(info_p) for (p, info_p) in info)
    # second pass: shrink each PkgInfo
    for p in collect(keys(info))
        info_p = info[p]
        # abbreviate components
        V = info_p.versions
        C = info_p.classes
        M = info_p.members
        S = info_p.shadows
        D = info_p.depends
        T = info_p.interacts
        X = info_p.conflicts
        m = nclasses(info_p)
        n = size(X, 2) - 1
        W = col_words(X)
        I, K = masks[p]
        m′ = count(I)
        # delete if no active classes
        if m′ == 0
            delete!(info, p)
            reps === nothing || delete!(reps, p)
            if ranks !== nothing
                delete!(ranks[1], p)
                delete!(ranks[2], p)
            end
            continue
        end
        # keep as is if everything is active (with the column flags
        # normalized, as rebuilding would leave them)
        if m′ == m && all(K)
            X[m+1, 1:n] .= true
            continue
        end
        # the surviving classes keep the versions they hold: a deleted class
        # takes its members with it, since nothing is left to name them.
        # dropping classes and columns can only *merge* row-equality classes
        # (fewer rows to distinguish, fewer columns to differ in), so
        # restricting the partition stays sound, if possibly finer than the
        # truth; `pkg_info` is where it is computed exactly
        keep = falses(length(V))
        for i = 1:m
            I[i] || continue
            for j in M[i]
                keep[j] = true
            end
        end
        index = cumsum(keep) # old version index => new one (kept ones only)
        V′ = V[keep]
        C′ = Vector{Int}(undef, length(V′))
        M′ = Vector{Vector{Int}}(undef, m′)
        S′ = similar(S, m′)
        i′ = 0
        for i = 1:m
            I[i] || continue
            i′ += 1
            M′[i′] = mem = Int[index[j] for j in M[i]]
            # a surviving class keeps what it shadows; a deleted one's shadows
            # went to each of its dominators when `mark_necessary!` deleted it,
            # and are simply gone when another pass did
            S′[i′] = S[i]
            for j in mem
                C′[j] = i′
            end
        end
        if reps !== nothing
            r = reps[p]
            reps[p] = Int[iszero(r[i]) ? 0 : index[r[i]] for i = 1:m if I[i]]
        end
        if ranks !== nothing
            kq, k0 = ranks
            kq_p, k0_p = kq[p], k0[p]
            kq[p] = Int[kq_p[i] for i = 1:m if I[i]]
            k0[p] = Int[k0_p[i] for i = 1:m if I[i]]
        end
        # compute shrunken components
        D′ = D[K[1:length(D)]]
        T′ = Dict{P,Int}()
        b′ = length(D′)
        for (q, b) in sort!(collect(T), by=last)
            n′ = count(K[b .+ (1:N[q])])
            if n′ > 0
                T′[q] = b′
                b′ += n′
            end
        end
        R′ = padded_rows(m′)
        W′ = R′ >> 6
        X′ = falses(R′, b′ + 1)
        src = X.chunks
        dst = X′.chunks
        # kept-class mask words for the gather below
        resize!(A, W)
        col_copy!(A, X, n + 1)
        clear_rows_above!(A, m)
        prefix = findlast(I) == m′ # kept classes are 1:m′
        j′ = 0
        for j = 1:n
            K[j] || continue
            j′ += 1
            sb = (j - 1) * W
            db = (j′ - 1) * W′
            if prefix
                # kept classes are a prefix: straight word copy
                nw = (m′ + 63) >> 6
                @inbounds for w = 1:nw
                    dst[db + w] = src[sb + w]
                end
                r = m′ & 63
                r != 0 && @inbounds (dst[db + nw] &= (UInt64(1) << r) - 1)
            else
                # gather the kept classes' bits
                acc = UInt64(0)
                na = 0
                dw = db + 1
                @inbounds for w = 1:W
                    avail = A[w]
                    iszero(avail) && continue
                    v = src[sb + w]
                    while !iszero(avail)
                        acc |= ((v >> trailing_zeros(avail)) & 1) << na
                        avail &= avail - 1
                        na += 1
                        if na == 64
                            dst[dw] = acc
                            dw += 1
                            acc = UInt64(0)
                            na = 0
                        end
                    end
                end
                na > 0 && @inbounds (dst[dw] = acc)
            end
        end
        @assert j′ == b′
        X′[1:m′, end] .= true  # kept classes are active
        X′[m′+1, 1:b′] .= true # kept columns are active
        # assign new struct into info
        info[p] = PkgInfo(V′, C′, M′, S′, D′, T′, X′)
    end
    return info
end

function check_info_structure(
    info :: Dict{P, PkgInfo{P,V}},
) where {P,V}
    for (p, info_p) in info
        length(info_p.classes) == length(info_p.versions) ||
            return :classes, p, p
        for (i, mem) in enumerate(info_p.members), j in mem
            info_p.classes[j] == i ||
                return :members, p, p
        end
        length(info_p.shadows) == nclasses(info_p) ||
            return :shadows, p, p
        size(info_p.conflicts, 1) == padded_rows(nclasses(info_p)) ||
            return :rows, p, p
        for q in info_p.depends
            q in keys(info) ||
                return :depends, p, q
        end
        interacts = sort!(collect(info_p.interacts), by=last)
        for (i, (q, b)) in enumerate(interacts)
            if i == 1
                b == length(info_p.depends) ||
                    return :conflicts, p, q
            end
            if i < length(interacts)
                b + nclasses(info[q]) == interacts[i+1][2] ||
                    return :conflicts, p, q
            end
        end
    end
end
