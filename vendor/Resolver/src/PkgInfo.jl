"""
    PkgInfo{P,V}

One package's slice of the universe. The conflict matrix has one row per
interchangeability *class* — a set of versions nothing in the registry can tell
apart — and the partition saying which versions those are is carried with it.

  * `versions` — every version the package offers, in canonical (provider)
    order. Untouched by the ordering a query asks for: the rank order is a
    property of the *classes*, and it is the rows that move.
  * `classes` / `members` — the partition, in both directions. `classes[i]` is
    the matrix row version `i` belongs to; `members[c]` is class `c`'s version
    indices, ascending. Both are stored because both directions are hot;
    anything that drops or renumbers classes rebuilds them together.
  * `shadows` — per class, the versions redundancy elimination removed *because
    of* that class, as values rather than indices, since they are no longer in
    `versions`. One version is listed under every class that dominated it, so
    these lists are not a partition of anything. See below.
  * `depends` — the packages some class depends on, sorted; one matrix column
    each, in that order.
  * `interacts` — per partner package, the offset of its block of *class*
    columns in this matrix. **Offset `0` is a real offset**, not a sentinel:
    the first partner's block starts there whenever the package has no
    dependency columns of its own — which is every package whose only
    relations are weak. So `haskey` is how to ask whether two packages
    interact; `get(interacts, q, 0)` silently reads a real interaction as
    none.
  * `conflicts` — `(m+1) × (n+1)` bits for `m` classes and `n` conflict
    columns: the dependency columns followed by one block of partner classes
    per partner, with the last row and column holding the *in-universe* flags
    (see BitKernels.jl for the layout).

Versions share a class when nothing in the registry can tell them apart — see
[`version_classes`](@ref Resolver.version_classes). Since class members are
indistinguishable by construction, a user constraint cannot split a class; all
it can do is empty one, which is why constraints never enter these matrices
(see [`prepare_pkg_info`](@ref Resolver.prepare_pkg_info)).

## The two per-class bits

A class carries two independent facts, and the matrix holds only one of them:

  * **in-universe** — "this class is still part of the problem". This is the
    flag row and column of `conflicts`. The passes that *delete* clear it
    (`mark_installable!`, `mark_reachable!`, `mark_necessary!`), and
    `drop_unmarked!` reads it and nothing else.
  * **activated** — "this query admits some member of this class". This is
    per-resolve state, not matrix state: it is `reps[c] != 0` on the
    [`Universe`](@ref Resolver.Universe) built from this artifact.

Deactivation never implies deletion: an emptied class keeps its row, its
column in every partner, and its dependency columns. Keeping the two bits apart
is what makes that possible, and BitKernels.jl's header spells out why one bit
could not do both jobs.

## Shadows

`members[c]` and `shadows[c]` are both "versions class `c` speaks for", and
they are deliberately not the same list. A member is *indistinguishable* from
the class: it shares the row, so every statement the row makes is true of it. A
shadowed version is one `mark_necessary!` deleted because `c` has a **subset**
of its constraints — so what `c` rules out, the shadow is ruled out by too, but
the shadow may be constrained in ways `c` is not. Folding the two together
would put a version under a row that does not describe it, and would break the
moment a constraint excludes `c` while admitting the version it shadows.

A version is listed under **every** class that dominated it, and that is what
makes it sayable. Read as the implication it is, a bound the class states
carries over: "at `c`, `q` is at `1.2`" is true of a shadow too, since `c`'s
constraints are a subset of the shadow's and a shadow wanting `q` more narrowly
still only makes the consequent truer. What does not carry over is **admission**
— something else's bound may take `c` and refuse a version `c` shadows, so "`c`
is one of the versions this allows" says nothing whatever about them. One rule
covers both once every dominator is known: a shadow is admitted exactly where
*all* of its dominators are admitted and excluded where *any* of them is
excluded. That is the widening `ω` of the manual's *Explaining an unsatisfiable
resolve*, Section 9; these lists are (D0)–(D2) of what it rests on, and Lemma
36 is the argument that `mark_necessary!` supplies them. (D3) — that the query
excludes no shadow and no dominator — is only half theirs: an emptied class is
on neither side of the domination test, but a deleted class is handed over
whole, members the query excludes and all, and dropping those is the reader's
to do.

Shadows exist to be reported, not resolved over: they are in no matrix, no SAT
clause names them, and no solution contains one. A class that leaves the
universe for any other reason — uninstallable, unreachable — takes its own
copy of the list with it, and a version its other dominators still name is
still named. That costs a report nothing either way: a shadow of a class that
left for such a reason would have left for the same reason on its own, and
unlike domination that reason is already somewhere a report can say it.
"""
struct PkgInfo{P,V}
    versions  :: Vector{V}
    classes   :: Vector{Int}
    members   :: Vector{Vector{Int}}
    shadows   :: Vector{Vector{V}}
    depends   :: Vector{P}
    interacts :: Dict{P, Int}
    conflicts :: BitMatrix
end

PkgInfo(
    versions  :: Vector{V},
    classes   :: Vector{Int},
    depends   :: Vector{P},
    interacts :: Dict{P,Int},
    conflicts :: BitMatrix,
) where {P,V} = PkgInfo{P,V}(versions, classes, class_members(classes),
    no_shadows(V, maximum(classes; init = 0)), depends, interacts, conflicts)

"""
    no_shadows(V, m) :: Vector{Vector{V}}

`m` classes that shadow nothing, at the cost of a single empty vector: every
entry aliases the same one. That is safe only because a shadow list is
*replaced* rather than appended to — the one place that grows one copies it
first — and the saving is worth the discipline, since most classes shadow
nothing and a registry-scale universe has tens of thousands of them.
"""
no_shadows(::Type{V}, m::Int) where {V} = fill(V[], m)

# the number of classes — i.e. of rows of the conflicts matrix
nclasses(info::PkgInfo) = length(info.members)

"""
    class_members(classes, m = maximum(classes)) :: Vector{Vector{Int}}

Invert a class-id-per-version vector into a version-index-per-class one. `m` is
the number of classes, needed only when the last ones might be empty — which
they never are for a partition, but the argument keeps the inverse total.
"""
function class_members(classes::Vector{Int}, m::Int = maximum(classes; init = 0))
    members = [Int[] for _ = 1:m]
    for (i, j) in enumerate(classes)
        push!(members[j], i)
    end
    return members
end

"""
    collapse_shadows(shadows, classes, members, m) :: Vector{Vector{V}}

The shadow lists of a coarser partition: the new class a set of old ones merge
into shadows everything they shadowed. `classes` and `m` describe the new
partition, `members` and `shadows` the old one.

`pkg_info` collapses before anything has shadowed anything, so in practice this
copies empties; it exists so that merging classes is not a special case that
has to remember shadows separately.
"""
function collapse_shadows(
    shadows :: Vector{Vector{V}},
    classes :: Vector{Int},
    members :: Vector{Vector{Int}},
    m       :: Int,
) where {V}
    sh = no_shadows(V, m)
    for (i, s) in enumerate(shadows)
        isempty(s) && continue
        c = classes[first(members[i])]
        sh[c] = isempty(sh[c]) ? copy(s) : vcat(sh[c], s)
    end
    return sh
end

# `members` is the inverse of `classes`, so it is not compared
function Base.:(==)(a::PkgInfo, b::PkgInfo)
    a.versions  == b.versions  &&
    a.classes   == b.classes   &&
    a.shadows   == b.shadows   &&
    a.depends   == b.depends   &&
    a.interacts == b.interacts &&
    a.conflicts == b.conflicts
end

"""
    version_classes(X, m) :: Vector{Int}

The interchangeability partition of the `m` versions whose conflicts matrix is
`X`, as a class id per version — ids numbered `1, 2, …` in the version order of
each class's first member.

Per the manual's Theory section (lemma on interchangeable versions), two
versions of a package are *interchangeable* when they have the same dependency
set and every compatibility entry in the problem — their own and every other
package's — constrains them equally. In `PkgInfo` terms that is exactly row
equality, and the test is purely local to `X`: the dependency columns carry the
dependency set, and the interaction blocks carry every compatibility entry that
mentions the package, incoming as much as outgoing, because `pkg_info` records
each conflict symmetrically in both partners' matrices. (The incoming half is
not optional — another package's bound can admit one of two versions and not
the other, and then they are genuinely distinguishable.)

The partition is a property of the registry alone: it is independent of the
requirements, of the version ordering, and of any user constraints. That is
what puts it on the T1 side of the boundary, and what lets a `PkgInfo`'s matrix
be indexed by it: `pkg_info` computes the partition from rows it builds one per
version, then emits the matrix with one row per class (`collapse_classes!`).
Choosing which member of a class stands for it is the part that does depend on
the query, and that is per-resolve state (see `class_ranking`).

The scan is word-parallel over columns: one pass computes, for every adjacent
pair of versions at once, whether their rows differ anywhere, which yields the
classes that are contiguous runs of versions — nearly all of them in practice,
since dependency sets and compat bounds vary in blocks. A second pass hashes
one row per run and merges runs whose rows compare equal, so the result is the
exact row-equality partition, hence invariant under reordering versions.
"""
function version_classes(X::BitMatrix, m::Int)
    version_classes!(Vector{Int}(undef, m), X, m)
end

function version_classes!(ids::Vector{Int}, X::BitMatrix, m::Int)
    resize!(ids, m)
    m > 0 || return ids
    n = size(X, 2) - 1
    W = col_words(X)
    chunks = X.chunks

    # pass 1: word-parallel adjacency differences. bit i-1 of `d` records
    # whether rows i and i+1 differ; within a word, row i's bit and row i+1's
    # bit are adjacent, so one shift-and-xor per word compares 64 pairs at
    # once (the topmost pair straddles into the next word)
    d = zeros(UInt64, W)
    @inbounds for k = 1:n
        base = (k - 1) * W
        for w = 1:W
            c = chunks[base + w]
            nxt = w < W ? chunks[base + w + 1] : UInt64(0)
            d[w] |= (c ⊻ (c >> 1)) ⊻ ((nxt & 1) << 63)
        end
    end
    runs = Int[1] # first version of each run of adjacent identical rows
    nc = 1
    ids[1] = 1
    @inbounds for i = 2:m
        if !iszero(d[((i - 2) >> 6) + 1] & (UInt64(1) << ((i - 2) & 63)))
            nc += 1
            push!(runs, i)
        end
        ids[i] = nc # = the index of i's run
    end
    nc > 1 || return ids

    # pass 2: merge runs whose rows are equal but not adjacent. hashes only
    # bucket the candidates; every merge is confirmed by comparing the rows
    buckets = Dict{UInt,Vector{Int}}()
    for (r, i) in enumerate(runs)
        push!(get!(() -> Int[], buckets, row_hash(X, i, n, W)), r)
    end
    canon = collect(1:nc) # each run's earliest run with an equal row
    merged = false
    for rs in values(buckets)
        length(rs) > 1 || continue
        sort!(rs)
        for a = 2:length(rs)
            for b = 1:a-1
                canon[rs[b]] == rs[b] || continue # not a class of its own
                rows_equal(X, runs[rs[b]], runs[rs[a]], n, W) || continue
                canon[rs[a]] = rs[b]
                merged = true
                break
            end
        end
    end
    merged || return ids

    # renumber the surviving classes in order of first appearance
    num = zeros(Int, nc)
    nc′ = 0
    for r = 1:nc
        canon[r] == r && (num[r] = (nc′ += 1))
    end
    @inbounds for i = 1:m
        ids[i] = num[canon[ids[i]]]
    end
    return ids
end

"""
    collapse_classes!(info)

The last step of building an artifact. `pkg_info` starts with a row per
version, because that is what the partition is computed from; this computes it
(`version_classes`) and rebuilds every matrix with one row per class of the
package and one column per class of each partner, which is the shape everything
downstream reads.

The collapse is lossless in both directions. A class's members have identical
rows by definition, so the class's row *is* any member's row. And members of a
partner class have identical *columns* here: a conflict is recorded
symmetrically in both partners' matrices, so partner rows that agree everywhere
agree in particular about this package, and the columns they index are equal.
Deleting duplicate columns cannot separate rows that agreed, so the partition
this indexes is also exactly the partition it was computed from — collapsing
does not have to be iterated to a fixpoint to be correct, only to be coarsest,
and coarser is not what is claimed here.

Called once, at the end of `pkg_info`.
"""
function collapse_classes!(info::Dict{P,PkgInfo{P,V}}) where {P,V}
    cls = Dict{P,Vector{Int}}()
    mem = Dict{P,Vector{Vector{Int}}}()
    for (p, info_p) in info
        c = version_classes(info_p.conflicts, length(info_p.versions))
        cls[p] = c
        mem[p] = class_members(c)
    end
    for p in collect(keys(info))
        info_p = info[p]
        mem_p = mem[p]
        m = length(mem_p)
        # every class of this package and of every partner holds a single
        # version, so the matrix is already the one this wants: only the
        # partition has to be recorded
        if m == length(info_p.versions) && all(
            length(mem[q]) == length(info[q].versions)
            for q in keys(info_p.interacts))
            info[p] = PkgInfo{P,V}(info_p.versions, cls[p], mem_p,
                collapse_shadows(info_p.shadows, cls[p], info_p.members, m),
                info_p.depends, info_p.interacts, info_p.conflicts)
            continue
        end
        # one column per dependency, then one per class of each partner
        cols = collect(1:length(info_p.depends))
        interacts = Dict{P,Int}()
        for (q, b) in sort!(collect(info_p.interacts), by = last)
            interacts[q] = length(cols)
            for mem_q in mem[q]
                push!(cols, b + first(mem_q))
            end
        end
        rows = Int[first(mem_c) for mem_c in mem_p]
        info[p] = PkgInfo{P,V}(info_p.versions, cls[p], mem_p,
            collapse_shadows(info_p.shadows, cls[p], info_p.members, m),
            info_p.depends, interacts,
            gather_conflicts(info_p.conflicts, rows, cols))
    end
    return info
end

# `X′[i, j] = X[rows[i], cols[j]]`, in a freshly allocated matrix of the shape
# `PkgInfo` wants: `length(cols)` conflict columns plus the flag column, all of
# it marked active
function gather_conflicts(X::BitMatrix, rows::Vector{Int}, cols::Vector{Int})
    m = length(rows)
    n = length(cols)
    X′ = falses(padded_rows(m), n + 1)
    W = col_words(X)
    W′ = col_words(X′)
    ch = X.chunks
    ch′ = X′.chunks
    @inbounds for j = 1:n
        base = (cols[j] - 1) * W
        base′ = (j - 1) * W′
        for i′ = 1:m
            i = rows[i′]
            b = (ch[base + ((i - 1) >> 6) + 1] >> ((i - 1) & 63)) & 1
            ch′[base′ + ((i′ - 1) >> 6) + 1] |= b << ((i′ - 1) & 63)
        end
    end
    X′[1:m, end] .= true
    X′[m+1, 1:n] .= true
    return X′
end

function pkg_data(
    deps :: DepsProvider{P,D},
    reqs :: SetOrVec{P} = deps.packages;
) where {P,D}
    data = Dict{P,D}()
    work = Set(reqs)
    while !isempty(work)
        p = pop!(work)
        data_p = data[p] = pkg_data(deps, p)
        for (v, deps_pv) in data_p.depends, q in deps_pv
            q in keys(data) && continue
            push!(work, q)
        end
    end
    return data
end

function validate_pkg_data_consistency(data::AbstractDict{P,<:PkgData{P}}, reqs::SetOrVec{P}) where {P}
    available_packages = keys(data)

    # Check that all required packages exist
    for p in reqs
        if p ∉ available_packages
            throw(ArgumentError("Required package $p is not available in the package data"))
        end
    end

    # Check that all dependencies exist
    for (p, data_p) in data
        for deps_pv in values(data_p.depends)
            for q in deps_pv
                if q ∉ available_packages
                    throw(ArgumentError("Package $p depends on $q, but $q is not available in the package data"))
                end
            end
        end

        # Note: Compatibility constraints on unknown packages are allowed
    end
end

function pkg_info(
    deps :: DepsProvider{P},
    reqs :: SetOrVec{P} = deps.packages;
    filter :: Bool = true,
) where {P}
    data = pkg_data(deps, reqs)
    info = pkg_info(data, reqs; filter)
    return info
end

# a `Problem`'s requirements are all of it that reaches T1 — that is the point
# of the boundary — so these are pure conveniences for `pkg_info(_, prob.reqs)`.
# Elsewhere the `Problem` form is the primary one and the requirements form the
# convenience; here the dependence really does run the other way

pkg_info(
    deps :: DepsProvider{P},
    prob :: Problem{P};
    filter :: Bool = true,
) where {P} = pkg_info(deps, prob.reqs; filter)

pkg_info(
    data :: AbstractDict{P,<:PkgData{P}},
    prob :: Problem{P};
    filter :: Bool = true,
) where {P} = pkg_info(data, prob.reqs; filter)

"""
    pkg_info(data, reqs = all packages; filter = true) :: Dict{P,PkgInfo{P,V}}

The **T1 artifact**: the dependency closure of `reqs`, encoded as one `PkgInfo`
per package — one conflict matrix per package, indexed by its interchangeability
classes (`version_classes`, `collapse_classes!`) — plus the one piece of
preprocessing that depends on the registry *alone*: dropping the versions that
cannot be installed whatever else is chosen, because they depend on a package
with no installable version at all, applied repeatedly until nothing more drops
(`mark_installable!`; the literature calls this arc consistency). Nothing here
depends on the version ordering, on user compat or pins, or (beyond the closure)
on the requirements, so the result can be computed once and shared by, or cached
across, arbitrarily many resolves.

`filter = false` skips that prune, leaving the conflict matrices saying exactly
what the data spells out.

Requirement-specific and constraint-specific shrinking — reachability and
redundancy elimination — happens per resolve instead, on the universe the
query's representatives make of this one: see `prepare_pkg_info`.
"""
function pkg_info(
    data :: AbstractDict{P,<:PkgData{P,V}},
    reqs :: SetOrVec{P} = keys(data);
    filter :: Bool = true,
) where {P,V}
    # intern packages as integer indices once, up front: the build phases
    # below run entirely on vectors, and package names reappear only in
    # the final PkgInfo structures. ids follow name order (packages are
    # sorted), so id-sorted dependency and interaction lists coincide
    # with the name-sorted ones the output requires
    pkgs = sort!(collect(keys(data)))
    N = length(pkgs)
    ix = Dict{P,Int}(p => i for (i, p) in enumerate(pkgs))
    datas = [data[p] for p in pkgs]
    nver = Int[length(d.versions) for d in datas]

    # required packages must exist
    for r in reqs
        haskey(ix, r) || throw(ArgumentError(
            "Required package $r is not available in the package data"))
    end

    # conflict masks per distinct compat entry: for each partner q with a
    # conflicting version, the bitmask of conflicting versions of q
    MasksT = Vector{Tuple{Int,Vector{UInt64}}}
    function compute_masks(comp_pv)
        masks = MasksT()
        for (q, comp_pvq) in comp_pv
            qi = get(ix, q, 0)
            # compatibility constraints on unknown packages are allowed
            qi == 0 && continue
            vers = datas[qi].versions
            mask = zeros(UInt64, (length(vers) + 63) >> 6)
            found = false
            for (j, w) in enumerate(vers)
                w in comp_pvq && continue
                mask[((j - 1) >> 6) + 1] |= UInt64(1) << ((j - 1) & 63)
                found = true
            end
            found && push!(masks, (qi, mask))
        end
        return masks
    end

    # compute interactions between packages, keeping each version's
    # masks around for the bit-setting pass below. data providers share
    # compat dicts across a package's versions, so each package has only
    # a handful of distinct entries — a linear identity scan finds them
    # far more cheaply than hashing every version's dict
    vmasks = [Tuple{V,MasksT}[] for _ = 1:N]
    interacts = [Int[] for _ = 1:N]
    objs = Vector{Any}()
    mvals = Vector{MasksT}()
    for pi = 1:N
        interacts_p = interacts[pi]
        vm = vmasks[pi]
        empty!(objs)
        empty!(mvals)
        for (v, comp_pv) in datas[pi].compat
            idx = 0
            for ci = 1:length(objs)
                if objs[ci] === comp_pv
                    idx = ci
                    break
                end
            end
            if idx == 0
                push!(objs, comp_pv)
                push!(mvals, compute_masks(comp_pv))
                idx = length(objs)
            end
            masks = mvals[idx]
            isempty(masks) && continue
            push!(vm, (v, masks))
            for (qi, _) in masks
                (qi == pi || qi in interacts_p) && continue
                push!(interacts_p, qi)
                push!(interacts[qi], pi)
            end
        end
    end
    foreach(sort!, interacts)

    # dependency ids (validating that dependencies exist), interaction
    # block offsets, and the conflicts matrices
    depids = Vector{Vector{Int}}(undef, N)
    dobjs = Vector{Vector{Any}}(undef, N)       # distinct dep vectors
    dcols = Vector{Vector{Vector{Int}}}(undef, N) # their column indices
    offs = Vector{Vector{Int}}(undef, N)
    mats = Vector{BitMatrix}(undef, N)
    for pi = 1:N
        data_p = datas[pi]
        # union the versions' dependency sets; they are shared objects
        # (provider deduplication), so convert each distinct one once
        objs_p = Any[]
        for dv in values(data_p.depends)
            found = false
            for o in objs_p
                if o === dv
                    found = true
                    break
                end
            end
            found || push!(objs_p, dv)
        end
        ids = Int[]
        for dv in objs_p, q in dv
            qi = get(ix, q, 0)
            qi == 0 && throw(ArgumentError(
                "Package $(pkgs[pi]) depends on $q, but $q is not available in the package data"))
            push!(ids, qi)
        end
        ids = sort!(unique!(ids))
        depids[pi] = ids
        # per distinct dep vector, the dependency column indices
        # (self-dependencies get no bits, as before)
        cols_p = Vector{Int}[]
        for dv in objs_p
            cols = Int[]
            for q in dv
                qi = ix[q]
                qi == pi && continue
                push!(cols, searchsortedfirst(ids, qi))
            end
            push!(cols_p, cols)
        end
        dobjs[pi] = objs_p
        dcols[pi] = cols_p
        # interaction block offsets
        n = length(ids)
        off = Vector{Int}(undef, length(interacts[pi]))
        for (k, qi) in enumerate(interacts[pi])
            off[k] = n
            n += nver[qi]
        end
        offs[pi] = off
        # conflicts matrix: n+1 columns of padded_rows(m) bits each — rows
        # 1:m are the singleton classes the build starts from (so one per
        # version here), row m+1 holds the columns' in-universe flags, the rest
        # is word-alignment padding (always zero); column n+1 holds the classes'
        # in-universe flags. Nothing is ever deactivated in a T1 artifact: that
        # is the query's business, and it is `Universe.reps` rather than a bit
        # in here (see BitKernels.jl's header on the two per-class bits)
        m = nver[pi]
        X = falses(padded_rows(m), n + 1)
        # mark all classes & columns in-universe; the column flags live at
        # a fixed bit of each column's chunk span, so set them directly
        # rather than through one strided BitArray write per column
        X[1:m, end] .= true
        W = col_words(X)
        wf = (m >> 6) + 1
        bf = UInt64(1) << (m & 63)
        ch = X.chunks
        @inbounds for j = 1:n
            ch[(j - 1) * W + wf] |= bf
        end
        mats[pi] = X
    end

    # block offset of package qi's versions in package pi's matrix
    block(pi::Int, qi::Int) =
        offs[pi][searchsortedfirst(interacts[pi], qi)]

    # initialize conflicts matrices
    for pi = 1:N
        data_p = datas[pi]
        X = mats[pi]
        V⁻¹ = Dict{V,Int}(v => i for (i, v) in enumerate(data_p.versions))
        # set dependency bits (column lists precomputed above)
        objs_p = dobjs[pi]
        cols_p = dcols[pi]
        for (v, deps_pv) in data_p.depends
            i = V⁻¹[v]
            idx = 0
            for ci = 1:length(objs_p)
                if objs_p[ci] === deps_pv
                    idx = ci
                    break
                end
            end
            for k in cols_p[idx]
                X[i, k] = true
            end
        end
        # set compatibility bits
        for (v, masks) in vmasks[pi]
            i = V⁻¹[v]
            Wx = col_words(X)
            wx = ((i - 1) >> 6) + 1
            bx = UInt64(1) << ((i - 1) & 63)
            xch = X.chunks
            for (qi, mask) in masks
                qi == pi && continue
                Y = mats[qi]
                b = block(pi, qi)
                c = block(qi, pi)
                # partner-side column is contiguous: blit the mask
                ybase = (c + i - 1) * col_words(Y)
                @inbounds for w = 1:length(mask)
                    Y.chunks[ybase + w] |= mask[w]
                end
                # own-side row: one bit per conflicting partner version,
                # written straight into the chunks (the row bit sits at a
                # fixed offset of each column's span)
                @inbounds for w = 1:length(mask)
                    z = mask[w]
                    while !iszero(z)
                        j = ((w - 1) << 6) + trailing_zeros(z) + 1
                        xch[(b + j - 1) * Wx + wx] |= bx
                        z &= z - 1
                    end
                end
            end
        end
    end

    # materialize the package-keyed PkgInfo structures. the build starts at the
    # finest partition there is — one class per version — so that the matrices
    # already have the shape the passes below expect, and one row still means
    # one version, which is what the partition has to be computed from.
    # `collapse_classes!` computes it and merges the rows
    info = Dict{P,PkgInfo{P,V}}()
    for pi = 1:N
        D = pkgs[depids[pi]]
        T = Dict{P,Int}(
            pkgs[qi] => offs[pi][k]
            for (k, qi) in enumerate(interacts[pi]))
        m = nver[pi]
        info[pkgs[pi]] = PkgInfo{P,V}(
            datas[pi].versions, collect(1:m), [[i] for i = 1:m],
            no_shadows(V, m), D, T, mats[pi])
    end

    # the T1 preprocessing: the installability prune, then the partition. Both
    # are properties of the registry alone. The prune deletes versions one of
    # whose dependencies has no versions at all, repeating until nothing more
    # goes (the literature calls this arc consistency); that is a sound
    # approximation of deleting versions no valid solution contains, and, per
    # the manual's Theory section, exactly the kind of deletion that is safe
    # for *every* ordering and requirement set. The partition is row equality.
    # Reachability and redundancy elimination are not of that kind — both are
    # stated in terms of the version ordering, and reachability in terms of the
    # requirements too — so they run per resolve, in `prepare_pkg_info`.
    #
    # the prune runs first because it can only make the partition coarser:
    # deleting versions removes rows to distinguish and columns to differ in.
    if filter
        mark_installable!(info)
        drop_unmarked!(info)
    end
    collapse_classes!(info)

    return info
end
