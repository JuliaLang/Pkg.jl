"""
    Resolver.UnsatCores

Minimal explanations of unsatisfiability, over assumption literals: two
questions about a `SAT` instance and an ordered collection of literals the
caller could assume. `sat_mus` returns a minimal subset of them that is
unsatisfiable already — drop any one of its literals and the rest is
satisfiable. `sat_mcses` enumerates the minimal repairs: every subset whose
removal makes everything else satisfiable. Answers come back as subsequences of the collection they were asked
about, and the order it is given in is the caller's only knob: conflicts avoid
the literals at the front, repairs take the ones at the back.

For the diagnostics machinery, whose relaxations are assumption literals rather
than packages. These two names are this module's API; `Resolver` itself
exports none of them.
"""
module UnsatCores

export sat_mus, sat_mcses

using ..Resolver: SAT, PicoSAT, sat_assume_var, sat_solve

# Everything not exported is internal to this module: the solve wrapper, the
# failed-assumption reader, the shrink pass, and the grow pass with the
# single-repair pair (`sat_mss`, `sat_mcs`) it is shared with — which the
# enumeration is built out of, and which no caller has asked for on its own;
# `sat_mcses(sat, lits; limit = 1)` is one solve away if one does.
#
# Everything here works on raw assumption literals: an ordered vector of distinct
# integers, each of which the caller could hand to `sat_assume_var`. Nothing about
# them is package-specific, so a relaxation object can be anything a literal can
# guard — an activation literal for a whole class of constraints works exactly as
# well as a package variable, which is the point: the caller these exist for
# relaxes classes, not packages. Nothing here translates package names either; a
# caller that wants to ask about packages assumes each one's `sat.vars[p]`.
#
# Candidate order is the caller's control knob:
#
#   * conflict shrinking attempts to delete earlier candidates first, so the
#     core it returns is biased *away from* the head of the collection;
#   * repair growing attempts to keep earlier candidates first, so the repair it
#     returns is biased *toward* the tail.
#
# Put what you would rather keep first. Results come back as subsequences of the
# candidate collection.
#
# Determinism, precisely. Nothing here depends on hash order, iteration order or
# randomness, so a given sequence of queries against a freshly built instance
# always produces the same answers. Within one instance, a grown repair is better
# than that: it is fixed by the candidate order alone, because a candidate is kept
# exactly when keeping it is satisfiable, which is a property of the instance and
# not of the solver. The conflict answers are not, and cannot be while they are
# seeded from the solver's failed-assumption core: that core depends on the
# solver's accumulated state, so asking the same question twice on the same
# instance can return a different — equally minimal — core, and the repair
# enumeration can discover the same complete set of answers in a different order.
# Seeding is what makes conflict extraction cheap (see `mus_shrink_linear`), so
# this is the trade being made deliberately; a caller that needs one canonical
# core across differently warmed solvers would have to give the seeding up and
# pay a solve per candidate.
#
# Every query is a solve under a *subset of the candidate assumptions*: no
# function here adds a clause to the instance. That is deliberate. It keeps the
# instance's clause set untouched, so the instance stays reusable for anything
# else afterwards, and it keeps these queries inside the class that downstream
# licensing arguments cover (they are stated for assumption subsets of a fixed
# clause set, not for instances augmented with blocking clauses).

# solve with exactly `lits` assumed (assumptions are consumed by the solve)
function sat_solve_assuming(sat::SAT, lits)
    for l in lits
        sat_assume_var(sat, l)
    end
    return sat_solve(sat)
end

# the failed-assumption core of the solve that just returned unsatisfiable, as
# a subsequence of `cands`, which must be exactly what that solve assumed --
# picosat aborts the process if queried outside that state, so callers have to
# keep track of which solve they are reading
failed_assumptions(sat::SAT, cands::AbstractVector{Int}) =
    Int[l for l in cands if PicoSAT.failed(sat.pico, l) ≠ 0]

## minimal unsatisfiable subsets

"""
    sat_mus(sat, lits) -> Vector{Int}

A minimal unsatisfiable subset of the assumption literals `lits`: a
subsequence `M` such that `sat` is unsatisfiable assuming `M`, while it is
satisfiable assuming any proper subset of `M` (equivalently: assuming `M` with
any single literal dropped). `lits` must be distinct.

Returns an empty vector when `sat` is satisfiable assuming all of `lits` — and
also when `sat` is unsatisfiable on its own, since the empty set is then itself
the minimal unsatisfiable subset. Call `sat_solve(sat)` to tell the two
apart if the instance is not known to be satisfiable without assumptions.

Deletion is attempted in the order given, so the result is biased away from the
front of `lits`; it is otherwise unspecified which MUS is returned when
several exist, and asking twice on one instance may not return the same one —
the seed comes from the solver's failed-assumption core, which depends on the
solver's state. A fresh instance asked the same sequence of questions always
answers identically; see the note on determinism at the top of this file.

Cost: one solve to check the whole set, then at most one solve per element of
the solver's failed-assumption core, which is where the work goes — see
`mus_shrink_linear`.
"""
function sat_mus(sat::SAT, lits::AbstractVector{<:Integer})
    cands = collect(Int, lits)
    @assert allunique(cands)
    sat_solve_assuming(sat, cands) && return Int[]
    return sat_mus_core(sat, cands)
end

# MUS extraction from the state left by an unsatisfiable solve that assumed
# exactly `cands`: seed with the solver's failed-assumption core — sound
# because the instance together with the failed assumptions is unsatisfiable,
# and usually a big win because that core is much smaller than `cands` — then
# shrink the seed to a minimal subset
"""
    sat_mus(sat, fixed, lits) :: Vector{Int}

A minimal subset of `lits` that is unsatisfiable *with* `fixed` assumed
throughout. `fixed` is not minimized and is not in the answer: it is what the
question is being asked about, not part of what the answer blames.

Empty when `fixed` and `lits` together are satisfiable.

Asking it this way is what keeps two cores from disagreeing. A single core over
both would be free to blame a different `fixed` than the caller settled on,
and then the two halves of an explanation are about different things.
"""
function sat_mus(
    sat   :: SAT,
    fixed :: AbstractVector{<:Integer},
    lits  :: AbstractVector{<:Integer},
)
    f = collect(Int, fixed)
    cands = collect(Int, lits)
    @assert allunique(cands)
    all = [f; cands]
    sat_solve_assuming(sat, all) && return Int[]
    held = Set{Int}(f)
    seed = Int[l for l in failed_assumptions(sat, all) if l ∉ held]
    rank = Dict{Int,Int}(l => i for (i, l) in enumerate(cands))
    sort!(seed; by = l -> get(rank, l, typemax(Int)))
    return mus_shrink_linear(sat, seed, f)
end

function sat_mus_core(sat::SAT, cands::AbstractVector{Int})
    seed = failed_assumptions(sat, cands)
    # ... in the order the caller asked, not the order the solver happened to
    # fail in. Every order gives a minimal subset and they need not be the
    # same one; deletion is tried first on what comes first, so the order is
    # how a caller says which assumptions it would rather not be blamed
    rank = Dict{Int,Int}(l => i for (i, l) in enumerate(cands))
    sort!(seed; by = l -> get(rank, l, typemax(Int)))
    return mus_shrink_linear(sat, seed)
end

# a single deletion pass, in candidate order. one pass suffices: satisfiability
# is monotone under dropping assumptions, so once deleting `s` has been found
# satisfiable — i.e. `s` is necessary, given everything still kept — deleting
# `s` from any later, smaller working set is satisfiable too, and retrying it
# can only ever confirm that. so at the end of the pass every kept element has
# been shown necessary against a superset of the final set, hence is necessary
# in it, hence the final set is minimal: no restart needed. the refinement below
# rides on the same argument — it may drop an element the pass had already found
# necessary, which is sound precisely because what "necessary" was established
# against was a superset of what remains.
#
# a deletion attempt that comes back unsatisfiable also refines the working set
# to that solve's own failed-assumption core, which is what makes this pass
# cheap even when the candidate set is huge and the core tiny: the first such
# attempt typically collapses the working set to a handful of literals, and the
# rest of the pass skips everything it dropped. measured on a registry-scale
# instance (1072 packages, 67k versions, 215k clauses) with every package's
# "installed" literal as a candidate and the failed-assumption seeding bypassed,
# so all 1072 candidates enter the pass:
#
#   linear pass + refinement          3–4 solves      0.02–0.14 s
#   dichotomic (QuickXplain)         17–23 solves     0.06–0.32 s
#   linear pass, no refinement     1072 solves        0.43–0.47 s
#
# and on the opposite shape, where the core is nearly everything ("package p is
# required but each of its 613 versions is excluded", 1685 candidates):
#
#   linear pass + refinement        615 solves        6.4 s
#   dichotomic (QuickXplain)       1228 solves       14.5 s
#
# QuickXplain's O(k·log(n/k)) needs k ≪ n to pay off, which is exactly the case
# refinement already handles in one solve, and it loses outright when k ≈ n —
# so there is no measured shape here where a second strategy earns its keep.
function mus_shrink_linear(sat::SAT, core::Vector{Int},
                           fixed::Vector{Int} = Int[])
    keep = trues(length(core))
    trial = Int[]
    for i in eachindex(core)
        keep[i] || continue # already dropped by a refinement below
        keep[i] = false
        empty!(trial)
        append!(trial, fixed)
        for j in eachindex(core)
            keep[j] && push!(trial, core[j])
        end
        if sat_solve_assuming(sat, trial)
            keep[i] = true # necessary: without it the rest is satisfiable
        else
            # still unsatisfiable, so core[i] is redundant. moreover this
            # solve's own failed-assumption core is a still-unsatisfiable
            # subset of what was assumed, so drop everything outside it too
            for j in eachindex(core)
                keep[j] || continue
                PicoSAT.failed(sat.pico, core[j]) ≠ 0 || (keep[j] = false)
            end
        end
    end
    return Int[core[i] for i in eachindex(core) if keep[i]]
end

## one repair: the pair the enumeration is built out of
#
# Unexported. The enumeration below grows every satisfiable seed it finds with
# the same pass, and a caller that wants just one repair can ask it for one with
# `limit = 1`; these two exist because the enumeration needs them, and are
# documented because it is built out of them.

"""
    sat_mss(sat, lits) -> Union{Vector{Int}, Nothing}

A maximal satisfiable subset of the assumption literals `lits`: a subsequence
`S` such that `sat` is satisfiable assuming `S`, while it is unsatisfiable
assuming `S` plus any one of the remaining candidates. `lits` must be distinct.

Returns `nothing` if `sat` is unsatisfiable on its own, in which case no subset
of `lits` is satisfiable and neither an MSS nor an MCS exists. Returns all of
`lits` when they are jointly satisfiable.

Candidates are tried for inclusion in the order given, so the result is the
greedy keep-in-order subset — which is how the caller expresses which
assumptions it would rather keep (equivalently, which it would rather see in
the correction set). Fully determined by the candidate order: a candidate is
kept exactly when keeping it is satisfiable, so repeated calls agree no matter
what the solver has been asked in between.

Cost: at most one solve per candidate, plus one; often far fewer, since a
candidate already true in the current model is kept without a solve.
"""
function sat_mss(sat::SAT, lits::AbstractVector{<:Integer})
    cands = collect(Int, lits)
    @assert allunique(cands)
    # optimistically try everything at once: one solve for the whole answer
    sat_solve_assuming(sat, cands) && return cands
    # otherwise the empty subset must be satisfiable for any subset to be
    sat_solve_assuming(sat, Int[]) || return nothing
    keep = falses(length(cands))
    sat_grow!(sat, cands, keep, true)
    return Int[cands[i] for i in eachindex(cands) if keep[i]]
end

"""
    sat_mcs(sat, lits) -> Union{Vector{Int}, Nothing}

A minimal correction set of the assumption literals `lits`: the complement of a
`sat_mss` result — a subsequence `C` such that `sat` is satisfiable
assuming `lits ∖ C`, while it is unsatisfiable assuming `lits ∖ C′` for every
proper subset `C′ ⊊ C`. Dropping `C` is thus a minimal repair.

Empty when `lits` are jointly satisfiable; `nothing` when `sat` is
unsatisfiable on its own, so that no repair exists. Biased toward dropping
candidates late in the order — put what you would rather keep first. Same cost
and determinism as `sat_mss`.
"""
function sat_mcs(sat::SAT, lits::AbstractVector{<:Integer})
    mss = sat_mss(sat, lits)
    mss === nothing && return nothing
    keep = Set{Int}(mss)
    return Int[l for l in lits if l ∉ keep]
end

# grow the satisfiable subset of `cands` selected by `keep` into a maximal
# satisfiable one, trying the candidates it does not already contain in order.
# `modeled` says the solver's last solve was the satisfiable solve of exactly
# that subset, so its model is available — and must be tracked honestly:
# picosat aborts the process if a model is dereferenced when the last solve did
# not return satisfiable
function sat_grow!(
    sat     :: SAT,
    cands   :: Vector{Int},
    keep    :: BitVector,
    modeled :: Bool,
)
    trial = Int[cands[i] for i in eachindex(cands) if keep[i]]
    for i in eachindex(cands)
        keep[i] && continue
        l = cands[i]
        # free ride: a model of the current subset that happens to satisfy `l`
        # is a model of that subset plus `l`, so no solve is needed. only the
        # candidate currently under consideration is taken this way, never a
        # later one, which keeps the result exactly the greedy-in-order subset
        if modeled && PicoSAT.deref(sat.pico, l) > 0
            keep[i] = true
            push!(trial, l)
            continue
        end
        push!(trial, l)
        if sat_solve_assuming(sat, trial)
            keep[i] = true
            modeled = true
        else
            pop!(trial)
            modeled = false # an unsatisfiable solve leaves no usable model
        end
    end
    return keep
end

"""
    sat_mcses(sat, lits; limit = typemax(Int)) -> Vector{Vector{Int}}

Enumerate the minimal correction sets of the assumption literals `lits`: every
subsequence `C` meeting the `sat_mcs` contract, each exactly once. The
results are undominated — none is a subset of another, since each is minimal —
and complete unless `limit` cut the search short.

`[Int[]]` (one empty correction set) when `lits` are jointly satisfiable, and
`Vector{Int}[]` when `sat` is unsatisfiable on its own, so that no repair
exists at all.

MARCO-style: a separate "map" instance over one variable per candidate tracks
which subsets remain unexplored and supplies each seed; the seed is classified
by a single assumption-subset query against `sat`, then grown to a maximal
satisfiable subset (reporting its complement) or shrunk to a MUS, and either
way the region it settles is blocked *in the map*. No clause is ever added to
`sat` itself.

The complete result is exactly the instance's set of correction sets, but the
order they are discovered in is unspecified, and — because the shrink step is
seeded from the solver's failed-assumption core — can differ between calls on
one instance. That is what `limit` truncates, so `limit = 1` asks for *a* minimal
repair rather than the one the candidate order prefers: the candidate order
governs how each repair is grown (later candidates are the ones dropped, as the
grow pass has it), but which satisfiable seed the map offers first is the map's
business. In practice the two have coincided — the map runs through the
candidates in index order too, so the first repair reported has come back
preference-ordered on every shape measured, at slightly less cost than growing
one from nothing — but that is a tendency of the search, not a promise; a caller
that needs the preferred repair should enumerate without a limit and choose.

The map prefers large seeds, which tends to surface small correction sets first.
There can be exponentially many correction sets, so pass `limit` when
enumerating over anything but a small candidate set. Cost: per iteration one map
solve, one classifying solve and a grow or shrink; the number of iterations is
the number of MUSes plus the number of MCSes discovered.
"""
function sat_mcses(
    sat   :: SAT,
    lits  :: AbstractVector{<:Integer};
    limit :: Integer = typemax(Int),
)
    cands = collect(Int, lits)
    @assert allunique(cands)
    n = length(cands)
    mcses = Vector{Int}[]
    limit ≤ 0 && return mcses
    index = Dict{Int,Int}(l => i for (i, l) in enumerate(cands))
    # the map: one variable per candidate, its models the subsets of the
    # candidate set whose status is not yet implied by what has been found.
    # each iteration adds a clause ruling out the region its seed settles, so
    # the loop ends when the map runs dry — at which point every subset is
    # either contained in a reported maximal satisfiable subset or contains a
    # discovered MUS, which is exactly the condition for having reported every
    # minimal correction set
    # (named `pico_map` rather than `map` so as not to shadow `Base.map`)
    pico_map = PicoSAT.init()
    try
        PicoSAT.adjust(pico_map, n)
        PicoSAT.set_global_default_phase(pico_map, 1) # prefer large seeds
        seed = Int[]
        keep = falses(n)
        while PicoSAT.sat(pico_map) == PicoSAT.SATISFIABLE
            fill!(keep, false)
            empty!(seed)
            for i = 1:n
                PicoSAT.deref(pico_map, i) > 0 || continue
                keep[i] = true
                push!(seed, cands[i])
            end
            if sat_solve_assuming(sat, seed)
                # satisfiable: grow to a maximal satisfiable subset and report
                # its complement, a minimal correction set
                sat_grow!(sat, cands, keep, true)
                push!(mcses, Int[cands[i] for i = 1:n if !keep[i]])
                length(mcses) ≥ limit && break
                # any further maximal satisfiable subset must keep something
                # this one drops
                for i = 1:n
                    keep[i] || PicoSAT.add(pico_map, i)
                end
                PicoSAT.add(pico_map, 0)
            else
                # unsatisfiable: shrink to a MUS — no later seed may contain it
                for l in sat_mus_core(sat, seed)
                    PicoSAT.add(pico_map, -index[l])
                end
                PicoSAT.add(pico_map, 0)
            end
        end
    finally
        PicoSAT.reset(pico_map)
    end
    return mcses
end

end # module UnsatCores
