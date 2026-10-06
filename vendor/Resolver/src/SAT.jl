"""
    Resolver.Relation{P}(dep, pkg, classes, other, others)

One registry statement, as a diagnostic instance can switch it off — and
everything the statement says, so that a proof can be read off a core without
asking the universe anything. These `classes` of `pkg` either need `other`
installed (`dep`), or rule out its `others` classes (`!dep`):

  * `classes` — the classes of `pkg` the clause's own literals cover. Exactly
    the ones it speaks for: a conflict groups them by pattern, and a pattern
    need not be a run.
  * `others` — the classes of `other` a conflict clause forbids, which is one
    run of them; empty for a dependency, which forbids none and asks only that
    `other` be installed.

It is the unit a clause is emitted in, so it is also the unit a proof can be
minimal down to.
"""
struct Relation{P}
    dep     :: Bool
    pkg     :: P
    classes :: Vector{Int}
    other   :: P
    others  :: UnitRange{Int}
end

mutable struct SAT{P,V}
    info :: Dict{P,PkgInfo{P,V}}
    # per package, the version index each class stands for (0: deactivated) —
    # what turns a solution over classes back into one over versions
    reps :: Dict{P,Vector{Int}}
    pico :: Ptr{Cvoid}
    vars :: Dict{P,Int}
    # the literals forbidding the deactivated classes, sorted; internal.
    # they are asserted as unit clauses inside a push frame, so one sat_pop
    # reactivates every class at once — after which any subset of them can be
    # deactivated again by assumption, no clause rewriting involved
    deact :: Vector{Int}
    # how many push frames are open. picosat reports the current context as a
    # literal rather than a level, and recycles those literals, so counting is
    # the way to know: `with_deactivations` has to reach the deactivation frame
    # with `sat_pop`, which retracts whatever was pushed last, and getting that
    # wrong retracts someone else's clauses instead of the query's
    depth :: Int
    # how many times picosat has been asked to solve, over the instance's whole
    # life. An instrument, and the right one: what a descent costs is a number
    # of solves, and a wall time can't say which of two changes to it made a
    # solve go away and which merely made it faster
    solves :: Int
    # per selector variable, the registry statement it switches on. Empty
    # unless the instance was built to be explained: a selector occurs only
    # negatively, so assuming them all gives back exactly the instance without
    # them, and a core over them is the registry's share of the blame
    why :: Dict{Int,Relation{P}}
end

function Base.show(io::IO, sat::SAT)
    show(io, typeof(sat))
    p = length(sat.vars)
    v = PicoSAT.var_count(sat.pico)
    c = PicoSAT.clause_count(sat.pico)
    print(io,
        "(packages: ", p,
        ", classes: ", v-p,
        ", clauses: ", c, ")")
end

# variable indices:
#   p     vars[p]     package p chosen
#   p@c   vars[p]+c   class c of p chosen
#   p@≤k  lads[p]+k   some class ≤ k of p chosen (prefix ladder,
#                     only for packages with several classes)
#
# A variable is a *class*, not a version: class members are indistinguishable
# to everything in the registry, so no solution can depend on which member
# stands for a class, and the instance is the smaller for it. `sat.reps` names
# the member at the end.
#
# returns the (sorted) names, the two index maps, and the last used variable
function sat_variables(
    info :: Dict{P, <: PkgInfo{P}},
) where {P}
    # sort names for predictability
    names = sort!(collect(keys(info)))
    N = 1
    vars = Dict{P,Int}()
    lads = Dict{P,Int}()
    for p in names
        vars[p] = N
        n_p = nclasses(info[p])
        # 1 variable for package
        # n_p variables for classes
        N += 1 + n_p
        if n_p ≥ 2
            # n_p prefix-ladder variables at lads[p]+1 : lads[p]+n_p
            lads[p] = N - 1
            N += n_p
        end
    end
    return names, vars, lads, N - 1
end

# append the literals for "no class in lo:hi of the package
# with variable base v, ladder base l, and n classes is chosen"
function run_lits!(lits::Vector{Int}, v::Int, l::Int, lo::Int, hi::Int, n::Int)
    if lo == hi
        push!(lits, -(v + lo))
    elseif lo == 1 && hi == n
        push!(lits, -v)
    elseif lo == 1
        push!(lits, -(l + hi))
    else
        push!(lits, -(l + hi), l + lo - 1)
    end
    return lits
end

function SAT(
    univ :: Universe{P,V};
    # record a selector per registry statement, so a core can say which of
    # them a query cannot live with. Off for resolving: the clauses are then
    # exactly as they were, and nothing extra is emitted
    explain :: Bool = false,
) where {P,V}
    info = univ.info
    names, vars, lads, N = sat_variables(info)

    why = Dict{Int,Relation{P}}()
    # instantiate picosat solver
    pico = PicoSAT.init() # TODO: use jl_malloc?
    try # free memory on error
        PicoSAT.adjust(pico, N)

        lits = Int[]
        # close a clause, with a selector of its own when explaining
        function close!(r::Union{Nothing,Relation{P}})
            if explain && r !== nothing
                v = PicoSAT.inc_max_var(pico)
                why[v] = r
                PicoSAT.add(pico, -v)
            end
            PicoSAT.add(pico, 0)
        end
        # default unconstrained variables to false: models then carry
        # fewer spuriously-true packages ("junk"), which makes solves
        # faster and improvement steps land on better versions
        PicoSAT.set_global_default_phase(pico, 0)
        # ... except each package's best class, which defaults to
        # true: when a package must be chosen the solver tries its best
        # class first, so models land at or near the optimum and the
        # descent's improvement loops mostly never need to run
        for v_p in values(vars)
            PicoSAT.set_default_phase_lit(pico, v_p + 1, 1)
        end

        # generate SAT problem
        for p in names
            info_p = info[p]
            n_p = nclasses(info_p)
            v_p = vars[p]

            # package implies some class
            #   p => OR_i p@i
            PicoSAT.add(pico, -v_p)
            for i = 1:n_p
                PicoSAT.add(pico, v_p + i)
            end
            PicoSAT.add(pico, 0)

            # class implies its package
            #   p@i => p
            for i = 1:n_p
                PicoSAT.add(pico, -(v_p + i))
                PicoSAT.add(pico, v_p)
                PicoSAT.add(pico, 0)
            end

            # prefix ladder: L_k holds iff some class ≤ k is chosen.
            # the two upward directions make chosen classes force their
            # ladder suffix true; the completion direction, together with
            # at-most-one below, forces the ladder prefix *below* the
            # chosen class false — which the interval conflict literals
            # rely on when they occur positively
            if n_p ≥ 2
                l_p = lads[p]
                for k = 1:n_p
                    # p@k => L_k
                    PicoSAT.add(pico, -(v_p + k))
                    PicoSAT.add(pico, l_p + k)
                    PicoSAT.add(pico, 0)
                end
                for k = 2:n_p
                    # L_(k-1) => L_k
                    PicoSAT.add(pico, -(l_p + k - 1))
                    PicoSAT.add(pico, l_p + k)
                    PicoSAT.add(pico, 0)
                end
                # completion: L_k => p@k OR L_(k-1)
                PicoSAT.add(pico, -(l_p + 1))
                PicoSAT.add(pico, v_p + 1)
                PicoSAT.add(pico, 0)
                for k = 2:n_p
                    PicoSAT.add(pico, -(l_p + k))
                    PicoSAT.add(pico, v_p + k)
                    PicoSAT.add(pico, l_p + k - 1)
                    PicoSAT.add(pico, 0)
                end
                # classes are mutually exclusive:
                #   p@k => no class < k (linear via the ladder)
                for k = 2:n_p
                    PicoSAT.add(pico, -(v_p + k))
                    PicoSAT.add(pico, -(l_p + k - 1))
                    PicoSAT.add(pico, 0)
                end
            end

            # dependencies, one clause per maximal run of classes
            # sharing the dependency (dep sets change rarely across
            # versions, so runs are long):
            #   (some class in run chosen) => q
            l_p = get(lads, p, 0)
            for (k, q) in enumerate(info_p.depends)
                v_q = vars[q]
                i = 1
                while i ≤ n_p
                    if info_p.conflicts[i, k]
                        lo = i
                        while i < n_p && info_p.conflicts[i + 1, k]
                            i += 1
                        end
                        empty!(lits)
                        run_lits!(lits, v_p, l_p, lo, i, n_p)
                        for x in lits
                            PicoSAT.add(pico, x)
                        end
                        PicoSAT.add(pico, v_q)
                        close!(Relation{P}(true, p, collect(lo:i), q, 1:0))
                    end
                    i += 1
                end
            end

            # conflicts are added below, rectangle-encoded
        end

        # conflicts, encoded as rectangles: within each interacting pair's
        # conflict bitmap, group p's classes by their conflict pattern
        # against q (identical patterns are the norm, since conflicts come
        # from shared compat entries) and split each pattern into maximal
        # runs of q's classes. each (class group) × (run) rectangle
        # becomes one clause forbidding "some class in the group chosen
        # AND some class in the run chosen". a side contributes its
        # class literal when it is a singleton, its package variable
        # when every class is covered, prefix-ladder literals when it
        # is an interval — ¬L_hi ∨ L_(lo-1), correct because a chosen
        # class in the interval forces L_hi true and (by at-most-one
        # plus ladder completion) L_(lo-1) false — and otherwise a shared
        # auxiliary trigger defined by one implication per class.
        # triggers occur only negatively, so their one-directional
        # definitions suffice for exact model projection.
        psets = Dict{Tuple{Int,Vector{Int}},Int}() # (v_p, classes) => var
        pat = UInt64[]
        runs = Tuple{Int,Int}[]

        # literal for "some class in S of the package with variable
        # base v and n classes is chosen" (non-contiguous S only)
        function set_trigger(v::Int, S::Vector{Int})
            get!(() -> begin
                t = PicoSAT.inc_max_var(pico)
                for i in S
                    PicoSAT.add(pico, -(v + i))
                    PicoSAT.add(pico, t)
                    PicoSAT.add(pico, 0)
                end
                t
            end, psets, (v, S))
        end

        for p in names
            info_p = info[p]
            n_p = nclasses(info_p)
            v_p = vars[p]
            l_p = get(lads, p, 0)
            for (q, b) in info_p.interacts
                p < q || continue # conflicts are symmetrical
                info_q = info[q]
                n_q = nclasses(info_q)
                v_q = vars[q]
                l_q = get(lads, q, 0)
                Y = info_q.conflicts
                c = info_q.interacts[p]
                W = col_words(Y)
                resize!(pat, W)
                # group p's classes by conflict pattern: the pattern of
                # p@i is the contiguous column c+i of q's matrix
                groups = Dict{Vector{UInt64},Vector{Int}}()
                for i = 1:n_p
                    col_copy!(pat, Y, c + i)
                    clear_rows_above!(pat, n_q)
                    all(iszero, pat) && continue
                    push!(get!(() -> Int[], groups, copy(pat)), i)
                end
                for (pattern, Sg) in groups
                    # p-side literals: interval via the ladder, otherwise
                    # a shared trigger
                    empty!(lits)
                    if Sg[end] - Sg[1] + 1 == length(Sg)
                        run_lits!(lits, v_p, l_p, Sg[1], Sg[end], n_p)
                    else
                        push!(lits, -set_trigger(v_p, Sg))
                    end
                    np_lits = length(lits)
                    # maximal runs of the pattern
                    empty!(runs)
                    prev = -2
                    @inbounds for w = 1:W
                        z = pattern[w]
                        while !iszero(z)
                            j = ((w - 1) << 6) + trailing_zeros(z) + 1
                            z &= z - 1
                            if j == prev + 1
                                runs[end] = (runs[end][1], j)
                            else
                                push!(runs, (j, j))
                            end
                            prev = j
                        end
                    end
                    for (lo, hi) in runs
                        resize!(lits, np_lits)
                        run_lits!(lits, v_q, l_q, lo, hi, n_q)
                        for x in lits
                            PicoSAT.add(pico, x)
                        end
                        close!(Relation{P}(false, p, copy(Sg), q, lo:hi))
                    end
                end
            end
        end
    catch # on error free picosat solver
        PicoSAT.reset(pico)
        rethrow()
    end
    sat = finalizer(finalize, SAT(info, univ.reps, pico, vars, Int[], 0, 0, why))
    try deactivate_classes!(sat)
    catch
        finalize(sat)
        rethrow()
    end
    return sat
end

# the structural instance for a bare artifact: every class stands for its best
# member and nothing is deactivated, which is what an unconstrained query makes
# of it (see `Universe`)
SAT(info :: Dict{P,PkgInfo{P,V}}; explain::Bool = false) where {P,V} =
    SAT(Universe(info); explain)

# Forbid the deactivated classes — the ones this query admits no member of.
#
# This is the *whole* of how a user constraint reaches the solver. It never
# forbids a version, because a version is not something the instance can talk
# about: the members of a class are indistinguishable, so a constraint that
# spares one of them has left the class choosable and there is nothing to say.
# What it can do is empty a class, and an empty class is one unit clause.
#
# The clauses go in a push frame of their own, so production solves see them at
# level 0 (no assumptions) while a single `sat_pop` reactivates every class at
# once — after which any subset can be deactivated again by assuming its
# literal, with no clause rewritten. Nothing pops the frame in production; the
# frame exists so that what is built on top of this can, which is
# `with_classes_relaxed` and `with_deactivations`.
function deactivate_classes!(sat::SAT{P,V}) where {P,V}
    pico = sat.pico
    append!(sat.deact, deactivated_lits(sat, sat.reps))
    for (p, reps_p) in sat.reps
        v_p = sat.vars[p]
        # the structural instance defaults every package's best class to true,
        # so that a package that must be chosen is tried at its best class
        # first. when this query has emptied that class, point the phase at the
        # best class it does admit instead — otherwise the solver's first guess
        # is infeasible for every such package at once
        best = hinted_class(reps_p, ranking(nothing, p, length(reps_p)))
        if best != 1
            PicoSAT.set_default_phase_lit(pico, v_p + 1, 0)
            best == 0 || PicoSAT.set_default_phase_lit(pico, v_p + best, 1)
        end
    end
    return push_forbidden!(sat, sat.deact)
end

# The literals forbidding the classes `reps` gives no representative to, sorted
# — what `sat.deact` is for the query the instance was built for, and what a
# relaxation of that query needs in its place.
function deactivated_lits(sat::SAT{P}, reps::Dict{P,Vector{Int}}) where {P}
    lits = Int[]
    for (p, reps_p) in reps, (i, r) in enumerate(reps_p)
        iszero(r) && push!(lits, forbidden_lit(sat, p, i))
    end
    sort!(lits; by = abs) # dict order must not reach the solver
    return lits
end

# Assert `lits` as unit clauses in a push frame of their own: one `sat_pop`
# retracts all of them at once, and asserting them again is what puts the frame
# back. Nothing to assert means no frame, so a caller that pushed nothing must
# not pop.
function push_forbidden!(sat::SAT, lits::Vector{Int})
    isempty(lits) && return sat
    sat_push(sat)
    for l in lits
        PicoSAT.add(sat.pico, l)
        PicoSAT.add(sat.pico, 0)
    end
    return sat
end

# Run `body` with `deact` forbidden in place of the query's own deactivations,
# and put the query's frame back afterwards, whatever `body` does, so the
# instance is as reusable as it was. Returns `body`'s value.
#
# The deactivation frame has to be the innermost one, since `sat_pop` retracts
# whatever was pushed last: this cannot run inside `with_temp_clauses`, though
# `body` may open one. That is checked rather than trusted — running it one
# frame too deep pops someone else's clauses and never says so — and so is the
# balance on the way out, which is what catches a `body` that pushed and did not
# pop, at the call that did it rather than wherever the damage surfaces.
function with_deactivations(body::Function, sat::SAT, deact::Vector{Int})
    depth = sat.depth
    @assert depth == (isempty(sat.deact) ? 0 : 1) """
        the deactivation frame is not the innermost one — $depth frames are \
        open where $(isempty(sat.deact) ? 0 : 1) is expected"""
    isempty(sat.deact) || sat_pop(sat)
    try
        push_forbidden!(sat, deact)
        try body()
        finally
            isempty(deact) || sat_pop(sat)
        end
    finally
        push_forbidden!(sat, sat.deact)
        @assert sat.depth == depth balance_error(sat, depth)
    end
end

# Run `body` with every class of the universe choosable — the deactivating
# clauses retracted — and put the frame back afterwards. The empty end of
# `with_deactivations`: forbidding nothing is the weakest thing to forbid.
#
# Inside, activation is entirely a matter of assumption: assuming
# `forbidden_lit(sat, p, c)` forbids class `c` of `p` for one solve, and
# assuming all of `sat.deact` states exactly what the frame stated, so any
# subset of the query's deactivations can be imposed one solve at a time with no
# clause added and none rewritten. Restoring re-asserts the same unit clauses,
# because popping a frame discards the clauses asserted in it.
with_classes_relaxed(body::Function, sat::SAT) =
    with_deactivations(body, sat, Int[])

function finalize(sat::SAT)
    pico = sat.pico
    pico == C_NULL && return
    sat.pico = C_NULL
    PicoSAT.reset(pico)
end

sat_new_variable(sat::SAT) = PicoSAT.inc_max_var(sat.pico)

sat_add_var(sat::SAT, v::Integer) = PicoSAT.add(sat.pico, v)
sat_assume_var(sat::SAT, v::Integer) = PicoSAT.assume(sat.pico, v)

sat_add(sat::SAT) = sat_add_var(sat, 0)
sat_add(sat::SAT{P}, p::P, i::Integer=0; not::Bool=false) where {P} =
    sat_add_var(sat, (-1)^not*(sat.vars[p] + i))

sat_assume(sat::SAT{P}, p::P, i::Integer=0; not::Bool=false) where {P} =
    sat_assume_var(sat, (-1)^not*(sat.vars[p] + i))
sat_assume(sat::SAT{P}, v::SetOrVec{P}) where {P} =
    foreach(p -> sat_assume(sat, p), v)
sat_assume(sat::SAT{P}, d::Dict{P,<:Integer}) where {P} =
    for (p, i) in d
        sat_assume(sat, p, i)
    end

# The two facts about this instance a caller can put to it as a raw literal, in
# the `Int` form `sat_assume_var` and the UnsatCores primitives take:

# "package p is installed"
installed_lit(sat::SAT{P}, p::P) where {P} = sat.vars[p]

# "class c of package p is forbidden" — the same literal `deactivate_classes!`
# asserts as a unit clause for a class this query admits no member of, so
# assuming it says what that clause says, for one solve
forbidden_lit(sat::SAT{P}, p::P, c::Integer) where {P} = -(sat.vars[p] + c)

# Solve, consuming whatever has been assumed since the last solve — the caller
# staged the question with `sat_assume`, this answers it. With nothing staged
# the question is the instance itself, which installing no package satisfies,
# so a caller asking about *requirements* wants `is_satisfiable(sat, reqs)`:
# requirements are assumed, not asserted, and an unstaged solve reports them
# satisfiable however unsatisfiable they are.
function sat_solve(sat::SAT)
    sat.solves += 1
    return PicoSAT.sat(sat.pico) == PicoSAT.SATISFIABLE
end

# Are `reqs` jointly installable? The complete question, staged and answered.
function is_satisfiable(sat::SAT{P}, reqs::Union{P,SetOrVec{P}}) where {P}
    sat_assume(sat, reqs)
    sat_solve(sat)
end

const is_unsatisfiable = !is_satisfiable

# iterate the current solution's package => class-index assignments by
# dereferencing the solver's assignment without re-solving: only valid right
# after a solve that returned satisfiable, with no clauses added since --
# ensuring that is the caller's responsibility
function each_solution_index(f::Function, sat::SAT)
    for (p, v_p) in sat.vars
        PicoSAT.deref(sat.pico, v_p) < 0 && continue
        c = 0
        for i = 1:nclasses(sat.info[p])
            PicoSAT.deref(sat.pico, v_p + i) > 0 || continue
            c = i
            break
        end
        @assert c != 0 """
            $p is installed with no class chosen, which `v_p => ⋁ᵢ p@i` forbids:
            the last solve must have returned satisfiable, with no clauses added
            since."""
        f(p, c)
    end
end

# extract the solver's current solution; same contract as
# each_solution_index: the last solve must have returned satisfiable,
# with no clauses added since
function extract_solution!(sat::SAT{P}, sol::Dict{P,Int}) where {P}
    empty!(sol)
    each_solution_index(sat) do p, i
        sol[p] = i
    end
    return sol
end

function solution(sat::SAT{P,V}) where {P,V}
    sol = Dict{P,V}()
    sat_solve(sat) || return sol
    each_solution_index(sat) do p, i
        sol[p] = sat.info[p].versions[sat.reps[p][i]]
    end
    return sol
end

sat_push(sat::SAT) = (sat.depth += 1; PicoSAT.push(sat.pico))
sat_pop(sat::SAT) = (sat.depth -= 1; PicoSAT.pop(sat.pico))

# What an unbalanced body did, said the same way wherever it is caught. An
# exception thrown from a `finally` while another is in flight does not lose it:
# Julia carries both and reports the original as the cause.
balance_error(sat::SAT, depth::Int) =
    "the body left $(sat.depth - depth) push frame(s) open"

function with_temp_clauses(body::Function, sat::SAT)
    depth = sat.depth
    sat_push(sat)
    try body()
    finally
        sat_pop(sat)
        @assert sat.depth == depth balance_error(sat, depth)
    end
end

# How a relaxation ranks a package's classes, and the whole of what the descent
# asks of it: `ord_p[r]` is the class ranked `r`-th. `nothing` is the universe's
# own layout, where a class's rank *is* its index, so the ranking is the range
# of its class indices and costs nothing to say.
#
# Re-ranking invalidates no clause — every clause says which classes exist,
# depend and conflict, and a relaxation changes none of that — so the universe
# is not relaid out and the order is threaded through the descent instead. The
# improvement disjunction has the same size the layout order's would, so the
# descent adds the clauses it always added.
#
# A relaxation moves few packages, and few of the classes of the ones it moves.
# Both sparsities are one fact, and `SparsePerm` is both: the map holds an entry
# only for a package that moved, and that entry holds only the classes that did.
ranking(::Nothing, p, m::Int) = Base.OneTo(m)
ranking(ord::Dict{P,SparsePerm}, p::P, m::Int) where {P} =
    get(ord, p, Base.OneTo(m))

# the class a package's decision phase points at when its classes are
# represented by `reps_p` and ranked by `ord_p`: the best class the query admits,
# or 0 when it admits none
function hinted_class(reps_p::Vector{Int}, ord_p)
    for r in eachindex(ord_p)
        c = @inbounds ord_p[r]
        iszero(reps_p[c]) || return c
    end
    return 0
end

# Move every package's phase hint from where `(from, from_ord)` puts it to where
# `(to, to_ord)` does. A phase is a solver knob rather than a clause, so no
# `sat_pop` takes one back down: an instance that answers one relaxation after
# another has to have each one's hints taken down explicitly before the next
# one's go up, or the first relaxation's guesses leak into the second's solves.
# Settled once per relaxation and not touched again — once the descent pins a
# package it adds a unit clause, and the hint stops mattering.
function rehint_classes!(
    sat      :: SAT{P},
    from     :: Dict{P,Vector{Int}},
    from_ord :: Union{Nothing, Dict{P,SparsePerm}},
    to       :: Dict{P,Vector{Int}},
    to_ord   :: Union{Nothing, Dict{P,SparsePerm}},
) where {P}
    for (p, v_p) in sat.vars
        from_p, to_p = from[p], to[p]
        a = hinted_class(from_p, ranking(from_ord, p, length(from_p)))
        b = hinted_class(to_p, ranking(to_ord, p, length(to_p)))
        a == b && continue
        a == 0 || PicoSAT.set_default_phase_lit(sat.pico, v_p + a, 0)
        b == 0 || PicoSAT.set_default_phase_lit(sat.pico, v_p + b, 1)
    end
    return sat
end

# improve package p to its best admissible feasible class: repeatedly demand
# some strictly better class until that becomes unsatisfiable, keeping the last
# good model in sol. `reps` says which classes are admissible — a class the
# query emptied is forbidden by a unit clause, so probing one would be a solve
# spent learning what the instance already states
function optimize_version!(
    sat  :: SAT{P},
    sol  :: Dict{P,Int},
    p    :: P,
    ord  :: O = nothing,
    reps :: Dict{P,Vector{Int}} = sat.reps, # the classes the query admits
) where {P, O}
    ord_p = ranking(ord, p, nclasses(sat.info[p]))
    best = hinted_class(reps[p], ord_p)
    @assert best != 0 """
        $p admits no class, yet the model installs it: `reps` has to be the
        representatives whose deactivations are in force."""
    # cheap first try: after filtering, the best admissible class is feasible
    # more often than not, and probing it by assumption needs no temp clauses
    # at all — one solve replaces the whole improvement loop
    if sol[p] != best
        sat_assume(sat, p, best)
        if sat_solve(sat)
            extract_solution!(sat, sol)
            @assert sol[p] == best
        end
    end
    # a package already at its best class is optimal: the improvement clause
    # below would be empty, forcing a guaranteed-UNSAT solve
    while sol[p] != best
        improved = with_temp_clauses(sat) do
            # some class ranking strictly above the one it has — the ranks the
            # scan passes on its way to the one it has, which is where it stops.
            # an emptied class among them stays in: its literal is false at
            # level 0 and costs nothing, and `best` being admissible means the
            # clause is never made of such literals alone
            for r in eachindex(ord_p)
                c = @inbounds ord_p[r]
                c == sol[p] && break
                sat_add(sat, p, c)
            end
            sat_add(sat)
            sat_solve(sat) || return false
            extract_solution!(sat, sol)
            return true
        end
        improved || break
    end
end

# fix a given set of versions — as the classes that hold them, which is all
# the instance can express (and all that is needed: a version's class is
# interchangeable with it)

function fix_versions(
    sat  :: SAT{P,V},
    pkgs :: AbstractVector{P},
    vers :: AbstractVector{Union{Nothing,V}},
) where {P,V}
    for (p, v) in zip(pkgs, vers)
        v === nothing && continue
        info_p = sat.info[p]
        i = findfirst(==(v), info_p.versions)
        i === nothing && throw(ArgumentError("package $p: unknown version $v"))
        sat_add(sat, p, info_p.classes[i])
        sat_add(sat)
    end
end
