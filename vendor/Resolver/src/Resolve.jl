# find the optimal solution determined by the priority ordering `by`:
# a package => class-index dict, or nothing when the requirements are
# not jointly satisfiable
function resolve_core(
    sat  :: SAT{P},
    reqs :: SetOrVec{P} = keys(sat.info);
    by   :: Function = identity, # priority ordering
    ord  :: O = nothing, # class ranking (the universe's own layout by default)
    reps :: Dict{P,Vector{Int}} = sat.reps, # the classes the query admits
    restore :: Bool = true, # restore the SAT instance's state before returning
) where {P, O}
    # a requirement the instance doesn't know has no installable version —
    # the filter drops such packages — so it cannot be satisfied
    all(p -> haskey(sat.info, p), reqs) || return nothing
    # a solution exists iff the requirements are jointly satisfiable; the
    # check only assumes, so an unsatisfiable resolve leaves no state behind
    is_satisfiable(sat, reqs) || return nothing
    sol = Dict{P,Int}() # the solution
    # capture the solution (it covers all the requirements) before the
    # clauses added by the descent invalidate the solver's assignment
    extract_solution!(sat, sol)

    # the best class of `p` the query admits: the first in its ranking that
    # `reps` gives a member, the emptied ones being forbidden already
    best_class(p::P) =
        hinted_class(reps[p], ranking(ord, p, nclasses(sat.info[p])))

    # optimize each package in `opts` to its best feasible version wrt quality,
    # pinning each as it goes (in priority order); return the newly-reachable
    # dependencies of the chosen versions that still need optimizing
    function optimize!(opts::Set{P}, seen::Set{P})
        layer = sort!(collect(opts); by)
        # optimistic joint probe: assume the best admissible class of every
        # package in the layer that the current model doesn't already have
        # there. when jointly feasible — the common case — one solve pins the
        # whole layer, and joint feasibility of those classes witnesses each
        # of the sequential optimizations below, so the layered answer is
        # unchanged. a failed probe tells us nothing and the sequential path
        # proceeds as usual (skipped for a single package, whose own probe
        # covers it). a class the query emptied is never assumed: it is
        # forbidden at level 0, and one such assumption would fail the probe
        # for the whole layer
        todo = Pair{P,Int}[]
        for p in layer
            c = best_class(p)
            sol[p] == c || push!(todo, p => c)
        end
        if length(todo) > 1
            for (p, c) in todo
                sat_assume(sat, p, c)
            end
            sat_solve(sat) && extract_solution!(sat, sol)
        end
        for p in layer
            optimize_version!(sat, sol, p, ord, reps)
            # fix optimized class
            sat_add(sat, p, sol[p])
            sat_add(sat)
        end
        # next optimization set: new dependencies of the chosen classes
        opts′ = empty(opts)
        for p in opts
            info_p = sat.info[p]
            i = sol[p]
            for (j, q) in enumerate(info_p.depends)
                info_p.conflicts[i, j] || continue
                q ∉ seen && push!(opts′, q)
            end
        end
        return opts′
    end

    function descend!()
        # force all requirements
        for p in reqs
            sat_add(sat, p)
            sat_add(sat)
        end
        # optimize quality in priority order, layer by layer
        opts = Set{P}(reqs)
        seen = copy(opts)
        while true
            @assert opts ⊆ keys(sol)
            opts = optimize!(opts, seen)
            isempty(opts) && break
            union!(seen, opts)
        end
        # prune to the packages the descent reached: the SAT model may set
        # variables of unreachable packages true
        filter!(kv -> first(kv) in seen, sol)
    end

    # `restore = true` rolls the instance's clauses back (reusable-instance
    # contract); `restore = false` runs at the top level, leaving the instance
    # constrained by the requirements and the solution's pins — measurably
    # faster (picosat keeps its learned clauses), for single-use instances only.
    if restore
        with_temp_clauses(descend!, sat)
    else
        descend!()
    end

    return sol
end

"""
    resolve(data, prob::Problem; by = identity, diagnose = true, upstream = true)
        -> Union{Dict{P,V}, Diagnosis{P,V}, Nothing}
    resolve(data, reqs; by = identity, diagnose = true, upstream = true)

Resolve the requirements `reqs` against the package universe described by
`data`, returning the optimal solution as a dict mapping each needed package
to its chosen version, or a [`Diagnosis`](@ref) when the requirements are not
jointly satisfiable. The solution covers every requirement and is exactly the
dependency closure of the requirements under its own chosen versions.

A `Diagnosis` says which requirements cannot hold together, why, and what the
user could change to make them; `show`ing it prints the report. Pass
`diagnose = false` for the bare `nothing` instead, which is what a caller that
only wants the verdict should do — the diagnosis costs several more solves and
one resolve per fix on the menus it offers.

Where `data` is a `DepsProvider` or a dict of `PkgData`, a diagnosis also says
what someone *else* could change: a release of a package on the page, supporting
a package the query narrowed, that a resolve on the data so modified says would
settle a conflict — see [`Upstream`](@ref Resolver.Diagnostics.Upstream).
`upstream = false` skips the search, which costs one such resolve per candidate
under a budget per report.

A [`Problem`](@ref) additionally constrains the admissible versions with user
constraints; the answer is the one the same universe with those versions
deleted would give. The requirements form is the unconstrained problem — a
constrained resolve is spelled by building the `Problem`.

The returned solution is the *layered solution*: requirements are optimized
first, in the priority order induced by `by` (each package maximized to its
best feasible version given the choices already made), then the dependencies
of the chosen versions, layer by layer along the dependency graph. See the
manual's Theory section for the precise semantics and the guarantees it
carries.

`data` may be a `DepsProvider`, a dict of `PkgData`, a dict of `PkgInfo`, or
a `SAT` instance. The `SAT` method takes bare requirements and so has no
constraints to attribute a failure to: it answers `nothing`, and accepts
`restore::Bool = true` instead of `diagnose` — when true the instance's clauses
are restored before returning so the instance can be reused, and
`restore = false` is faster for single-use instances.

The other methods accept `order` as well, and the `DepsProvider` and `PkgData`
ones `upstream` besides:

  * `order`: the *version* preference ordering, as a callable mapping a package
    to a `lt` comparator over its versions ("is preferred to"). The default,
    `nothing`, means the order the universe already lists them in — which for a
    T1 artifact (see [`pkg_info`](@ref Resolver.pkg_info)) is the canonical one
    the registry state fixes. The ordering is not a constraint: it selects among
    the valid solutions rather than changing which ones are valid, so it is a
    parameter here instead of part of the `Problem`, and one artifact serves
    every ordering.

    The universe is built out of *interchangeability classes* — sets of versions
    nothing in the registry can tell apart (see
    [`pkg_info`](@ref Resolver.pkg_info)) — so `order` decides two things: which
    class the answer picks, and which member of that class it names, namely the
    best one the query admits.
"""
function resolve(
    sat  :: SAT{P,V},
    reqs :: SetOrVec{P} = keys(sat.info);
    by   :: Function = identity, # priority ordering
    restore :: Bool = true, # restore the SAT instance's state before returning
) where {P,V}
    sol = resolve_core(sat, reqs; by, restore)
    sol === nothing && return nothing
    # a solution names classes; the version each stands for is `reps`
    return Dict{P,V}(
        p => sat.info[p].versions[sat.reps[p][i]] for (p, i) in sol)
end

# resolve a universe that `prepare_pkg_info` has already ranked & filtered
function resolve_prepared(
    univ :: Universe{P,V},
    prob :: Problem{P};
    by   :: Function = identity, # package ordering
    order = nothing, # version ordering
    diagnose :: Bool = false,
) where {P,V}
    sat = SAT(univ)
    try
        # the instance is single-use, so don't bother restoring its state. an
        # unsatisfiable resolve adds no clause anyway — it stops at the
        # feasibility check, which only assumes — so the instance a diagnosis
        # gets is the one the query posed, whichever way this is asked
        sol = resolve(sat, prob.reqs; by, restore=false)
        sol === nothing || return sol
        diagnose || return nothing
        # every question a diagnosis asks is a relaxation of `prob`, which this
        # universe was filtered for and so answers (Theorem C): the artifact
        # behind it is not needed and does not have to have been kept
        return Diagnostics.diagnose(sat, prob, univ; by, order)
    finally
        finalize(sat)
    end
end

"""
    relaxations(prob) :: Dict{Symbol, Union{Nothing, Set{P}}}

Everything `prob` constrains, as the relaxation that lifts all of it: per kind,
the packages that kind names, or `nothing` for one that speaks about every
package. This is what [`relax`](@ref Resolver.relax) takes, so
`relax(univ, prob, prob.reqs, relaxations(prob))` is the bottom of the
relaxation lattice — the empty query — and any part of it is a point between.
"""
relaxations(prob::Problem{P}) where {P} =
    Dict{Symbol, Union{Nothing, Set{P}}}(
        kind => c.named for (kind, c) in prob.constraints)

"""
    RelaxedProblem

A relaxation of a query, together with what answering it on the universe that
query was filtered for takes: `resolve(sat, rp)` returns what
`resolve(info, rp.prob)` returns, without preparing again.

Built by [`relax`](@ref Resolver.relax), which *derives* the relaxed problem by
withdrawing demands rather than accepting one — so that `rp.prob` being a
relaxation of `rp.base` is a consequence of how the value was made rather than a
claim about an argument — and settles there what every solve would otherwise
recompute: the member each class stands for under the relaxed problem, and the
order those members rank the classes in.

Those two are indexed by the class layout of the universe `relax` was given, so
a `RelaxedProblem` is stale if that universe is filtered again afterwards.
Nothing does that: `drop_unmarked!` is reachable only from `prepare_pkg_info`,
which builds a universe rather than shrinking one already in use.
"""
struct RelaxedProblem{P, O}
    base :: Problem{P} # the query this relaxes — what it is a relaxation *of*
    prob :: Problem{P} # the relaxed query, derived from `base`
    reps :: Dict{P, Vector{Int}} # per class, its member under `prob`
    # per package, the ranking `prob` puts its classes in, for the ones it moved
    # — or `nothing`, the universe's own layout, when it moved none
    ord  :: O
end

"""
    relax(univ, Q, drop_reqs = P[], drop_constraints = ...; order = nothing)

The relaxation of `Q` that stops requiring `drop_reqs` and lifts the constraints
`drop_constraints`, ready to resolve against `univ` — the universe
`prepare_pkg_info(info, Q; order)` produced. Lifting nothing gives `Q` itself,
which is a relaxation of `Q`; lifting everything
([`relaxations`](@ref Resolver.relaxations)) gives the empty query. Anything `Q`
does not carry is ignored, a constraint that is not there being already lifted.

`drop_constraints` maps a kind to the packages it is lifted for — or to `nothing`, which
lifts it for every package it speaks about, and so lifts it entirely.

`order` is the version preference ordering, as `resolve` takes it, and has to be
the one `univ` was ranked in: it is what "better" means, and the universe and the
relaxation have to mean the same thing by it. It is consumed here, so the
permutations it induces are computed once however often the result is resolved.
"""
function relax(
    univ :: Universe{P,V},
    Q    :: Problem{P},
    drop_reqs        :: SetOrVec{P} = P[],
    drop_constraints :: AbstractDict{Symbol} = EmptyDict{Symbol,Nothing}();
    order = nothing, # version ordering
) where {P,V}
    R = relax(Q, drop_reqs, drop_constraints)
    # what `R` makes of the classes `Q` laid out, in one pass: the member each
    # class stands for under `R` and the order those members rank the classes
    # in. The universe is not relaid out — the clauses say which classes exist,
    # depend and conflict, and `R` changes none of that — so the ranking is
    # threaded through the descent instead, and the representatives name the
    # answer at the end.
    info = univ.info
    reps, cperms = class_ranking(info, R, version_permutations(info, order))
    return RelaxedProblem(Q, R, reps, cperms)
end

# Answer a relaxation on the instance built for the query it relaxes: the
# descent again, in the order `rp` ranks the classes and over the classes `rp`
# admits, with `rp`'s deactivations in place of the query's for the duration
# and the query's put back after. What is admissible the descent learns from
# the representatives the frame was built from, not from `sat.reps`, which
# still names the query's: a class the query emptied may well be admissible
# here. The instance is left exactly as it was found — same clauses, same
# forbidden classes, same decision phases — so one universe answers as many
# relaxations as it is asked, in any order.
function resolve(
    sat :: SAT{P,V},
    rp  :: RelaxedProblem{P};
    by  :: Function = identity, # package ordering
) where {P,V}
    info = sat.info
    reps, ord = rp.reps, rp.ord
    sol = with_deactivations(sat, deactivated_lits(sat, reps)) do
        rehint_classes!(sat, sat.reps, nothing, reps, ord)
        try
            resolve_core(sat, rp.prob.reqs; by, ord, reps)
        finally
            rehint_classes!(sat, reps, ord, sat.reps, nothing)
        end
    end
    sol === nothing && return nothing
    # a solution names classes, and it is the relaxation's representatives that
    # name the versions: a class whose best member the query forbade stands at a
    # better one here, so `sat.reps` would name the wrong version — and is not
    # ours to move
    return Dict{P,V}(p => info[p].versions[reps[p][i]] for (p, i) in sol)
end

# ... building the instance for it, which is the shape to reach for when there
# is a single relaxation to answer; a second one wants the instance kept
function resolve(
    univ :: Universe{P,V},
    rp   :: RelaxedProblem{P};
    by   :: Function = identity, # package ordering
) where {P,V}
    sat = SAT(univ)
    try resolve(sat, rp; by)
    finally
        finalize(sat)
    end
end

# primary entry points: a Problem (requirements + user constraints). each
# builds the T1 artifact for the problem's requirements, then prepares it —
# the T1 info is freshly built and nobody else holds it, so preparation is
# allowed to shrink it in place

function resolve(
    deps :: DepsProvider{P},
    prob :: Problem{P};
    by   :: Function = identity, # package ordering
    order = nothing, # version ordering
    diagnose :: Bool = true,
    upstream :: Bool = true, # look for releases that would fix each conflict
) where {P}
    info = pkg_info(deps, prob)
    ans = resolve_prepared(prepare_pkg_info(info, prob, info; order), prob;
        by, order, diagnose)
    return with_upstream(deps, prob, ans, upstream; by, order)
end

function resolve(
    data :: AbstractDict{P,<:PkgData{P}},
    prob :: Problem{P};
    by   :: Function = identity, # package ordering
    order = nothing, # version ordering
    diagnose :: Bool = true,
    upstream :: Bool = true, # look for releases that would fix each conflict
) where {P}
    info = pkg_info(data, prob)
    ans = resolve_prepared(prepare_pkg_info(info, prob, info; order), prob;
        by, order, diagnose)
    return with_upstream(data, prob, ans, upstream; by, order)
end

# What the package data adds to a diagnosis, and only it can: for each
# conflict, whether a release of some package on the page would settle it (see
# `Diagnostics.upstream_fixes`). A release is a different registry rather than a
# different query, so this is the resolve's to ask and not the diagnosis's, and
# `upstream = false` is how a caller that does not want the probes says so.
with_upstream(data, prob::Problem, ans, upstream::Bool; by, order) =
    upstream && ans isa Diagnostics.Diagnosis ?
        Diagnostics.upstream_fixes(data, prob, ans; by, order) : ans

# a caller-supplied info may be a reusable (or cached) T1 artifact, so this
# method prepares into a dict of its own and leaves the argument alone
function resolve(
    info :: AbstractDict{P,PkgInfo{P,V}},
    prob :: Problem{P};
    by   :: Function = identity, # package ordering
    order = nothing, # version ordering
    diagnose :: Bool = true,
) where {P,V}
    resolve_prepared(prepare_pkg_info(info, prob; order), prob;
        by, order, diagnose)
end

# convenience entry points: bare requirements, with the user constraints (if
# any) given as keywords instead of a `Problem`

resolve(
    deps :: DepsProvider{P},
    reqs :: SetOrVec{P} = deps.packages;
    by     :: Function = identity, # package ordering
    order  = nothing, # version ordering
    diagnose :: Bool = true,
    upstream :: Bool = true,
) where {P} = resolve(deps, Problem(reqs); by, order, diagnose, upstream)

resolve(
    data :: AbstractDict{P,<:PkgData{P}},
    reqs :: SetOrVec{P} = keys(data);
    by     :: Function = identity, # package ordering
    order  = nothing, # version ordering
    diagnose :: Bool = true,
    upstream :: Bool = true,
) where {P} = resolve(data, Problem(reqs); by, order, diagnose, upstream)

resolve(
    info :: AbstractDict{P,PkgInfo{P,V}},
    reqs :: SetOrVec{P} = keys(info);
    by     :: Function = identity, # package ordering
    order  = nothing, # version ordering
    diagnose :: Bool = true,
) where {P,V} = resolve(info, Problem(reqs); by, order, diagnose)

"""
    issatisfiable(data, reqs) -> Bool

Compute `resolve(data, reqs; ..., diagnose = false) !== nothing` more
efficiently, with a single satisfiability check instead of a full optimizing
resolve. Use this when you want to know whether the requirements can be
satisfied but don't need an actual solution — or a report on why not.

`data` may be a `DepsProvider`, a dict of `PkgData`, a dict of `PkgInfo`, or a
`SAT` instance, and a `Problem` may be passed in place of the requirements and
keywords, as with `resolve`. The `by` and `order` keywords are not accepted
since they affect which solution `resolve` picks, not whether one exists. The `SAT` method leaves the instance unchanged, so it can be reused.
"""
function issatisfiable(
    sat  :: SAT{P},
    reqs :: SetOrVec{P} = keys(sat.info),
) where {P}
    # a requirement the instance doesn't know has no installable version —
    # the filter drops such packages — so it cannot be satisfied
    all(p -> haskey(sat.info, p), reqs) || return false
    # the requirements are satisfiable iff this one solve says so; it only
    # assumes, so the instance is left exactly as it was found
    return is_satisfiable(sat, reqs)
end

# check a universe that `prepare_pkg_info` has already ranked & filtered
function issatisfiable_prepared(
    univ :: Universe{P,V},
    prob :: Problem{P},
) where {P,V}
    sat = SAT(univ)
    try issatisfiable(sat, prob.reqs)
    finally
        finalize(sat)
    end
end

# primary entry points, mirroring `resolve`'s: a Problem against each shape of
# package data, each building the T1 artifact and preparing it the same way

function issatisfiable(
    deps :: DepsProvider{P},
    prob :: Problem{P},
) where {P}
    info = pkg_info(deps, prob)
    issatisfiable_prepared(prepare_pkg_info(info, prob, info), prob)
end

function issatisfiable(
    data :: AbstractDict{P,<:PkgData{P}},
    prob :: Problem{P},
) where {P}
    info = pkg_info(data, prob)
    issatisfiable_prepared(prepare_pkg_info(info, prob, info), prob)
end

# a caller-supplied info may be a reusable (or cached) T1 artifact, so this
# method prepares into a dict of its own and leaves the argument alone
issatisfiable(
    info :: AbstractDict{P,PkgInfo{P,V}},
    prob :: Problem{P},
) where {P,V} = issatisfiable_prepared(prepare_pkg_info(info, prob), prob)

# convenience entry points: bare requirements, with the user constraints (if
# any) given as keywords instead of a `Problem`

issatisfiable(
    deps :: DepsProvider{P},
    reqs :: SetOrVec{P} = deps.packages;
) where {P} = issatisfiable(deps, Problem(reqs))

issatisfiable(
    data :: AbstractDict{P,<:PkgData{P}},
    reqs :: SetOrVec{P} = keys(data);
) where {P} = issatisfiable(data, Problem(reqs))

issatisfiable(
    info :: AbstractDict{P,PkgInfo{P,V}},
    reqs :: SetOrVec{P} = keys(info);
) where {P,V} = issatisfiable(info, Problem(reqs))
