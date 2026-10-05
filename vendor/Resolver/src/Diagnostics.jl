"""
    Resolver.Diagnostics

Why an unsatisfiable query fails, and what its user could change.

A report owes three things: the **fixes** — how many independent things are
wrong and, for each, the menu that settles it, such that any combination of
choices, one per conflict, repairs the query while giving up as little as any
repair can; the **explanations** — for each conflict, which of the user's own
facts collide, at which package, and through which of the registry's
statements; and the **witnesses** — what taking each fix yields.

The facts a query is made of are per package: *requiring* it, and the query's
own limits on *which versions of it* are admissible. Package granularity is the
finest grain that stays a user action — no edit gives back one excluded version
while keeping its siblings excluded. A **reason** is a minimal unsatisfiable set
of facts, a **repair** a minimal set whose withdrawal is satisfiable, and the
two are hitting-set duals; the conflicts are the menus the cheapest repairs
decompose into, each explaining a reason of its own, and where a group of them
that stand or fall together has cheapest repairs their product does not reach,
those print after the conflicts as **alternatives** to the whole group.

See the manual's *Explaining an unsatisfiable resolve* for the theory this
implements, including the proof of every claim above.
"""
module Diagnostics

using ..Resolver: Resolver, SAT, Problem, PkgInfo, Universe, PicoSAT, Relation,
    nclasses, installed_lit, forbidden_lit, sat_assume_var, sat_solve,
    sat_new_variable, sat_add_var, sat_add, with_classes_relaxed,
    with_temp_clauses, exclusion_kinds, kind_base, kind_source, EmptyDict,
    relax, resolve, DepsProvider, PkgData, is_excluded
using ..Resolver.Clauses: Clauses, Clause, Lit, literal, clause, packages,
    isbottom, subsumes, absent, present, resolve_raw, resolve_on, clause_phrase,
    range_phrase, selected, unselected, nversions, version_order
using ..Resolver.UnsatCores: sat_mus

export Diagnosis, Conflict, Alternative, Fix, Action, Line, Upstream,
    action_phrase

## what a report is made of

"""
    Action(kind, pkg)

One thing a user could do: `:drop` a requirement on `pkg`, or lift the
constraint of kind `kind` for `pkg`. The kinds are the query's own
([`Problem`](@ref Resolver.Problem)), so an action is always something the
reader can carry out by editing what they wrote.
"""
struct Action{P}
    kind :: Symbol
    pkg  :: P
end

Base.:(==)(a::Action, b::Action) = a.kind === b.kind && a.pkg == b.pkg
Base.hash(a::Action, h::UInt) = hash(a.pkg, hash(a.kind, hash(:Action, h)))
Base.show(io::IO, a::Action) = print(io, "Action(", repr(a.kind), ", ",
                                     repr(a.pkg), ")")

"""
    Line(clause, through, given, proof = 0, pivot = nothing)

One printed statement. `clause` is the whole of what it says; `through` names
the packages an elimination reached it by — a courtesy pointer, carrying no
claim of its own, since the page shows what a line says and not the
elimination that reached it. `given` marks the query's own facts, which every proof on the page
shares; `proof` numbers the reason a derived line argues for, and `pivot` the
package its meet is taken at.
"""
struct Line{P}
    clause  :: Clause{P}
    through :: Vector{P}
    given   :: Bool
    proof   :: Int
    pivot   :: Union{Nothing,P}
end

Line{P}(c::Clause{P}, t::Vector{P}, g::Bool) where {P} =
    Line{P}(c, t, g, 0, nothing)
Line{P}(c::Clause{P}, t::Vector{P}, g::Bool, n::Integer) where {P} =
    Line{P}(c, t, g, Int(n), nothing)

"""
    Fix(actions, solution)

One entry of a menu: the actions to carry out, and what the resolver answers
once they are — with everything else on the page settled the first way it
offers, the other menus of this entry's own layer included. An entry may ask
for several actions at once, where the family couples them and no one of them
is a repair without the rest. The versions are the resolver's optimising answer
for the withdrawn query, never a model found during diagnosis: diagnosis
decides what is true, the resolver decides what is chosen.
"""
struct Fix{P,V}
    actions  :: Vector{Action{P}}
    solution :: Dict{P,V}
end

"""
    Upstream(pkg, latest, dep, supports, supported, solution)

A release someone else could cut that would settle a conflict: `pkg`'s latest
version, `latest`, with its compatibility bound on `dep` dropped and nothing
else changed — the same dependencies, the same bounds on every other package,
the same version number. `supports` is the version of `dep` that release would
let the user have, `supported` the versions of `dep` that `latest` does support
— what the page names as the range the request is about — and `solution` the
whole of what the resolver answers on that registry, `pkg` at `latest`.

Modelled in place rather than as a new version number: a new number would carry
every other package's bound on `pkg` along with it, and whether some third
package admits the next version where it admitted this one is a question about
version arithmetic no report has any business raising.

One request, and verified. A conflict names such a release only where the bound
it drops meets one of the user's *own* facts — never another registry package's,
which would blame two maintainers and judge between them — where the user's own
constraint admits `latest`, since otherwise a release that helps exists already
and *relax your compat on «pkg»* is on the menu, and where a resolve on the
modified registry succeeded, which is `solution`. Nothing prints where any of
that fails: the sentence is one the reader can send upstream as it stands.
"""
struct Upstream{P,V}
    pkg       :: P          # the package a release of would fix it
    latest    :: V          # its latest version, what that release is like
    dep       :: P          # the package the release would support
    supports  :: V          # the version of it the witness took
    supported :: Vector{V}  # the versions of it `latest` does support
    solution  :: Dict{P,V}  # the witness, `pkg` at `latest`
end

"""
    Conflict(reqs, lines, versions, excluded, fixes,
             blocks = [], upstream = [], shadows = Dict())

One independent thing that is wrong: the requirements it answers for, the lines
that prove it, the version list each named package is spoken of in, which of
the query's constraint kinds exclude which of those versions, the menu of fixes
that settles it, the verdict on each action the page makes tempting, and the
releases someone else could cut instead.

`versions` is the universe the user sees: what the query's universe still
holds, together with the versions redundancy elimination removed because a
newer version of the same package dominated them. `shadows` says which entries
those are — one `(index, dominator indices)` pair each, into `versions[p]` —
and every literal of every line already reads over them: a shadow is admitted
by a literal exactly where all of its dominators are, and excluded where any of
them is. That is the widening `ω` of the manual's *Shadows*, done once here so
that nothing downstream has to know about it; Theorem 35 is why each widened
line is true, and (D3) is why the query's own line allows every shadow.

A rendering that reads the survivors alone credits the user's compat with the
resolver's deletions, and one that widens only that line names a version as
available and never says what rules it out.

A conflict is one **menu**: choose one entry of `fixes` and this conflict is
settled. An entry may ask for several actions at once, where the family couples
them and no one of them is a repair without the rest. Where a block of the
query's cheapest repairs is not the product of its conflicts' menus, what the
product misses is not hidden inside a conflict: it is an
[`Alternative`](@ref) on the [`Diagnosis`](@ref), printed after the conflicts
and replacing the menus of the block it belongs to.

An action is **tempting** when this conflict's lines or heading name its
package and no fix anywhere on the page takes it: the reader can see it and
cannot see why it is not offered. Each entry of `blocks` answers for one or
more such actions at once: `tried` holds one action-bundle per tempting fact
(a lift of several kinds is one bundle), and `unless` the rest of a minimal
repair that carries them all, empty where the action is in no minimal repair
the search could reach. One tried bundle prints "does not help." or "would
not help unless you also …"; several print, joined by "or", "would only help
if you do both" — they exhibit one repair, each insufficient alone, and the
page says the repair once rather than mirroring it from every end. Every verdict is the
solver's: a bounded search for a minimal repair through the action, shrunk
in the action's favour so a tie between equal repairs cannot call the same
action idle in one sentence and a rescue in the next.

Everything above is what the *user* could change. `upstream` is what a
maintainer could: each entry an [`Upstream`](@ref) — a release of a package
this conflict speaks of, its bound on a package the query narrowed dropped —
that a resolve says would settle this conflict. Empty where no pair meets the
bar, and empty where the diagnosis was made without the package data such a
release has to be tried against.
"""
struct Conflict{P,V}
    reqs     :: Vector{P}
    lines    :: Vector{Line{P}}
    versions :: Dict{P,Vector{V}}
    excluded :: Dict{P,Vector{Vector{Symbol}}}
    fixes    :: Vector{Fix{P,V}}
    blocks   :: Vector{Tuple{Vector{Vector{Action{P}}},Vector{Action{P}}}}
    upstream :: Vector{Upstream{P,V}}
    # per package, which entries of `versions` redundancy elimination removed
    # and, for each, the entries that dominated it: the record a checker needs
    # to recompute the widening every line is printed over (V8).
    shadows  :: Dict{P,Vector{Tuple{Int,Vector{Int}}}}
end

Conflict{P,V}(reqs, lines, versions, excluded, fixes) where {P,V} =
    Conflict{P,V}(reqs, lines, versions, excluded, fixes,
                  Tuple{Vector{Vector{Action{P}}},Vector{Action{P}}}[])
Conflict{P,V}(reqs, lines, versions, excluded, fixes, blocks) where {P,V} =
    Conflict{P,V}(reqs, lines, versions, excluded, fixes, blocks,
                  Upstream{P,V}[])
Conflict{P,V}(reqs, lines, versions, excluded, fixes, blocks, upstream) where {P,V} =
    Conflict{P,V}(reqs, lines, versions, excluded, fixes, blocks, upstream,
                  Dict{P,Vector{Tuple{Int,Vector{Int}}}}())

"""
    selections(c) :: Vector{Vector{Action{P}}}

Every repair `c` offers: its menu's entries, one by one.
"""
selections(c::Conflict{P,V}) where {P,V} =
    Vector{Action{P}}[unique(f.actions) for f in c.fixes]

"""
    Alternative(conflicts, avoided, menus)

Another way of settling a whole block of conflicts at once — the cheapest
repairs of that block which taking one entry from each of its conflicts' menus
does not reach.

`conflicts` are the indices of the conflicts it replaces, which are exactly one
block of the query's independent factors; the rest of the report stands as
printed, settled the way its own menus offer. `menus` is a product: settle each
of them, one entry apiece, and every combination of those is a repair as cheap
as any there is. `avoided` are the replaced conflicts — as indices again —
whose menus every selection of this alternative misses entirely, which is what
the page says the alternative is instead of.

No proof prints under an alternative: reasons attach to the conflicts and do
not layer (Corollary 25 of the theory page), so what it owes the reader is its
menus and a witness under every entry.
"""
struct Alternative{P,V}
    conflicts :: Vector{Int}
    avoided   :: Vector{Int}
    menus     :: Vector{Vector{Fix{P,V}}}
end

"""
    selections(a) :: Vector{Vector{Action{P}}}

Every repair `a` offers: one entry from each of its menus, in every
combination.
"""
function selections(a::Alternative{P,V}) where {P,V}
    sels = Vector{Action{P}}[Action{P}[]]
    for m in a.menus
        sels = Vector{Action{P}}[[s; f.actions] for s in sels for f in m]
    end
    return Vector{Action{P}}[unique!(s) for s in sels]
end

"""
    Diagnosis

What [`resolve`](@ref Resolver.resolve) answers when the query cannot be
satisfied: the conflicts, every one of which every solution resolves, the
alternatives to whole blocks of them, and what all of that leaves out.

The conflicts fall into independent blocks, and a block's repairs are one entry
from each of its conflicts' menus in every combination, together with every
selection of each [`Alternative`](@ref) naming it. A repair of the query is one
of each block's, and between them they are every repair as cheap as the
cheapest — see [`selections`](@ref). So `others` is about what costs more:
`:none` when nothing outside them exists at all, `:larger` when what is outside
gives up more, and `:some` when the enumeration of the cheapest repairs was cut
short and one further solve found one it never reached. `truncated` records
that the search for reasons was cut short — a conflict may then argue from a
reason that is not the shortest it owns — which the report does not announce,
since nothing on the page is false or missing for the reader on that account.
`upstream_cut` records the same about the probes behind the conflicts' upstream
fixes: the budget stopped a candidate being tried, which is a sentence the page
did not print rather than a false one, and so is not announced either.

`sources` is where the query said each requirement is required from
([`Problem`](@ref Resolver.Problem)), for the ones it said: a heading and a
fix that drops a requirement print the places after its name.

`show`ing one prints the report.
"""
struct Diagnosis{P,V}
    conflicts    :: Vector{Conflict{P,V}}
    alternatives :: Vector{Alternative{P,V}}
    others       :: Symbol # :none, :larger, :some
    truncated    :: Bool
    upstream_cut :: Bool
    sources      :: Dict{P,Vector{String}}
end

# a diagnosis rebuilt by a caller — renamed, filtered, whatever — is not one
# whose search was cut short, so the disclosure defaults off
Diagnosis(conflicts::Vector{Conflict{P,V}},
          alternatives::Vector{Alternative{P,V}}, others::Symbol) where {P,V} =
    Diagnosis{P,V}(conflicts, alternatives, others, false)
Diagnosis{P,V}(conflicts, alternatives, others, truncated) where {P,V} =
    Diagnosis{P,V}(conflicts, alternatives, others, truncated, false)
Diagnosis{P,V}(conflicts, alternatives, others, truncated, upstream_cut) where {P,V} =
    Diagnosis{P,V}(conflicts, alternatives, others, truncated, upstream_cut,
                   Dict{P,Vector{String}}())
Diagnosis(conflicts::Vector{Conflict{P,V}}, others::Symbol) where {P,V} =
    Diagnosis(conflicts, Alternative{P,V}[], others)

# The conflicts of each block, as their indices. A block with alternatives is
# named by them; every conflict no alternative names is a block on its own,
# since a block whose repairs its conflicts' menus present as a product is
# exactly one whose factors are those conflicts (Theorem 30).
function conflict_blocks(d::Diagnosis)
    groups = Vector{Int}[]
    for a in d.alternatives
        a.conflicts in groups || push!(groups, a.conflicts)
    end
    named = Set{Int}(i for g in groups for i in g)
    for i in eachindex(d.conflicts)
        i in named || push!(groups, Int[i])
    end
    sort!(groups; by = first)
    return groups
end

# every repair one block offers: one entry from each of its conflicts' menus,
# in every combination, and every selection of every alternative to it
function block_selections(d::Diagnosis{P,V}, g::Vector{Int}) where {P,V}
    out = Vector{Action{P}}[Action{P}[]]
    for i in g
        out = Vector{Action{P}}[[s; f.actions]
                                for s in out for f in d.conflicts[i].fixes]
    end
    out = Vector{Action{P}}[unique!(s) for s in out]
    for a in d.alternatives
        a.conflicts == g && append!(out, selections(a))
    end
    return out
end

"""
    selections(d) :: Vector{Vector{Action{P}}}

Every repair of the query the report presents: one of each block's, in every
combination. A block's own are one entry from each of its conflicts' menus,
together with every selection of each alternative to it. Between them these are
exactly the repairs as cheap as the cheapest — nothing offered that is not one,
and none of them left unsaid.
"""
function selections(d::Diagnosis{P,V}) where {P,V}
    out = Vector{Action{P}}[Action{P}[]]
    for g in conflict_blocks(d)
        out = Vector{Action{P}}[unique!([s; b]) for s in out
                                for b in block_selections(d, g)]
    end
    return out
end

## the universe as the clause logic sees it

"""
    clause_versions(sat, p) :: Vector{V}

The versions of `p` a clause's literal indexes — the ones the universe this
query was run against still holds. A literal has one more slot than this, for
⊥.
"""
clause_versions(sat::SAT{P,V}, p) where {P,V} =
    haskey(sat.info, p) ? sat.info[p].versions : V[]

## the universe the page prints over
#
# Every line prints over the universe the *user* sees, and that is not the one
# the diagnosis ran over: before any solve, redundancy elimination removed each
# version of a package that a newer version of it dominated — the **shadows**
# of Section 9 of the theory page — and no line of a report can say why those
# are gone. Two things go wrong if they stay gone. A line reading the query
# over the survivors alone credits the user's compat with the resolver's
# deletions ("your compat restricts DataFrames to ≥1.7.1", when 1.7.0 exists
# and the compat admits it); and once a line does name 1.7.0, every statement
# arguing from DataFrames has to reach it, or the page rules out a version it
# has just called available and never says how.
#
# So a conflict is extended to `V′ = V ∪ Sh` before anything prints, and every
# literal in it becomes the widening
#
#     ω(C)(p) = C(p) ∪ { s ∈ Sh(p) : D(s) ⊆ C(p) }
#
# of the literal the diagnosis derived: a shadow is admitted exactly where all
# of the versions that dominated it are admitted, and excluded where any of
# them is. That is one operation, applied to every literal on whichever side of
# a sentence it lands, so the printer knows nothing about shadows at all — the
# availability line is the query's own fact widened the same way, and admits
# every shadow because (D3) says the query left every dominator. Theorem 35 is
# that the widened line is entailed by the registry and the query over `V′`,
# and its corollary that a meet which closed over `V` closes over `V′` too.

"""
    shadow_dominators(sat, prob, p) :: Vector{Tuple{V,Vector{Int}}}

The versions of `p` redundancy elimination removed, each with the versions that
dominated it, as indices into [`clause_versions`](@ref
Resolver.Diagnostics.clause_versions).

The universe records domination by *class*, and a class speaks here for every
member the query admits: members are indistinguishable to the registry, so each
of them dominates whatever the class does, and (D3) wants a dominator the query
left. A class the query emptied dominates nothing — `mark_necessary!` takes a
deactivated class off both sides of its test — so no shadow is left without a
dominator.

A shadow the query itself excludes is not one of these. The universe hands over
a deleted class whole, and a class can hold a version the query rules out
beside one it admits — a constraint is finer than a class, which is the one
place the two per-class bits are not enough on their own — so the versions the
query took away are dropped here. Keeping one would have the query's own line
saying the compat allows a version that compat excludes.
"""
function shadow_dominators(sat::SAT{P,V}, prob::Problem{P}, p::P) where {P,V}
    out = Tuple{V,Vector{Int}}[]
    haskey(sat.info, p) || return out
    info = sat.info[p]
    any(!isempty, info.shadows) || return out
    vs = info.versions
    at = Dict{V,Int}()
    admitted = Int[]
    for (c, sh) in enumerate(info.shadows)
        isempty(sh) && continue
        empty!(admitted)
        for j in info.members[c]
            isempty(exclusion_kinds(prob, p, vs[j])) && push!(admitted, j)
        end
        @assert !isempty(admitted) """
            a shadow of $p is hosted by a class this query emptied — and an \
            emptied class dominates nothing, which is (D3)"""
        for v in sh
            isempty(exclusion_kinds(prob, p, v)) || continue
            k = get(at, v, 0)
            if iszero(k)
                push!(out, (v, copy(admitted)))
                at[v] = length(out)
            else
                append!(out[k][2], admitted)
            end
        end
    end
    for (_, ds) in out
        unique!(sort!(ds))
    end
    return out
end

# Where the widened version list puts each version: the survivors keep the
# order they were in and each shadow takes the place the version order gives
# it. Where there is no order to take — versions with no `isless`, or a
# provider order that is not monotone — the shadows go at the end, which costs
# the page nothing, since a range over such a list is printed by naming its
# versions and a name claims nothing about order.
#
# Returns the list, the new index of each old version, and the new index of
# each shadow.
function merge_shadows(vs::Vector{V}, svs::Vector{V}) where {V}
    n = length(vs)
    isempty(svs) && return vs, collect(1:n), Int[]
    dir = version_order(vs)
    # one version is in order whichever way the list is read
    dir == 0 && n ≤ 1 && hasmethod(isless, Tuple{V,V}) && (dir = 1)
    items = Tuple{V,Int}[(v, k) for (k, v) in enumerate(vs)]
    for (t, v) in enumerate(svs)
        push!(items, (v, -t))
    end
    # the survivors are monotone where there is a direction at all, so sorting
    # the whole of it leaves their order alone
    dir == 0 || sort!(items; by = first, rev = dir == -1)
    pos = zeros(Int, n)
    spos = zeros(Int, length(svs))
    for (i, (_, k)) in enumerate(items)
        k > 0 ? (pos[k] = i) : (spos[-k] = i)
    end
    return V[v for (v, _) in items], pos, spos
end

# One literal, widened: the survivors where they have moved to, and each shadow
# where all of its dominators are — `ω` at one package. ⊥ is a value like any
# other and no shadow of it exists, so it carries over as it is.
function widen_lit(m::Lit, pos::Vector{Int}, sh::Vector{Tuple{Int,Vector{Int}}},
                   n::Int)
    bits = falses(n + 1)
    for (k, i) in enumerate(pos)
        bits[i] = m[k]
    end
    for (i, ds) in sh
        bits[i] = all(bits[d] for d in ds)
    end
    bits[n+1] = absent(m)
    return Lit(bits)
end

"""
    widened(sat, prob, pkgs, lines)

One conflict over the universe the user sees: the version list of each of
`pkgs` with the shadows in it, which of the query's kinds exclude which of
those versions, the shadows as `(index, indices of its dominators)` into that
list, and `lines` with every literal widened by `ω`.
"""
function widened(sat::SAT{P,V}, prob::Problem{P}, pkgs::Vector{P},
                 lines::Vector{Line{P}}) where {P,V}
    versions = Dict{P,Vector{V}}()
    excluded = Dict{P,Vector{Vector{Symbol}}}()
    shadows = Dict{P,Vector{Tuple{Int,Vector{Int}}}}()
    maps = Dict{P,Vector{Int}}() # the new index of each old version
    for p in pkgs
        sh = shadow_dominators(sat, prob, p)
        vs, pos, spos = merge_shadows(clause_versions(sat, p), V[v for (v, _) in sh])
        versions[p] = vs
        if !isempty(sh)
            maps[p] = pos
            shadows[p] = Tuple{Int,Vector{Int}}[
                (spos[t], Int[pos[d] for d in ds]) for (t, (_, ds)) in enumerate(sh)]
        end
        ks = Vector{Symbol}[exclusion_kinds(prob, p, v) for v in vs]
        # (D3): the query admits every shadow, so the line saying what the
        # query left is one the widening may speak in
        @assert all(isempty(ks[i]) for (i, _) in get(shadows, p, ())) """
            a shadow of $p is a version this query excludes — and the query's \
            constraints are in force where redundancy is judged, which is (D3)"""
        any(!isempty, ks) && (excluded[p] = ks)
    end
    isempty(maps) && return versions, excluded, shadows, lines
    wide = Line{P}[]
    for l in lines
        pairs = Pair{P,Lit}[]
        for (p, m) in l.clause.lits
            pos = get(maps, p, nothing)
            push!(pairs, p => (pos === nothing ? m :
                  widen_lit(m, pos, shadows[p], length(versions[p]))))
        end
        cl = clause(pairs)
        # a literal that admitted everything would have made the clause a
        # tautology before it was widened: `ω` adds to a literal, never to the
        # versions it leaves out
        @assert cl !== nothing "widening left a line saying nothing"
        push!(wide, Line{P}(cl, l.through, l.given, l.proof, l.pivot))
    end
    return versions, excluded, shadows, wide
end

"""
    clause_of(sat, r::Relation) :: Union{Clause{P}, Nothing}

One registry statement as the clause it is: the versions of `r.pkg` it speaks
for, complemented and admitting ⊥ — the statement binds only where that package
is at one of them — together with what it asks of `r.other`, which is presence
(a dependency) or everything but a run of versions (a compatibility bound).
"""
function clause_of(sat::SAT{P,V}, r::Relation{P}) where {P,V}
    ip, iq = sat.info[r.pkg], sat.info[r.other]
    np, nq = length(ip.versions), length(iq.versions)
    a = falses(np + 1)
    for c in r.classes, j in ip.members[c]
        a[j] = true
    end
    for j = 1:np
        a[j] = !a[j]
    end
    a[np+1] = true
    b = falses(nq + 1)
    if r.dep
        b[1:nq] .= true
    else
        for c in r.others, j in iq.members[c]
            b[j] = true
        end
        for j = 1:nq
            b[j] = !b[j]
        end
        b[nq+1] = true
    end
    return clause([r.pkg => Lit(a), r.other => Lit(b)])
end

"""
    clauses_satisfiable(sat, clauses) :: Bool

Can these clauses hold together, over the versions the universe leaves each
package they name? Asked of the clauses alone — no registry, no query — because
whether a set of statements contradicts is a question about the statements.
"""
function clauses_satisfiable(sat::SAT{P,V}, cs) where {P,V}
    ps = P[]
    for c in cs, p in packages(c)
        p in ps || push!(ps, p)
    end
    isempty(ps) && return !any(isbottom, cs)
    pico = PicoSAT.init()
    try
        var = Dict{P,Int}()
        n = 0
        for p in ps
            var[p] = n
            n += length(clause_versions(sat, p)) + 1
        end
        PicoSAT.adjust(pico, max(n, 1))
        function add(lits)
            for l in lits
                PicoSAT.add(pico, l)
            end
            PicoSAT.add(pico, 0)
        end
        for p in ps
            k = length(clause_versions(sat, p)) + 1
            add(Int[var[p] + i for i = 1:k])
            for i = 1:k, j = i+1:k
                add(Int[-(var[p] + i), -(var[p] + j)])
            end
        end
        for c in cs
            add(Int[var[p] + i for (p, m) in c.lits for i in eachindex(m) if m[i]])
        end
        return PicoSAT.sat(pico) != PicoSAT.UNSATISFIABLE
    finally
        PicoSAT.reset(pico)
    end
end

# Does `base` entail `c`? Deny the clause — every package it names confined to
# what its literal does not allow — and ask whether the rest can still hold.
function entails(sat::SAT{P,V}, base::Vector{Clause{P}}, c::Clause{P}) where {P,V}
    deny = Clause{P}[]
    for (p, m) in c.lits
        d = clause([p => Lit(.~m.bits)])
        d === nothing && return true
        push!(deny, d)
    end
    return !clauses_satisfiable(sat, Clause{P}[base; deny])
end

# The smallest vocabulary outside a line that still proves it, in the order the
# route reaches it. The packages an elimination passed through are not all
# packages the line needs, and the list is what the report offers in place of
# the argument, so it should be the argument's own vocabulary and no more. And
# order matters as much as membership: named alphabetically the list is a set,
# and a set is not what the reader wants — they want the way from what the
# line argues from to what it concludes, so the route is walked out from the
# line's own packages over the statements the proof may use, nearest first.
function trim_route(sat::SAT{P,V}, base::Vector{Clause{P}}, c::Clause{P},
                    through::Vector{P}) where {P,V}
    named = Set{P}(packages(c))
    ok(v) = entails(sat, Clause{P}[b for b in base
        if all(q -> q in named || q in v, packages(b))], c)
    v = Set{P}(q for q in through if q ∉ named)
    isempty(v) && return P[]
    if ok(v)
        for q in sort!(collect(v))
            w = setdiff(v, [q])
            ok(w) && (v = w)
        end
    end
    isempty(v) && return P[]
    usable = Clause{P}[b for b in base
                       if all(q -> q in named || q in v, packages(b))]
    seen = copy(named); out = P[]
    front = sort!(collect(named))
    while !isempty(front)
        step = P[]
        for b in usable
            ps = packages(b)
            any(q -> q in front, ps) || continue
            for q in ps
                q in v && q ∉ seen && q ∉ step && push!(step, q)
            end
        end
        sort!(step)
        append!(out, step); union!(seen, step)
        front = step
    end
    for q in sort!(collect(v))
        q in seen || push!(out, q)
    end
    return out
end

## elimination

# a clause on its way through a projection: what it says, the packages whose
# elimination derived it, and which of the reason's facts its derivation used.
# The mask over-attributes — a derivation that happened to use a fact is a
# witness that the fact may be needed, not a proof of it — which is sound for
# everything printed, since a side stated from a larger support is still true.
struct Item{P}
    clause :: Clause{P}
    route  :: Vector{P}
    mask   :: UInt64
end

# how much subset enumeration one elimination may do before the projection is
# abandoned — on overflow the caller falls back to printing the core, a true
# but unshaped account being better than a shaped partial one
const ELIM_NODES = 30_000
const ELIM_CLAUSES = 2_000
const ELIM_ARITY = 40
const ELIM_SET = 5

# Every minimal subset of `bits` whose intersection is empty, up to
# `ELIM_SET` members. Minimal subsets and not merely emptying ones: the
# resolvent of a larger emptying set is subsumed by that of a minimal one
# inside it, so restricting to these loses nothing — and pairs do not suffice,
# since three set-valued literals can have empty intersection while every two
# overlap.
#
# Three prunes keep this from walking the powerset, two of them lossless. A
# clause that does not shrink the running intersection is redundant in every
# minimal set the branch could reach, so it is skipped where it stands. A
# branch whose intersection survives even the conjunction of everything still
# ahead of it can never empty, so it is cut — this is what kills the long
# chains of statements that all admit ⊥. The size cap alone loses something:
# a minimal emptying set wider than `ELIM_SET` is not found, and the
# projection may then fail to close at this pivot — sound (nothing false is
# ever derived, only less), and the search moves to the next pivot or falls
# back to the core. Convex bounds cannot need more than three (the manual's
# proposition on the shape of convex meets), so the cap is generous.
function minimal_emptying(bits::Vector{BitVector}, budget::Ref{Int})
    n = length(bits)
    sols = Vector{Vector{Int}}()
    chosen = Int[]
    suffix = [trues(length(bits[1])) for _ = 1:n+1]
    for i = n:-1:1
        suffix[i] = suffix[i+1] .& bits[i]
    end
    function is_minimal()
        for j in eachindex(chosen)
            cur = trues(length(bits[1]))
            for k in eachindex(chosen)
                k == j || (cur .&= bits[chosen[k]])
            end
            any(cur) || return false
        end
        return true
    end
    function rec(start::Int, cur::BitVector)
        any(cur .& suffix[start]) && return true
        length(chosen) ≥ ELIM_SET && return true
        for i = start:n
            budget[] -= 1
            budget[] ≤ 0 && return false
            nxt = cur .& bits[i]
            nxt == cur && continue
            push!(chosen, i)
            if !any(nxt)
                is_minimal() && push!(sols, copy(chosen))
            elseif i < n
                rec(i + 1, nxt) || (pop!(chosen); return false)
            end
            pop!(chosen)
        end
        return true
    end
    isempty(bits) && return sols
    return rec(1, trues(length(bits[1]))) ? sols : nothing
end

# drop what another item already says: an item saying at least as much on no
# more of the reason's facts makes the other one redundant on every page
function reduce_items(items::Vector{Item{P}}) where {P}
    keep = trues(length(items))
    for i in eachindex(items)
        keep[i] || continue
        for j in eachindex(items)
            (i == j || !keep[j]) && continue
            subsumes(items[i].clause, items[j].clause) || continue
            iszero(items[i].mask & ~items[j].mask) || continue
            if items[i].clause == items[j].clause && items[i].mask == items[j].mask
                (length(items[i].route), i) ≤ (length(items[j].route), j) || continue
            end
            keep[j] = false
        end
    end
    return Item{P}[items[i] for i in eachindex(items) if keep[i]]
end

# Two statements that agree everywhere but one package are one statement about
# the union: `A 1.0.0 requires C S` beside `A 1.1.0–1.3.0 requires C S` is
# `A 1.0.0–1.3.0 requires C S`, by resolution on `A` like anything else.
# Carried separately into an elimination each becomes a case of its own, the
# subset enumeration pays for every combination, and the reader is handed a
# dozen lines with the same right-hand side; merged first, the split is over
# what actually differs. A merged support is the union of the parents' — wider
# than either may have needed, which the mask is allowed to be.
function factor_items(items::Vector{Item{P}}, keep = ()) where {P}
    items = copy(items)
    while true
        done = true
        for i in eachindex(items), j in eachindex(items)
            i < j || continue
            c, e = items[i].clause, items[j].clause
            length(c.lits) == length(e.lits) || continue
            diff = P[q for (q, m) in c.lits
                     if (n = e[q]; n === nothing || n != m)]
            length(diff) == 1 || continue
            # merge only across a package on its way out: resolving two of a
            # meet's own sides on the kept package would fold the meet itself
            # into the empty clause, which is a derivation, not a merge
            q = only(diff)
            q in keep && continue
            r = resolve_on(c, e, q)
            (r === nothing || isbottom(r)) && continue
            route = copy(items[i].route)
            for q in items[j].route
                q in route || push!(route, q)
            end
            items[i] = Item{P}(r, sort!(route), items[i].mask | items[j].mask)
            deleteat!(items, j)
            done = false; break
        end
        done && return reduce_items(items)
    end
end

# Eliminate `q`: keep the clauses that do not mention it, and resolve every
# minimal set of the ones that do that leaves it nothing to be. That is the
# coverage condition stated as the rule itself — a version of `q` no resolvent
# accounts for is a gap in the argument, and this cannot leave one.
function eliminate_one(items::Vector{Item{P}}, q::P, budget::Ref{Int}) where {P}
    hit = Item{P}[]
    out = Item{P}[]
    for it in items
        push!(it.clause[q] === nothing ? out : hit, it)
    end
    isempty(hit) && return out
    length(hit) > ELIM_ARITY && return nothing
    sets = minimal_emptying(BitVector[hit[i].clause[q].bits for i in eachindex(hit)],
                            budget)
    sets === nothing && return nothing
    for S in sets
        r = resolve_raw(Clause{P}[hit[i].clause for i in S], q)
        r === nothing && continue
        route = P[q]
        mask = UInt64(0)
        for i in S
            append!(route, hit[i].route)
            mask |= hit[i].mask
        end
        push!(out, Item{P}(r, sort!(unique!(route)), mask))
    end
    return reduce_items(out)
end

# eliminate everything outside `keep`, cheapest package first — any order
# preserves satisfiability, and taking the least-mentioned one keeps the
# intermediate sets small
function eliminate_to(items::Vector{Item{P}}, keep) where {P}
    work = factor_items(items, keep)
    while true
        counts = Dict{P,Int}()
        for it in work, p in packages(it.clause)
            p in keep && continue
            counts[p] = get(counts, p, 0) + 1
        end
        isempty(counts) && return work
        q = first(sort!(collect(counts); by = x -> (last(x), first(x))))[1]
        work = eliminate_one(work, q, Ref(ELIM_NODES))
        work === nothing && return nothing
        work = factor_items(work, keep)
        length(work) > ELIM_CLAUSES && return nothing
    end
end

"""
    project(lines, keep) :: Union{Vector{Line{P}}, Nothing}

The statements `lines` make about the packages in `keep` alone: every package
outside `keep` eliminated, one at a time, by resolving every minimal set of
clauses that leaves it nothing to be. Satisfiability is preserved, so what comes
out contradicts exactly when what went in did.

`nothing` when the elimination would cost more work than it is worth; the
caller then has the clauses it started with, which are true whether or not they
have been shaped.
"""
function project(lines::Vector{Line{P}}, keep) where {P}
    out = eliminate_to(
        Item{P}[Item{P}(l.clause, copy(l.through), UInt64(0)) for l in lines], keep)
    out === nothing && return nothing
    return Line{P}[Line{P}(it.clause, it.route, false) for it in out]
end

## finding the conflicts
#
# The facts a query is made of, the cheapest repairs, the menus those factor
# into, and one explanation per reason each menu owns.
#
# Every question here is a solve under a subset of the *assumptions* standing
# for the query's facts, on an instance whose own deactivations have been
# lifted for the duration — so the registry is what the solver holds and the
# query is what it is asked about. Blame is settled on that instance first,
# with the registry inviolable; only then is the registry's share asked for, on
# a second instance where its statements are individually switchable. Asking
# the other way round lets a minimal answer drop a registry statement and blame
# a requirement in its place, which is minimal and a lie about what the user
# can do.

# a pivot with more classes than this has its sides taken as the elimination
# derived them; below it, each class is put to the instance, so that a side
# states everything the registry entails from its support rather than only what
# this reason's core happened to need
const TIGHTEN_CLASSES = 24

# how many of each enumeration is worth having. The reason walk is exponential
# and the repair enumeration can be too; both truncate, and truncation is
# disclosed rather than hidden (a conflict simply explains fewer of the reasons
# it owns).
const REPAIR_CAP = 64
const REASON_CAP = 24    # reasons the walk records before it stops
const REASON_NODES = 400 # calls the walk makes before it stops
# how far above the cheapest repair the search for a repair through a tempting
# action goes before it gives up. A verdict is worth one bounded search, not an
# unbounded one, and an action whose cheapest repair is that much costlier than
# the page's own is one the page says nothing about rather than something wrong
const BLOCKED_SLACK = 3
# a reason wider than this has more facts than a bitmask carries; its
# explanation falls back to printing the core
const MASK_WIDTH = 62

"""
    VarMap(sat)

Which packages a diagnosis can ask about, and how. `haskey(vm, p)` is whether
the universe holds `p` at all — a requirement it does not is one nothing can
give back. `pkgs` are the packages this query has emptied classes of, in a
fixed order, with the literals that forbid them: those are the only packages a
constraint can be blamed for, since a constraint that spares a member of every
class it touches has changed nothing the registry can tell.
"""
struct VarMap{P}
    known :: Set{P}
    pkgs  :: Vector{P}
    lits  :: Dict{P,Vector{Int}}
end

function VarMap(sat::SAT{P,V}) where {P,V}
    pkgs = P[]
    lits = Dict{P,Vector{Int}}()
    for p in sort!(collect(keys(sat.reps)))
        reps = sat.reps[p]
        ls = Int[forbidden_lit(sat, p, c) for c in eachindex(reps)
                 if iszero(reps[c])]
        isempty(ls) && continue
        push!(pkgs, p)
        lits[p] = ls
    end
    return VarMap{P}(Set{P}(keys(sat.info)), pkgs, lits)
end

Base.haskey(vm::VarMap{P}, p) where {P} = p in vm.known

"""
    with_emptied_packages(body, sat, vm) -> body(pkg_lits, pkg_of)

Run `body` with one fresh literal per package this query emptied classes of,
each of which says "this query's limits on that package are in force". The
definitions live in a frame of their own and are retracted afterwards, so the
instance is as reusable as it was found.

Must be run inside `with_classes_relaxed`:
the point of the literal is to impose by assumption what the query's own frame
imposes unconditionally, and it can only do that once that frame is off.
"""
function with_emptied_packages(body::Function, sat::SAT{P,V},
                               vm::VarMap{P}) where {P,V}
    isempty(vm.pkgs) && return body(Int[], Dict{Int,P}())
    return with_temp_clauses(sat) do
        pkg_lits = Int[]
        pkg_of = Dict{Int,P}()
        for p in vm.pkgs
            v = sat_new_variable(sat)
            for l in vm.lits[p]
                sat_add_var(sat, -v)
                sat_add_var(sat, l)
                sat_add(sat)
            end
            push!(pkg_lits, v)
            pkg_of[v] = p
        end
        body(pkg_lits, pkg_of)
    end
end

# One of the query's facts: requiring a package, or the query's own limits on
# which of its versions are admissible. `lit` assumes it on the blame instance,
# `litx` on the one that can switch registry statements off.
#
# The canonical order is constraints before requirements, each by package: a
# menu prints in it, so a fix that gives something back is offered before one
# that gives a requirement up.
struct Fact{P}
    req  :: Bool
    pkg  :: P
    lit  :: Int
    litx :: Int
end

# solve with exactly `lits` assumed
function assuming(sat::SAT, lits)
    for l in lits
        sat_assume_var(sat, l)
    end
    return sat_solve(sat)
end

# What the registry entails about `pivot` from `support` alone — the strongest
# bound, not merely the one this reason's core happened to give. A core is
# minimal for the whole reason, so a statement the contradiction can do without
# is left out of it, and a side derived from what is left can be weaker than
# the truth: it may permit the package's absence where the registry demands it,
# which is the difference between *constrains* and *requires*. Asking closes
# that gap, and asking costs one solve per value.
function tighten!(sat::SAT{P,V}, bits::BitVector, pivot::P,
                  support::Vector{Int}) where {P,V}
    if bits[end] && !assuming(sat, Int[support; -installed_lit(sat, pivot)])
        bits[end] = false
    end
    info = sat.info[pivot]
    nclasses(info) ≤ TIGHTEN_CLASSES || return bits
    for c = 1:nclasses(info)
        mem = info.members[c]
        any(j -> bits[j], mem) || continue
        assuming(sat, Int[support; -forbidden_lit(sat, pivot, c)]) && continue
        for j in mem
            bits[j] = false
        end
    end
    return bits
end

## the bounded oracle

# "at most `k` of these facts are violated", as clauses over the fact literals
# (Sinz's sequential counter). A model of the instance under this constraint
# violates a correction set of at most `k` facts, and the least `k` at which one
# exists is the size of the cheapest repairs.
function add_at_most!(sat::SAT, lits::Vector{Int}, k::Int)
    n = length(lits)
    (n == 0 || k ≥ n) && return
    unit(a) = (sat_add_var(sat, a); sat_add(sat))
    two(a, b) = (sat_add_var(sat, a); sat_add_var(sat, b); sat_add(sat))
    three(a, b, c) =
        (sat_add_var(sat, a); sat_add_var(sat, b); sat_add_var(sat, c); sat_add(sat))
    if k == 0
        for l in lits
            unit(l)
        end
        return
    end
    s = [Int[sat_new_variable(sat) for _ = 1:k] for _ = 1:n-1]
    two(lits[1], s[1][1])
    for j = 2:k
        unit(-s[1][j])
    end
    for i = 2:n-1
        two(lits[i], s[i][1])
        two(-s[i-1][1], s[i][1])
        for j = 2:k
            three(lits[i], -s[i-1][j-1], s[i][j])
            two(-s[i-1][j], s[i][j])
        end
        two(lits[i], -s[i-1][k])
    end
    two(lits[n], -s[n-1][k])
    return
end

# The cheapest repairs, how much they cost, and whether the cap hid any.
# Raising the bound one at a time stops at the first `k` a model exists at,
# which is the least size a correction set has; at that `k` every model's
# violated set *is* a repair, and blocking each one found enumerates them all.
#
# Where the cap stops the enumeration, one more solve settles what stopping
# cost: with every member found blocked, a model at the same bound is a repair
# the enumeration never reached, and no model means it reached them all. That
# answer is the only thing that entitles a report to say its account of the
# cheapest repairs is short — never the length of the vector, which says
# nothing about what a longer search would have found.
function min_repairs(sat::SAT, lits::Vector{Int})
    n = length(lits)
    for k = 0:n
        found, more = with_temp_clauses(sat) do
            add_at_most!(sat, lits, k)
            out = Vector{Vector{Int}}()
            more = false
            while sat_solve(sat)
                viol = Int[i for i = 1:n if PicoSAT.deref(sat.pico, lits[i]) < 0]
                push!(out, viol)
                for i in viol
                    sat_add_var(sat, lits[i])
                end
                sat_add(sat)
                if length(out) ≥ REPAIR_CAP
                    more = sat_solve(sat)
                    break
                end
            end
            return out, more
        end
        isempty(found) || return k, found, more
    end
    return n, Vector{Int}[], false
end

# The cheapest repair that carries fact `x`, as fact indices, and empty where
# the search gave up. The counter of `min_repairs` again, with `x` forced
# violated: the least bound at which a model then exists is the size of the
# cheapest correction set containing `x`, and that model's violated set is one.
#
# Started at `k`, the cheapest repair size of the query, since nothing is
# cheaper, and stopped `BLOCKED_SLACK` above it. Where it stops there is no
# answer to report, and the page says nothing about that action rather than
# guessing at one.
function repair_through(sat::SAT, lits::Vector{Int}, x::Int, k::Int,
                        blocked::Vector{Vector{Int}} = Vector{Int}[])
    n = length(lits)
    for bound = k:min(k + BLOCKED_SLACK, n)
        found = with_temp_clauses(sat) do
            sat_add_var(sat, -lits[x])
            sat_add(sat)
            for B in blocked
                for j in B
                    sat_add_var(sat, lits[j])
                end
                sat_add(sat)
            end
            add_at_most!(sat, lits, bound)
            sat_solve(sat) || return Int[]
            return Int[i for i = 1:n if PicoSAT.deref(sat.pico, lits[i]) < 0]
        end
        isempty(found) || return found
    end
    return Int[]
end

# The verdict on a tempting action, made well defined. A found repair through
# `x` proves nothing about `x` until it is minimal as a set, and which minimal
# set a solver's model happens to land on is a tie-break — so the question
# asked is whether `x` lies in SOME minimal repair within the bound, favouring
# `x` in the shrinking and retrying past sets that collapse without it. Load
# bearing: the minimal set it survives in, as the exhibit. Idle: no minimal
# repair within reach carries it, and the flat verdict claims no more.
function blocked_verdict(sat::SAT, lits::Vector{Int}, x::Int, k::Int)
    correcting(S) = assuming(sat, Int[lits[j] for j in eachindex(lits)
                                     if j ∉ S])
    blocked = Vector{Int}[]
    for _ = 1:3
        W = repair_through(sat, lits, x, k, blocked)
        isempty(W) && return isempty(blocked) ? nothing : Int[]
        keep = Set{Int}(W)
        for e in sort!([j for j in W if j != x])
            length(keep) > 1 || break
            trial = setdiff(keep, [e])
            correcting(trial) && (keep = trial)
        end
        correcting(setdiff(keep, [x])) || return sort!(collect(delete!(keep, x)))
        push!(blocked, sort!(collect(keep)))
    end
    return Int[]
end

# Is there a repair holding none of the cheapest ones? One question, and its
# answer is the whole of what a report may say about what it leaves out.
function larger_repairs(sat::SAT, lits::Vector{Int}, fmin::Vector{Vector{Int}})
    return with_temp_clauses(sat) do
        for m in fmin
            for i in m
                sat_add_var(sat, lits[i])
            end
            sat_add(sat)
        end
        return sat_solve(sat)
    end
end

## menus

# The factors the cheapest repairs decompose into, or `nothing` where they do
# not decompose. Two facts lie in one factor exactly when they never share a
# repair, so the candidate partition is the components of that relation and
# needs no search; a family that counts right — one fact of each factor in every
# member, and as many members as the product has tuples — *is* the product.
function product_menus(fmin::Vector{Vector{Int}}, used::Vector{Int})
    n = length(used)
    at = Dict{Int,Int}(f => i for (i, f) in enumerate(used))
    shares = falses(n, n)
    for m in fmin, a in m, b in m
        a == b || (shares[at[a], at[b]] = true)
    end
    parent = collect(1:n)
    function root(x::Int)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    for i = 1:n, j = i+1:n
        shares[i, j] && continue
        ri, rj = root(i), root(j)
        ri == rj || (parent[ri] = rj)
    end
    groups = Dict{Int,Vector{Int}}()
    for i = 1:n
        push!(get!(Vector{Int}, groups, root(i)), used[i])
    end
    factors = Vector{Int}[sort!(g) for g in values(groups)]
    k = length(factors)
    for m in fmin
        length(m) == k || return nothing
        all(f -> count(x -> x in f, m) == 1, factors) || return nothing
    end
    length(fmin) == prod(length, factors; init = 1) || return nothing
    sort!(factors; by = first)
    return factors
end

## decomposition tree

# The substitution (modular) decomposition of the cheapest-repair family: the
# canonical tree of the monotone repair function, one node per fix-instruction.
# A `:menu` chooses one of `facts`; an `:and` fixes all its `children`; an `:or`
# fixes one of them; a `:threshold` fixes `k` of `facts`; a `:prime` is the
# incompressible remainder, carrying `fmin` over `facts` for the product cover
# below to present. One immutable struct with a kind tag; the
# five constructors below name the shapes and leave the irrelevant fields empty.
struct DecompNode
    kind     :: Symbol                 # :menu | :and | :or | :threshold | :prime
    facts    :: Vector{Int}            # :menu, :threshold, :prime — the ground U
    children :: Vector{DecompNode}     # :and, :or
    k        :: Int                    # :threshold — the K in "any K of"
    fmin     :: Vector{Vector{Int}}    # :prime — the local family
end

MenuNode(facts::Vector{Int}) =
    DecompNode(:menu, facts, DecompNode[], 0, Vector{Int}[])
AndNode(children::Vector{DecompNode}) =
    DecompNode(:and, Int[], children, 0, Vector{Int}[])
OrNode(children::Vector{DecompNode}) =
    DecompNode(:or, Int[], children, 0, Vector{Int}[])
ThresholdNode(k::Int, facts::Vector{Int}) =
    DecompNode(:threshold, facts, DecompNode[], k, Vector{Int}[])
PrimeNode(fmin::Vector{Vector{Int}}, facts::Vector{Int}) =
    DecompNode(:prime, facts, DecompNode[], 0, fmin)

# The projection of the family onto a block: each member's trace on `B`, deduped.
proj(F::Vector{Vector{Int}}, B::Vector{Int}) =
    unique!(sort!(Vector{Int}[sort!(intersect(m, B)) for m in F]))

# The members that lie wholly within `B`.
within(F::Vector{Vector{Int}}, B::Vector{Int}) =
    Vector{Int}[m for m in F if issubset(m, B)]

# The co-occurrence components of `U`: two facts are joined when some member
# holds both, so a component is a maximal set of facts that reach each other
# through shared members. More than one means the family splits as an OR.
function cooccur_components(F::Vector{Vector{Int}}, U::Vector{Int})
    n = length(U)
    at = Dict{Int,Int}(u => i for (i, u) in enumerate(U))
    parent = collect(1:n)
    function root(x::Int)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    for m in F, a in m, b in m
        a == b && continue
        ra, rb = root(at[a]), root(at[b])
        ra == rb || (parent[ra] = rb)
    end
    comps = Dict{Int,Vector{Int}}()
    for i = 1:n
        push!(get!(Vector{Int}, comps, root(i)), U[i])
    end
    sort!(Vector{Int}[sort!(c) for c in values(comps)])
end

# The finest factoring partition of `U`: the coarsest-to-finest fixpoint of
# merging any two blocks whose joint projection is not the product of their
# separate projections. Returns the blocks when the family genuinely factors as
# their product (more than one block, every combination realised, the counts
# agree), and `nothing` otherwise.
function factoring_partition(F::Vector{Vector{Int}}, U::Vector{Int})
    blocks = Vector{Int}[[u] for u in U]
    changed = true
    while changed
        changed = false
        for i = 1:length(blocks), j = i+1:length(blocks)
            B1, B2 = blocks[i], blocks[j]
            BU = sort!(vcat(B1, B2))
            p1, p2, pu = proj(F, B1), proj(F, B2), proj(F, BU)
            combos = Set(sort!(vcat(a, b)) for a in p1 for b in p2)
            indep = length(pu) == length(p1) * length(p2) && Set(pu) == combos
            if !indep
                blocks[i] = BU
                deleteat!(blocks, j)
                changed = true
                break
            end
        end
    end
    total = prod(B -> length(proj(F, B)), blocks; init = 1)
    gen = Set{Vector{Int}}()
    function build(bi::Int, acc::Vector{Int})
        if bi > length(blocks)
            push!(gen, sort!(copy(acc)))
            return
        end
        for tr in proj(F, blocks[bi])
            build(bi + 1, vcat(acc, tr))
        end
    end
    build(1, Int[])
    (length(blocks) > 1 && gen == Set(F) && length(F) == total) ?
        sort!(blocks; by = first) : nothing
end

# The decomposition tree of family `fmin` (all members size `k`) over facts
# `used`. Recursion: a lone fact is a menu; a disconnected co-occurrence graph
# is an OR of its components; a family that factors is an AND of its blocks; an
# indecomposable block that is every `k`-subset is a threshold; anything else is
# a prime. Canonical — the same family always yields the same tree.
function decompose(fmin::Vector{Vector{Int}}, used::Vector{Int})
    U = sort(used)
    k = isempty(fmin) ? 0 : length(first(fmin))
    length(U) ≤ 1 && return MenuNode(U)
    comps = cooccur_components(fmin, U)
    length(comps) > 1 &&
        return OrNode(DecompNode[decompose(within(fmin, c), c) for c in comps])
    part = factoring_partition(fmin, U)
    part === nothing ||
        return AndNode(DecompNode[decompose(proj(fmin, B), B) for B in part])
    (k > 0 && length(fmin) == binomial(length(U), k)) &&
        return ThresholdNode(k, U)
    return PrimeNode(fmin, U)
end

# The tree as the flat menu list `analyse` consumes today, or `nothing` where a
# node is not a plain product of choose-one menus. A `:menu` is one menu; an
# `:or` of singleton leaves is itself one choose-one menu; an `:and` is the
# concatenation of its children's menus. Threshold, prime, and any OR of
# non-singletons have no menu-product form and return `nothing`.
function flatten_menus(t::DecompNode)
    t.kind === :menu && return Vector{Int}[copy(t.facts)]
    if t.kind === :or
        all(c -> c.kind === :menu && length(c.facts) == 1, t.children) ||
            return nothing
        return Vector{Int}[sort!(Int[c.facts[1] for c in t.children])]
    end
    if t.kind === :and
        menus = Vector{Int}[]
        for c in t.children
            sub = flatten_menus(c)
            sub === nothing && return nothing
            append!(menus, sub)
        end
        return sort!(menus; by = first)
    end
    return nothing
end

# A readable one-line shape of a tree, for tests: mirrors the prototype's
# `shape`, e.g. `AND(OR(menu[1], menu[2]), T2of[3, 4, 5])`.
function tree_shape(t::DecompNode)
    t.kind === :menu && return "menu$(t.facts)"
    t.kind === :and && return "AND(" * join(map(tree_shape, t.children), ", ") * ")"
    t.kind === :or && return "OR(" * join(map(tree_shape, t.children), ", ") * ")"
    t.kind === :threshold && return "T$(t.k)of$(t.facts)"
    return "PRIME$(t.facts)"
end

## the product cover

# A **generalized rectangle** inside a family of cheapest repairs: disjoint
# groups of facts, each group holding a menu of options — fact sets of one
# size, compound where the family couples the facts it groups — such that every
# selection (one option per menu, unioned) is a member of the family. It is
# *exact* by construction: everything it offers is a cheapest repair, and never
# a combination the family does not hold. One menu whose options are whole
# members is the degenerate rectangle, always available, and is the flat list
# of those members.
#
# Facts are bits in the search below — a member, an option and a selection are
# all masks over the block's own facts — so a selection is an `|` and
# membership a lookup.

# a menu: the options it offers, each a set of facts
const Menu = Vector{Vector{Int}}
# a layer: the menus whose product it is, a generalized rectangle
const Layer = Vector{Menu}

# The members a layer's selections reach, and what it costs to read, priced
# the way it prints: the menus of one entry are said together as one line, a
# phrase per action; a menu with a choice is a line and then a line per entry,
# each a phrase per action — so a compound entry is paid for by the actions it
# names, which is what keeps a cover from collapsing into the flat list.
lreach(w) = prod(length, w; init = 1)
function lcost(w)
    choice = 0; single = 0
    for m in w
        length(m) == 1 ? (single += olen(m[1])) :
            (choice += 1 + sum(o -> 1 + olen(o), m; init = 0))
    end
    return choice + (single > 0 ? 1 + single : 0)
end
olen(o::Vector{Int}) = length(o)
olen(o::UInt64) = count_ones(o)

# Is `a` the better layer? More members per printed option first — that is what
# a cover is for — then more menus, since a finer split says more about the
# family than a coarser one, and then the facts themselves, so that a tie never
# turns on the order the search happened to run in.
function richer(a, b)
    ka, kb = lreach(a) * lcost(b), lreach(b) * lcost(a)
    ka != kb && return ka > kb
    length(a) != length(b) && return length(a) > length(b)
    return a < b
end

# every selection of a layer, as masks
function layer_selections(menus::Vector{Vector{UInt64}})
    sels = UInt64[0]
    for m in menus
        sels = UInt64[s | o for s in sels for o in m]
    end
    return sels
end

# what the menus other than `skip` offer: their selections, and the facts they
# hold between them
function menu_context(menus::Vector{Vector{UInt64}}, skip)
    rest = Vector{UInt64}[menus[l] for l in eachindex(menus) if l ∉ skip]
    omask = UInt64(0)
    for m in rest, o in m
        omask |= o
    end
    return layer_selections(rest), omask
end

# The options one menu may hold, given what the others offer. A member that
# agrees with the others on their facts contributes what it has left over, and
# such an option is admissible exactly when every one of the others' selections
# completes it to a member — which is exactness, taken one option at a time,
# since a selection takes one option per menu and no more.
function menu_options(members::Vector{UInt64}, memset::Set{UInt64},
                      others::Vector{UInt64}, omask::UInt64, size::Int)
    seen = Set{UInt64}(others)
    out = UInt64[]
    for M in members
        (M & omask) in seen || continue
        o = M & ~omask
        count_ones(o) == size || continue
        o in out && continue
        all(s -> (s | o) in memset, others) || continue
        push!(out, o)
    end
    return sort!(out)
end

# The rectangles grown from one member: start with each of its facts a menu of
# its own — a rectangle covering that member alone — then extend every menu as
# far as exactness allows, and merge the pair of menus whose coupling buys the
# most members, until no merge buys one. Every state along the way is
# returned, since a merge covers more members and a split reads better, and
# which of the two wins is `richer`'s to decide and not this function's. A
# merge that buys no member is never made: two menus whose product is already
# exact are two choices the reader makes separately, and coupling them would
# print each entry of one beside every entry of the other — "relax A and relax
# H, or relax H and drop A" — which is a product written out, not a factor.
# Where a coupling does buy a member the split is not exact, and the compound
# entries are the family's own shape.
function grow_layers(members::Vector{UInt64}, memset::Set{UInt64}, seed::UInt64)
    menus = Vector{UInt64}[UInt64[UInt64(1) << b]
                           for b = 0:63 if !iszero((seed >> b) & 1)]
    out = Vector{Vector{UInt64}}[]
    isempty(menus) && return out
    while true
        grew = true
        while grew
            grew = false
            for i in eachindex(menus)
                others, omask = menu_context(menus, (i,))
                opts = menu_options(members, memset, others, omask,
                                    count_ones(menus[i][1]))
                length(opts) > length(menus[i]) || continue
                menus[i] = opts
                grew = true
            end
        end
        push!(out, Vector{UInt64}[copy(m) for m in menus])
        length(menus) > 1 || break
        best = nothing
        for i = 1:length(menus)-1, j = i+1:length(menus)
            others, omask = menu_context(menus, (i, j))
            sz = count_ones(menus[i][1]) + count_ones(menus[j][1])
            opts = menu_options(members, memset, others, omask, sz)
            gain = length(opts) - length(menus[i]) * length(menus[j])
            gain > 0 || continue
            (best === nothing || gain > best[1]) && (best = (gain, i, j, opts))
        end
        best === nothing && break
        menus[best[2]] = best[4]
        deleteat!(menus, best[3])
    end
    return out
end

# the flat list as a layer: one menu whose options are whole members
flat_layer(F::Vector{Vector{Int}}) =
    Menu[sort!(Vector{Int}[sort(m) for m in F])]

# The cover of a family by exact generalized rectangles: take the best
# rectangle there is, emit it as a layer, drop the members its selections
# reach, and go on until nothing is left. Since a single member is a rectangle,
# the cover always finishes and always presents the whole family.
#
# The first layer is the one the section's proofs answer for, so where any
# rectangle of two or more menus exists the first layer is one: a fact it
# offers is then a fact one of its menus holds, and the reason that menu owns
# names it. The layers after it repartition repairs and not reasons
# (Corollary 25), and may be flat.
function product_cover(F::Vector{Vector{Int}}, U::Vector{Int})
    layers = Layer[]
    isempty(F) && return layers
    n = length(U)
    # more facts than a mask holds: the flat list is all that can be said here,
    # and it does say all of it
    n > 64 && return Layer[flat_layer(F)]
    at = Dict{Int,Int}(u => i for (i, u) in enumerate(U))
    mask(m) = reduce(|, (UInt64(1) << (at[x] - 1) for x in m); init = UInt64(0))
    unmask(o) = Int[U[i] for i = 1:n if !iszero((o >> (i - 1)) & 1)]
    left = sort!(unique!(UInt64[mask(m) for m in F]))
    while !isempty(left)
        memset = Set{UInt64}(left)
        best = nothing
        for seed in left, cand in grow_layers(left, memset, seed)
            isempty(layers) && length(cand) < 2 && continue
            (best === nothing || richer(cand, best)) && (best = cand)
        end
        flat = Vector{UInt64}[copy(left)]
        (best === nothing || (!isempty(layers) && richer(flat, best))) &&
            (best = flat)
        layer = Menu[sort!(Vector{Int}[unmask(o) for o in m]) for m in best]
        sort!(layer; by = m -> first(first(m)))
        push!(layers, layer)
        reached = Set{UInt64}(layer_selections(best))
        filter!(m -> m ∉ reached, left)
    end
    return layers
end

## sections

# One independent block of the cheapest repairs, as the analysis settles it:
# the facts it is about, and the layers that present its share of them. The
# menus of the leading layer are the conflicts the page prints, and every layer
# after it an alternative to all of them at once.
struct Section
    facts  :: Vector{Int}
    layers :: Vector{Layer}
end

# the facts a node is about, gathered from its children where it has them
node_facts(t::DecompNode) =
    t.kind === :and || t.kind === :or ?
    sort!(unique!(reduce(vcat, Vector{Int}[node_facts(c) for c in t.children];
                         init = Int[]))) : sort(t.facts)

# choose-one menus, as the layer they are
singleton_layer(menus::Vector{Vector{Int}}) =
    Menu[Vector{Int}[Int[f] for f in m] for m in menus]

# The presentation of one node of the tree, over the family it is about. A node
# that is a product of choose-one menus is that product and nothing else, so
# every clean family reads as it always has; a genuine OR is its children, each
# a way of settling the whole of it; anything else — a prime block, or a
# threshold, which no registry query has yet produced — is covered by products.
function section_of(t::DecompNode, F::Vector{Vector{Int}})
    B = node_facts(t)
    ms = flatten_menus(t)
    ms === nothing || return Section(B, Layer[singleton_layer(ms)])
    if t.kind === :or
        ways = Layer[]
        for c in t.children
            Bc = node_facts(c)
            sub = flatten_menus(c)
            sub === nothing ? append!(ways, product_cover(within(F, Bc), Bc)) :
                push!(ways, singleton_layer(sub))
        end
        sort!(ways; lt = richer)
        return Section(B, ways)
    end
    return Section(B, product_cover(F, B))
end

# The sections of a family: the children of its decomposition where it factors,
# and the whole of it where it does not. The order is the tree's, which is the
# fact order, so the page numbers its conflicts the same way every time.
function plan_sections(fmin::Vector{Vector{Int}}, used::Vector{Int})
    F = Vector{Int}[sort(m) for m in fmin]
    # A family that counts right is a product (Theorem 6), and that check is a
    # component computation with no search at all. Where it answers, the
    # sections are its factors and nothing further need be decomposed.
    factors = product_menus(F, used)
    factors === nothing ||
        return Section[Section(f, Layer[singleton_layer([f])]) for f in factors]
    t = decompose(F, used)
    t.kind === :and &&
        return Section[section_of(c, proj(F, node_facts(c))) for c in t.children]
    return Section[section_of(t, F)]
end

# every repair a list of layers presents: one option from each menu of one of
# them, unioned
function cover_selections(layers::Vector{Layer})
    out = Vector{Int}[]
    for L in layers
        sels = Vector{Int}[Int[]]
        for m in L
            sels = Vector{Int}[[s; o] for s in sels for o in m]
        end
        append!(out, Vector{Int}[sort!(s) for s in sels])
    end
    return out
end

## reasons

# Reasons are enumerated by removal, over the whole pool and never a restricted
# one: a reason can hold this conflict's menu *and* facts another menu offers,
# and a pool with those held out cannot contain it. Every reason in the pool is
# recorded — take a minimal unsatisfiable subset, then recurse with each of its
# members removed — until the budget stops the walk, which is disclosed.
function reason_walk(sat::SAT, pool::Vector{Int}, lits::Vector{Int})
    found = Vector{Vector{Int}}()
    seen = Set{Vector{Int}}()
    budget = Ref(REASON_NODES)
    complete = Ref(true)
    index = Dict{Int,Int}(l => i for (i, l) in enumerate(lits))
    function walk(p::Vector{Int})
        if length(found) ≥ REASON_CAP || budget[] ≤ 0
            complete[] = false
            return
        end
        budget[] -= 1
        m = sat_mus(sat, Int[lits[i] for i in p])
        isempty(m) && return
        r = sort!(Int[index[l] for l in m])
        if !(r in seen)
            push!(seen, r)
            push!(found, r)
        end
        for x in r
            walk(Int[y for y in p if y != x])
        end
    end
    walk(pool)
    return found, complete[]
end

## explanation

# The query's own fact, as the clause it is: a requirement demands one of the
# package's versions, a constraint admits the versions it leaves and absence.
# Read straight off the query — which versions each kind rules out is data, not
# a solver question — so it is finer than the instance, which can only empty a
# whole class. Finer is sound: a stronger premise cannot make a contradiction
# less of one.
function fact_clause(sat::SAT{P,V}, prob::Problem{P}, f::Fact{P}) where {P,V}
    vs = clause_versions(sat, f.pkg)
    n = length(vs)
    b = falses(n + 1)
    if f.req
        b[1:n] .= true
    else
        for j = 1:n
            b[j] = isempty(exclusion_kinds(prob, f.pkg, vs[j]))
        end
        b[n+1] = true
    end
    return clause([f.pkg => Lit(b)])
end

# One meet: the pivot, the sides that close at it, and what the page costs
struct Meet{P}
    pivot :: P
    sides :: Vector{Tuple{Clause{P},Vector{P}}}
    key   :: Tuple{Bool,Int,Int,Int,Int,Int,String}
end

# The strongest bound on `pivot` each support entails, and the smallest
# subfamily of them that closes.
#
# The facts on the pivot itself are held out of the derivation and put back as
# sides: they are the query's own lines, already on the page, and leaving them
# in would let a side be stated from a support the printed implication cannot
# name.
function meet_at(
    sat   :: SAT{P,V},
    pivot :: P,
    reason:: Vector{Int},
    facts :: Vector{Fact{P}},
    fcl   :: Dict{Int,Clause{P}},
    core  :: Vector{Clause{P}},
    menu  :: Vector{Int},
) where {P,V}
    bit = Dict{Int,Int}(f => i - 1 for (i, f) in enumerate(reason))
    items = Item{P}[]
    on_pivot = Int[]
    for i in reason
        if facts[i].pkg == pivot
            push!(on_pivot, i)
        else
            push!(items, Item{P}(fcl[i], P[], UInt64(1) << bit[i]))
        end
    end
    for c in core
        push!(items, Item{P}(c, P[], UInt64(0)))
    end
    proj = eliminate_to(items, Set{P}([pivot]))
    proj === nothing && return nothing
    nv = length(clause_versions(sat, pivot))
    sigma = Dict{UInt64,BitVector}()
    routes = Dict{UInt64,Vector{P}}()
    for it in proj
        isbottom(it.clause) && return nothing
        m = it.clause[pivot]
        m === nothing && continue
        if haskey(sigma, it.mask)
            sigma[it.mask] .&= m.bits
            append!(routes[it.mask], it.route)
        else
            sigma[it.mask] = copy(m.bits)
            routes[it.mask] = copy(it.route)
        end
    end
    for (m, b) in sigma
        tighten!(sat, b, pivot, Int[facts[i].lit for i in reason
                                    if (m >> bit[i]) & 1 == 1])
    end
    base = trues(nv + 1)
    for i in on_pivot
        base .&= fcl[i][pivot].bits
    end
    # trim to an irredundant family, dropping the sides that cost most to read
    # first; nothing that matters can be lost this way, since every fact of the
    # reason roots a side of *whatever* family closes
    keep = Set{UInt64}(keys(sigma))
    for m in sort!(collect(keys(sigma)); by = x -> (-count_ones(x), -Int(x)))
        trial = copy(base)
        for x in keep
            x == m || (trial .&= sigma[x])
        end
        any(trial) || delete!(keep, m)
    end
    closed = copy(base)
    for x in keep
        closed .&= sigma[x]
    end
    any(closed) && return nothing
    # each side, stated from its support: the packages the support names, held
    # where the support holds them, imply the bound
    sides = Tuple{Clause{P},Vector{P}}[]
    menubits = UInt64(0)
    for i in menu
        haskey(bit, i) && (menubits |= UInt64(1) << bit[i])
    end
    forcing = false
    cond = cond_menu = fracture = routelen = 0
    for m in sort!(collect(keep))
        ant = Dict{P,BitVector}()
        for i in reason
            (m >> bit[i]) & 1 == 1 || continue
            p = facts[i].pkg
            b = fcl[i][p].bits
            haskey(ant, p) ? (ant[p] .&= b) : (ant[p] = copy(b))
        end
        pairs = Pair{P,Lit}[p => Lit(.~b) for (p, b) in ant]
        push!(pairs, pivot => Lit(copy(sigma[m])))
        cl = clause(pairs)
        cl === nothing && continue
        route = P[q for q in routes[m] if q ∉ packages(cl)]
        push!(sides, (cl, sort!(unique!(route))))
        sigma[m][end] || (forcing = true)
        wide = count_ones(m) > 1
        wide && (cond += 1)
        wide && !iszero(m & menubits) && (cond_menu += 1)
        lit = cl[pivot]
        # a support the registry cannot satisfy at all leaves the pivot out of
        # the statement: what the side says is then about its own packages
        lit === nothing ||
            (fracture += length(Clauses.selected_runs(selected(lit))))
        routelen += length(route)
    end
    key = (!forcing, cond_menu, cond, length(sides), routelen, fracture,
           string(pivot))
    return Meet{P}(pivot, sides, key)
end

# Every package the argument touches is a lawful pivot, so the choice is made
# for the reader by ranking what each would print: a meet with a forcing side
# first (a meet all of whose registry sides admit absence has elided the
# registry's half of the argument), then separated sides over conditional ones,
# then fewer sides, shorter routes and less version fracture.
function best_meet(
    sat   :: SAT{P,V},
    reason:: Vector{Int},
    facts :: Vector{Fact{P}},
    fcl   :: Dict{Int,Clause{P}},
    core  :: Vector{Clause{P}},
    menu  :: Vector{Int},
) where {P,V}
    cands = P[]
    for c in core, p in packages(c)
        p in cands || push!(cands, p)
    end
    for i in reason
        facts[i].pkg in cands || push!(cands, facts[i].pkg)
    end
    sort!(cands)
    best = nothing
    for p in cands
        m = meet_at(sat, p, reason, facts, fcl, core, menu)
        m === nothing && continue
        (best === nothing || m.key < best.key) && (best = m)
    end
    return best
end

# The joins of a parallel family: one candidate per package of the family,
# resolving on that package — intersect there, union everywhere else. On the
# antecedent package that is exactly the merge of implications, `A@R₁ → B@S₁`
# with `A@R₂ → B@S₂` giving `A@(R₁∪R₂) → B@(S₁∪S₂)`: antecedent literals are
# stored complemented, so unioning the ranges is intersecting the literals,
# which is resolution — and so the join is entailed by the family, sound by
# the one rule everything else already leans on. A literal-wise union would
# instead turn disjoint antecedents into a tautology and join nothing.
function clause_joins(cs::Vector{Clause{P}}) where {P}
    out = Clause{P}[]
    for q in packages(cs[1])
        u = resolve_raw(cs, q)
        u === nothing || isbottom(u) || push!(out, u)
    end
    return out
end

# Coarsen a core against the claim it belongs to, by licensed joins. Parallel
# statements about one set of packages differ in thresholds the proof may
# never need: replace a family by its join wherever the claim's clauses still
# cannot hold together, and keep the split wherever they can — the licence is
# the whole criterion, since a join is true by the weakening above and no
# local rule is both sound and sufficient (a boundary can be load-bearing
# three links away). Families that refuse to join whole are bisected in
# clause order, so a staircase gives up exactly the boundaries the
# contradiction is not standing on. This is what makes a lockstep family —
# nine parallel edges over one pair — projectable: the joins erase the
# thresholds that do not matter before the elimination pays for their
# combinations.
function coarsen_core(sat::SAT{P,V}, core::Vector{Clause{P}},
                      held::Vector{Clause{P}}) where {P,V}
    # families are processed one at a time and each licence is asked against
    # the set as it stands — earlier joins included — so the invariant after
    # every accepted join is that the whole current set still contradicts,
    # and in particular the final one does. Licensed one against the original
    # set instead, two joins could each pass and jointly satisfy.
    groups = Dict{Vector{P},Vector{Clause{P}}}()
    order = Vector{P}[]
    for c in core
        ps = packages(c)
        haskey(groups, ps) || push!(order, ps)
        push!(get!(Vector{Clause{P}}, groups, ps), c)
    end
    sort!(order)
    current = Dict{Vector{P},Vector{Clause{P}}}(k => copy(v) for (k, v) in groups)
    context(except) = Clause{P}[c for k in order if k != except
                                for c in current[k]]
    for ps in order
        function join_family(cs::Vector{Clause{P}}, rest::Vector{Clause{P}})
            length(cs) ≤ 1 && return cs
            for u in clause_joins(cs)
                clauses_satisfiable(sat,
                    Clause{P}[held; context(ps); rest; u]) && continue
                return Clause{P}[u]
            end
            h = length(cs) ÷ 2
            a, b = cs[1:h], cs[h+1:end]
            ja = join_family(a, Clause{P}[rest; b])
            jb = join_family(b, Clause{P}[rest; ja])
            return Clause{P}[ja; jb]
        end
        fam = sort!(current[ps]; by = c -> [m.bits for (_, m) in c.lits])
        current[ps] = join_family(fam, Clause{P}[])
    end
    return Clause{P}[c for k in order for c in current[k]]
end

# The registry's share of one reason: a minimal set of its statements that the
# reason cannot live with. Empty is a value here — a requirement whose package
# the query leaves nothing of contradicts it with no help from the registry.
function reason_core(satx::SAT{P,V}, reason::Vector{Int},
                     facts::Vector{Fact{P}}, selectors::Vector{Int}) where {P,V}
    isempty(selectors) && return Clause{P}[]
    fixed = Int[facts[i].litx for i in reason]
    out = Clause{P}[]
    for v in sat_mus(satx, fixed, selectors)
        c = clause_of(satx, satx.why[v])
        c === nothing || push!(out, c)
    end
    return out
end

# no line may say less than another beside it in the same proof: a covered line
# is one the reader has already been told
function drop_covered(lines::Vector{Line{P}}) where {P}
    keep = trues(length(lines))
    for i in eachindex(lines)
        keep[i] || continue
        for j in eachindex(lines)
            (i == j || !keep[j]) && continue
            subsumes(lines[i].clause, lines[j].clause) || continue
            lines[i].clause == lines[j].clause && i > j && continue
            keep[j] = false
        end
    end
    return Line{P}[lines[i] for i in eachindex(lines) if keep[i]]
end

## putting it together

# What the analysis settles, on the instance, before anything is resolved. The
# conflicts are the menus of every section's leading layer, in section order:
# each owns a reason of its own (Theorem 9), and the layers after the leading
# one own none (Corollary 25), so they are alternatives to a whole section's
# conflicts rather than conflicts themselves. `owner` says which section each
# conflict's menu came from.
struct Plan{P}
    sections  :: Vector{Section}
    owner     :: Vector{Int}
    reqs      :: Vector{Vector{P}}
    lines     :: Vector{Vector{Line{P}}}
    # per conflict: a tempting fact, and the rest of the cheapest repair that
    # carries it (empty where withdrawing that rest alone already repairs)
    blocks    :: Vector{Vector{Tuple{Vector{Int},Vector{Int}}}}
    others    :: Symbol
    truncated :: Bool
end

# Does this reason own that menu? Every reason meets every option of some menu
# (Theorem 9), and the section whose menu it is answers for it. Where the
# options are single facts — every clean family, and the primary layer of every
# product — that is the menu lying inside the reason.
owns(r::Vector{Int}, m::Menu) = all(o -> any(x -> x in r, o), m)

# the facts a menu names, whatever its options group them into
menu_facts(m::Menu) = sort!(unique!(reduce(vcat, m; init = Int[])))

# Do the sections present the family exactly, and all of it? A section's own
# offer is one entry from each menu of its leading layer — the conflicts it
# becomes — together with every selection of each layer after that, which the
# page prints as alternatives to those conflicts; `cover_selections` is
# precisely that union. The sections are independent blocks, so what the page
# offers is one of each in every combination — and that has to be the family
# itself: nothing offered that is not a cheapest repair, and no cheapest repair
# left unsaid.
function covers_family(secs::Vector{Section}, fmin::Vector{Vector{Int}})
    want = Set{Vector{Int}}(sort(m) for m in fmin)
    # no sections is one empty selection: a query already satisfiable on its
    # facts is repaired by doing nothing, and that is the whole of the family
    isempty(want) && return isempty(secs)
    out = Vector{Int}[Int[]]
    for s in secs
        sels = cover_selections(s.layers)
        allunique(sels) || return false
        out = Vector{Int}[sort!([a; b]) for a in out for b in sels]
        length(out) ≤ length(want) || return false
    end
    return Set(out) == want && length(out) == length(want)
end

# One reason, as the lines that argue it: the query's own facts it holds, and
# then the meet its supports close at — or, where no meet can be printed, the
# core itself. `n` numbers the argument, since a section that offers several
# menus answers for one reason per menu.
function reason_lines(sat::SAT{P,V}, satx::SAT{P,V}, facts::Vector{Fact{P}},
                      fcl::Dict{Int,Clause{P}}, selectors::Vector{Int},
                      r::Vector{Int}, menu::Vector{Int}, n::Int) where {P,V}
    ls = Line{P}[Line{P}(fcl[j], P[], true, n, nothing)
                 for j in r if haskey(fcl, j)]
    core = reason_core(satx, r, facts, selectors)
    meet = length(r) ≤ MASK_WIDTH ?
        best_meet(sat, r, facts, fcl, core, menu) : nothing
    if meet === nothing && !isempty(core)
        # the projection drowned — usually in a lockstep family whose
        # thresholds the proof never needed. Coarsen by licensed joins
        # and try once more; failing that, the coarsened core is still
        # the better fallback, since every join it prints is true and
        # the set still contradicts
        held = Clause{P}[fcl[j] for j in r if haskey(fcl, j)]
        core = coarsen_core(sat, core, held)
        meet = length(r) ≤ MASK_WIDTH ?
            best_meet(sat, r, facts, fcl, core, menu) : nothing
    end
    derived = meet === nothing ?
        Line{P}[Line{P}(it.clause, P[], false, n, nothing)
                for it in factor_items(
                    Item{P}[Item{P}(c, P[], UInt64(0)) for c in core])] :
        Line{P}[Line{P}(cl, trim_route(sat, core, cl, route),
                        false, n, meet.pivot)
                for (cl, route) in meet.sides]
    append!(ls, drop_covered(derived))
    return ls
end

function analyse(
    sat   :: SAT{P,V},
    satx  :: SAT{P,V},
    prob  :: Problem{P},
    facts :: Vector{Fact{P}},
) where {P,V}
    lits = Int[f.lit for f in facts]
    k, fmin, more = min_repairs(sat, lits)
    used = sort!(unique!(reduce(vcat, fmin; init = Int[])))
    # The cheapest repairs, decomposed and then covered by products: the tree
    # says which things are independently wrong, and each of them is presented
    # by exact rectangles of its own share of the family. Nothing is left over
    # by construction — the cover of a block always finishes on the block —
    # so there is no residue to lay out and no cross-product to enumerate.
    secs = isempty(used) ? Section[] : plan_sections(fmin, used)
    @assert covers_family(secs, fmin)
    # What is outside the page is then what the bounded enumeration itself
    # missed — the cap stopping and a further solve finding a repair beyond
    # what it found — and, failing that, Theorem 5's one question about
    # repairs that give up more
    others = more ? :some : (larger_repairs(sat, lits, fmin) ? :larger : :none)

    fcl = Dict{Int,Clause{P}}()
    for i in eachindex(facts)
        c = fact_clause(sat, prob, facts[i])
        c === nothing || (fcl[i] = c)
    end
    # Every fact the page's own fixes take, on any layer of any section. An
    # action the page offers is not a road not taken, so no fact here is
    # tempting — and a fact *is* one action of the page's vocabulary, since the
    # two facts a package can have differ in kind, one asking that the
    # requirement be dropped and the other that the query's limits be lifted.
    cover = Set{Int}(x for s in secs for L in s.layers for m in L
                       for o in m for x in o)

    selectors = sort!(collect(keys(satx.why)))
    owner = Int[]
    reqs = Vector{P}[]
    lines = Vector{Line{P}}[]
    blocks = Vector{Tuple{Vector{Int},Vector{Int}}}[]
    truncated = false
    # one walk, over the whole fact set: a reason can hold this menu *and*
    # facts another menu offers, and a pool with those held out cannot contain
    # it. Ownership is then a filter, and a reason two conflicts own is set out
    # under both — redundant, never wrong.
    found = Vector{Vector{Int}}()
    if !isempty(secs)
        found, ok = reason_walk(sat, collect(eachindex(facts)), lits)
        ok || (truncated = true)
    end
    # The conflicts are the menus of every section's leading layer — the layers
    # after it repartition repairs and not reasons (Corollary 25) — so these
    # are the menus a reason is owned by and settled at, one conflict each.
    prim = Tuple{Int,Menu}[(i, m) for (i, s) in enumerate(secs)
                           for m in first(s.layers)]
    at = Dict{Int,Int}(l => j for (j, l) in enumerate(lits))
    for (pi, (si, m)) in enumerate(prim)
        told = Vector{Vector{Int}}()
        ls = Line{P}[]
        # One reason per conflict: the shortest its menu owns. A second owned
        # reason proves the same thing a second way, which the page has no room
        # to spend and the reader no use for; what it wanted the second reason
        # for — why an action it can see is not offered — is a question about
        # repairs, and the blocked entries below answer it from the cover and
        # one bounded search apiece.
        function explain(r::Vector{Int}, menu::Vector{Int})
            r in told && return
            push!(told, r)
            append!(ls, reason_lines(sat, satx, facts, fcl, selectors, r, menu,
                                     length(told)))
        end
        rs = Vector{Int}[r for r in found if owns(r, m)]
        sort!(rs; by = r -> (length(r), r))
        if isempty(rs)
            # every conflict owns a reason of its very own, whatever the walk
            # got to: with the other menus settled one way, what is left is
            # still unsatisfiable and every reason in it is this one's
            held = Set{Int}()
            for (qi, (_, mq)) in enumerate(prim)
                qi == pi || union!(held, first(mq))
            end
            pool = Int[lits[x] for x in eachindex(facts) if x ∉ held]
            r = sort!(Int[at[l] for l in sat_mus(sat, pool)])
            isempty(r) && (r = menu_facts(m))
            truncated = true
            explain(r, menu_facts(m))
        else
            explain(first(rs), menu_facts(m))
        end
        # ... and then whatever more it takes to name every package this menu
        # offers. A menu of compound options is owned by reasons that need not
        # hold all of its facts, and a fix the page makes while no line speaks
        # of its package would be talking past the reader.
        for o in m, x in o
            named = Set{P}(p for l in ls for p in packages(l.clause))
            facts[x].pkg in named && continue
            rs = Vector{Int}[r for r in found if x in r && r ∉ told]
            isempty(rs) && continue
            sort!(rs; by = r -> (length(r), r))
            explain(first(rs), Int[x])
        end
        rs = sort!(unique!(P[facts[j].pkg for r in told for j in r
                            if facts[j].req]))
        # What this page makes tempting, and what the solver says of each: a
        # package its lines or its heading name, an action on that package the
        # cover never offers, and the cheapest repair carrying that action.
        # Where the rest of that repair repairs on its own, the action is dead
        # weight in it and the verdict is flat; where it does not, that rest is
        # the price of the road, and never a fix the page has printed already
        # (Lemma 28). Where the search gave up there is nothing to say.
        named = Set{P}(p for l in ls for p in packages(l.clause))
        union!(named, rs)
        blks = Tuple{Vector{Int},Vector{Int}}[]
        exhibits = Dict{Vector{Int},Vector{Int}}() # repair => its tempting facts
        for x in eachindex(facts)
            (facts[x].pkg in named && x ∉ cover) || continue
            v = blocked_verdict(sat, lits, x, k)
            v === nothing && continue
            if isempty(v)
                push!(blks, (Int[x], Int[]))
            else
                push!(get!(Vector{Int}, exhibits, sort!([v; x])), x)
            end
        end
        # two tempting actions exhibiting one repair are one entry: each is
        # insufficient alone and the repair carries them both, so the page
        # says the repair once, from all its tempting ends at once
        for (W, xs) in sort!(collect(exhibits))
            push!(blks, (sort!(xs), Int[j for j in W if j ∉ xs]))
        end
        push!(owner, si)
        push!(lines, ls)
        push!(blocks, blks)
        push!(reqs, rs)
    end
    return Plan{P}(secs, owner, reqs, lines, blocks, others, truncated)
end

# The kinds to lift so that a package this query emptied is choosable again.
# Its classes are what a lift has to give back — a version is not something the
# universe can be asked about — so the cheapest lift is the smallest set of
# kinds restoring every class the full lift would, and among those the one
# whose best restored version is best.
#
# A class comes back once every kind excluding some member of it is lifted, so
# what restores it is one of its members' exclusion sets, and a lift restoring
# every class is a union of one such choice per class. A smallest lift is such
# a union, and among the smallest so is the one whose best restored version is
# best (any kind outside every exclusion set it covers could be dropped), so
# the search is over those unions and nothing else. Subsets of the kinds were
# searched before, which is exponential in how many kinds the query has on `p`
# — one per file where a workspace's members each declare a compat — and a
# package every member holds to the same range needs all of them lifted, which
# was the last subset of the last size.
function lift_actions(prob::Problem{P}, sat::SAT{P,V}, univ::Universe{P,V},
                      p::P) where {P,V}
    info = sat.info[p]
    reps = univ.reps[p]
    vs = info.versions
    excl = Vector{Symbol}[exclusion_kinds(prob, p, v) for v in vs]
    # per dead class, what restoring it could take: its members' exclusion
    # sets, one of which the lift must cover; a class with a member no kind
    # excludes is not the query's to restore and asks nothing
    choices = Vector{Vector{Symbol}}[
        unique!(Vector{Symbol}[excl[j] for j in info.members[c]])
        for c in eachindex(reps) if iszero(reps[c])]
    filter!(cs -> !any(isempty, cs), choices)
    # the classes that leave no choice first, so that what they fix is fixed
    # before anything branches
    sort!(choices; by = length)
    # smaller first, then the lift admitting the best excluded version, then
    # the kinds themselves: what a version is admitted by is the lift covering
    # everything that excludes it
    function key(S::Vector{Symbol})
        j = findfirst(j -> !isempty(excl[j]) && excl[j] ⊆ S, eachindex(vs))
        return (length(S), something(j, length(vs) + 1), S)
    end
    best = nothing
    function search(i::Int, S::Vector{Symbol})
        best !== nothing && length(S) > best[1] && return
        if i > length(choices)
            k = key(S)
            (best === nothing || k < best) && (best = k)
            return
        end
        any(E -> E ⊆ S, choices[i]) && return search(i + 1, S)
        for E in choices[i]
            search(i + 1, sort!(union(S, E)))
        end
    end
    search(1, Symbol[])
    lift = best === nothing ? Symbol[] : best[3]
    return Action{P}[Action(k, p) for k in lift]
end

fix_actions(prob::Problem{P}, sat::SAT{P,V}, univ::Universe{P,V},
            f::Fact{P}) where {P,V} =
    f.req ? Action{P}[Action(:drop, f.pkg)] : lift_actions(prob, sat, univ, f.pkg)

# What carrying `actions` out gets you: the resolver's own answer for the
# withdrawn query, on the universe the failed resolve was run against. A model
# found during diagnosis witnesses satisfiability; which versions the user
# would *get* is the resolver's optimising answer, and nothing else may stand
# in for it.
function witness(sat::SAT{P,V}, univ::Universe{P,V}, prob::Problem{P},
                 actions::Vector{Action{P}}; by, order) where {P,V}
    drop_reqs, drop_constraints = withdrawal(actions)
    sol = resolve(sat, relax(univ, prob, drop_reqs, drop_constraints; order); by)
    return sol === nothing ? Dict{P,V}() : sol
end

# The withdrawal a set of actions asks for: the requirements to stop requiring,
# and per constraint kind the packages to lift it for. An action names a kind
# of the query's own, so this is a reading of the actions and not a decision
# about them.
function withdrawal(actions::Vector{Action{P}}) where {P}
    drop_reqs = P[a.pkg for a in actions if a.kind === :drop]
    drop_constraints = Dict{Symbol,Set{P}}()
    for a in actions
        a.kind === :drop && continue
        push!(get!(Set{P}, drop_constraints, a.kind), a.pkg)
    end
    return drop_reqs, drop_constraints
end

"""
    diagnose(sat, prob, univ; by, order) :: Diagnosis

Why `prob` cannot be satisfied on `univ`, and what its user could change. The
instance is left exactly as it was found, so a caller may go on using it.

Requirements the universe holds nothing of are their own conflicts: nothing
this query did took them away, so dropping them is all that could help. What is
left is settled on the facts — the requirements and the query's own version
limits — and one relaxation is resolved per fix on the menus offered.
"""
function diagnose(
    sat  :: SAT{P,V},
    prob :: Problem{P},
    univ :: Universe{P,V};
    by   :: Function = identity,
    order = nothing,
) where {P,V}
    vm = VarMap(sat)
    seen = P[]
    for p in prob.reqs
        p in seen || push!(seen, p)
    end
    sort!(seen)
    gone = P[p for p in seen if !haskey(vm, p)]
    live = P[p for p in seen if haskey(vm, p)]

    facts = Fact{P}[]
    satx = SAT(univ; explain = true)
    plan = try
        vmx = VarMap(satx)
        with_classes_relaxed(sat) do
            with_emptied_packages(sat, vm) do lits, _
                with_classes_relaxed(satx) do
                    with_emptied_packages(satx, vmx) do litsx, _
                        for i in eachindex(vm.pkgs)
                            push!(facts, Fact{P}(false, vm.pkgs[i], lits[i], litsx[i]))
                        end
                        for p in live
                            push!(facts, Fact{P}(true, p, installed_lit(sat, p),
                                                 installed_lit(satx, p)))
                        end
                        analyse(sat, satx, prob, facts)
                    end
                end
            end
        end
    finally
        Resolver.finalize(satx)
    end

    # The sections, as the actions they ask for: the missing requirements
    # first, each its own forced choice, then the cover of the cheapest
    # repairs, layer by layer and menu by menu — the leading layer's menus as
    # the conflicts they are, and every layer after it as an alternative to
    # them all.
    function option_actions(o::Vector{Int})
        as = Action{P}[]
        for x in o, a in fix_actions(prob, sat, univ, facts[x])
            a in as || push!(as, a)
        end
        return as
    end
    alayers = Vector{Vector{Vector{Vector{Action{P}}}}}[
        Vector{Vector{Vector{Action{P}}}}[
            Vector{Vector{Action{P}}}[Vector{Action{P}}[option_actions(o)
                                                        for o in m]
                                      for m in L]
            for L in s.layers]
        for s in plan.sections]
    # How the page settles a section while it shows what one fix elsewhere
    # gets you: the first option of every menu of its primary layer.
    defaults = Vector{Action{P}}[]
    for L in alayers
        as = Action{P}[]
        for m in first(L), a in first(m)
            a in as || push!(as, a)
        end
        push!(defaults, as)
    end

    conflicts = Conflict{P,V}[]
    # what the rest of the page asks for, with section `si` (or none) left out
    function elsewhere(si::Int, skip_gone::Int)
        as = Action{P}[Action(:drop, gone[j]) for j in eachindex(gone)
                       if j != skip_gone]
        for j in eachindex(defaults), a in (j == si ? Action{P}[] : defaults[j])
            a in as || push!(as, a)
        end
        return as
    end
    for (i, p) in enumerate(gone)
        acts = Action{P}[Action(:drop, p)]
        f = Fix{P,V}(copy(acts),
                     witness(sat, univ, prob, unique!([acts; elsewhere(0, i)]);
                             by, order))
        push!(conflicts, Conflict{P,V}(P[p], Line{P}[], Dict{P,Vector{V}}(),
            Dict{P,Vector{Vector{Symbol}}}(), Fix{P,V}[f],
            Tuple{Vector{Vector{Action{P}}},Vector{Action{P}}}[]))
    end
    # one menu of a layer, as the fixes it offers: each option withdrawn with
    # the layer's other menus settled the first way they offer, which is how
    # every menu on the page reads
    function menu_fixes(L::Vector{Vector{Vector{Action{P}}}}, mi::Int,
                        rest::Vector{Action{P}})
        mates = Action{P}[a for (mj, mq) in enumerate(L) if mj != mi
                            for a in first(mq)]
        return Fix{P,V}[Fix{P,V}(copy(o),
                                 witness(sat, univ, prob,
                                         unique!(Action{P}[o; mates; rest]);
                                         by, order))
                        for o in L[mi]]
    end
    # which conflicts came from which section, so that a later layer can name
    # the ones it is an alternative to
    mine = Vector{Int}[Int[] for _ in plan.sections]
    for i in eachindex(plan.owner)
        push!(mine[plan.owner[i]], length(gone) + i)
    end
    for i in eachindex(plan.owner)
        n = plan.owner[i]
        L = first(alayers[n])
        mi = findfirst(==(length(gone) + i), mine[n])
        fixes = menu_fixes(L, mi, elsewhere(n, 0))
        blocks = Tuple{Vector{Vector{Action{P}}},Vector{Action{P}}}[
            (Vector{Action{P}}[fix_actions(prob, sat, univ, facts[x])
                               for x in xs],
             Action{P}[a for j in rst
                       for a in fix_actions(prob, sat, univ, facts[j])])
            for (xs, rst) in plan.blocks[i]]
        lines = plan.lines[i]
        pkgs = P[]
        for l in lines, p in packages(l.clause)
            p in pkgs || push!(pkgs, p)
        end
        # over the universe the user sees, lines and all (`widened`)
        versions, excluded, shadows, lines = widened(sat, prob, pkgs, lines)
        push!(conflicts, Conflict{P,V}(plan.reqs[i], lines, versions, excluded,
                                       fixes, blocks, Upstream{P,V}[], shadows))
    end
    # Every layer after the leading one is an alternative to the whole of its
    # section's conflicts. Which of them it declines is read off the facts: a
    # leading menu the layer shares no fact with is one every selection of the
    # layer misses entirely, and those are what the label says it is instead of.
    alternatives = Alternative{P,V}[]
    for (n, s) in enumerate(plan.sections)
        rest = elsewhere(n, 0)
        lead = first(s.layers)
        for li = 2:length(s.layers)
            here = Set{Int}(x for m in s.layers[li] for o in m for x in o)
            avoided = Int[mine[n][mi] for mi in eachindex(lead)
                          if isdisjoint(menu_facts(lead[mi]), here)]
            L = alayers[n][li]
            menus = Vector{Fix{P,V}}[menu_fixes(L, mi, rest)
                                     for mi in eachindex(L)]
            push!(alternatives,
                  Alternative{P,V}(copy(mine[n]), avoided, menus))
        end
    end
    # where the query said its requirements are required from rides along for
    # the report: satisfiability never asked, and the fixes are the same
    return Diagnosis{P,V}(conflicts, alternatives, plan.others, plan.truncated,
                          false, Dict{P,Vector{String}}(prob.sources))
end

## upstream fixes
#
# Everything a menu offers is what the user could change. A conflict's chain
# ends where a registry statement meets one of the user's own facts, and the
# registry side is something a maintainer could change instead — so the page
# may say so, under a bar high enough that what it says is a single, sendable
# request: the sentence a user would put in an issue, and one this has resolved
# and found would work.
#
# The hypothetical is the package's latest version with its bound on the other
# package dropped and nothing else changed, modelled in place: same version
# number, same dependencies, same bounds on everything else, so that it behaves
# as the latest in every clause but one and no third package's bound on it comes
# into question. What a solve on that registry proves is exactly the sentence
# printed (Lemma 32 of the theory page): a model taking the release takes the
# bounded package outside the dropped bound, and the witness names the version.
#
# This needs the package data — a release is a different registry, not a
# different query — so it runs out here rather than inside `diagnose`, which
# has only the universe the failed resolve was run against.

# how many qualifying releases one conflict may name, and how many solves the
# whole report may spend looking for them. A candidate the budget leaves untried
# is a sentence the page did not print, never a false one: it is recorded on the
# diagnosis and not announced (Section 11 of the theory page).
const UPSTREAM_PER_CONFLICT = 2
const UPSTREAM_SOLVES = 8

# The pairs this conflict could ask a release for, in the order it would name
# them, each with the version a release would be of and the versions of the
# other package that version supports as it stands. `q` runs over the packages
# the page states a constraint of the user's own about, in the order it states
# them — only such a package counts, since a bound contradicted by another
# registry package's bound would blame two maintainers and judge between them.
# `p` runs over the packages this conflict's lines speak of, the pair closing
# the chain first, since that is the bound the reader has just read.
#
# Two of the three conditions are decided here, off the data and the query
# alone: the bound must exclude every version of `q` the user's own constraint
# leaves — one it admits is not what stops the user — and the query must admit
# `p`'s latest, since otherwise a release that helps exists already and the menu
# says so. The third is a solve.
function upstream_candidates(base, prob::Problem{P}, c::Conflict{P,V}) where {P,V}
    out = Tuple{P,V,P,Vector{V}}[]
    isempty(c.lines) && return out
    _, con, _, _ = given_facts(c, Line{P}[l for l in c.lines if l.given])
    isempty(con) && return out
    pkgs = line_packages(c)
    for q in chain_closers(c)
        haskey(con, q) || continue
        ps = P[]
        for l in c.lines
            l.given && continue
            l.pivot == q || continue
            for p in packages(l.clause)
                p == q || p in ps || push!(ps, p)
            end
        end
        for p in pkgs
            p == q || p in ps || push!(ps, p)
        end
        qd = base(q)
        for p in ps
            pd = base(p)
            isempty(pd.versions) && continue
            v = maximum(pd.versions)
            haskey(pd.compat, v) || continue
            comp = pd.compat[v]
            haskey(comp, q) || continue
            s = comp[q]
            any(w -> !is_excluded(prob, q, w) && w in s, qd.versions) && continue
            is_excluded(prob, p, v) && continue
            # ... and there has to be a range to name. The sentence says what
            # the bound does support, of the versions the page speaks of `q`
            # in, so a bound that admits none of them or all of them is one the
            # page cannot state — and a candidate it cannot state is one it
            # does not try
            sel = Bool[w in s for w in c.versions[q]]
            (any(sel) && !all(sel)) || continue
            push!(out, (p, v, q, V[w for w in c.versions[q] if w in s]))
        end
    end
    return out
end

# `p`'s data with its latest version's bound on `q` removed, in place: same
# version numbers, same dependencies, same bounds on every other package and
# for every other version. The compat map is rebuilt rather than edited, since
# a provider's own may be shared between versions and is not ours to change —
# and rebuilt entry by entry, so that versions that shared one before share one
# still, which is what keeps the artifact behind the probe the size it was.
function without_bound(pd::PkgData{P,V,S}, v::V, q::P) where {P,V,S}
    comp = Dict{V,Dict{P,S}}()
    seen = IdDict{Any,Dict{P,S}}()
    for (w, e) in pd.compat
        comp[w] = w == v ? Dict{P,S}(r => s for (r, s) in e if r != q) :
                           get!(() -> Dict{P,S}(e), seen, e)
    end
    return PkgData(pd.versions, pd.depends, comp)
end

# One candidate, tried (condition 3): the query with every other conflict
# settled the first way its menu offers — the convention every witness on the
# page uses — resolved against the registry that release would make. `nothing`
# where it does not answer with `p` at its latest and `q` installed, which is
# what the sentence would have claimed.
function upstream_probe(deps::DepsProvider{P,D}, base, prob::Problem{P},
                        p::P, v::V, q::P, supported::Vector{V},
                        settle::Vector{Action{P}}; by, order) where {P,D,V}
    over = without_bound(base(p), v, q)
    release(r::P) = r == p ? over : base(r)
    # the release's own data is a `PkgData` of its own type — same versions,
    # same dependencies, a compat map rebuilt — so the provider answers in
    # whatever both it and the rest of the registry are
    prov = DepsProvider{P,typejoin(D, typeof(over)),typeof(release)}(
        deps.packages, release)
    drop_reqs, drop_constraints = withdrawal(settle)
    sol = resolve(prov, relax(prob, drop_reqs, drop_constraints);
                  by, order, diagnose = false, upstream = false)
    sol === nothing && return nothing
    get(sol, p, nothing) == v || return nothing
    w = get(sol, q, nothing)
    w === nothing && return nothing
    return Upstream{P,V}(p, v, q, w, supported, sol)
end

"""
    upstream_fixes(deps, prob, d; by, order) :: Diagnosis

`d` with each conflict's upstream fixes filled in: for every conflict, up to
two releases someone else could cut that a resolve says would settle it — see
[`Upstream`](@ref) for what a release is taken to be and what it takes to
qualify. Everything else about `d` is unchanged, and a diagnosis whose
conflicts have no qualifying pair comes back as it went in.

`deps` is the package data the releases are tried against, as a `DepsProvider`
or a dict of `PkgData`; `prob` is the query `d`
diagnoses; `by` and `order` are the orderings the witnesses are resolved with,
as `resolve` takes them. Each candidate costs one resolve on modified data,
under a budget per report; what the budget leaves untried sets `upstream_cut`
on the answer and is not otherwise announced.
"""
function upstream_fixes(deps::DepsProvider{P,D}, prob::Problem{P},
                        d::Diagnosis{P,V}; by::Function = identity,
                        order = nothing) where {P,D,V}
    isempty(d.conflicts) && return d
    # one call per package for the whole report, however many releases are
    # tried: the data is the same for every candidate but the one package each
    # of them edits
    cache = Dict{P,D}()
    base(r::P) = get!(() -> deps.provider(r)::D, cache, r)
    firsts = Vector{Action{P}}[isempty(c.fixes) ? Action{P}[] :
                               first(c.fixes).actions for c in d.conflicts]
    ups = Vector{Upstream{P,V}}[Upstream{P,V}[] for _ in d.conflicts]
    solves = 0
    cut = false
    for (i, c) in enumerate(d.conflicts)
        cands = upstream_candidates(base, prob, c)
        isempty(cands) && continue
        settle = Action{P}[]
        for j in eachindex(firsts), a in (j == i ? Action{P}[] : firsts[j])
            a in settle || push!(settle, a)
        end
        for (p, v, q, supported) in cands
            length(ups[i]) < UPSTREAM_PER_CONFLICT || break
            if solves ≥ UPSTREAM_SOLVES
                cut = true
                break
            end
            solves += 1
            u = upstream_probe(deps, base, prob, p, v, q, supported, settle;
                               by, order)
            u === nothing && continue
            push!(ups[i], u)
        end
    end
    (cut || any(!isempty, ups)) || return d
    conflicts = Conflict{P,V}[
        Conflict{P,V}(c.reqs, c.lines, c.versions, c.excluded, c.fixes,
                      c.blocks, ups[i], c.shadows)
        for (i, c) in enumerate(d.conflicts)]
    return Diagnosis{P,V}(conflicts, d.alternatives, d.others, d.truncated,
                          d.upstream_cut | cut, d.sources)
end

upstream_fixes(data::AbstractDict{P,<:PkgData{P}}, prob::Problem{P},
               d::Diagnosis{P,V}; by::Function = identity,
               order = nothing) where {P,V} =
    upstream_fixes(DepsProvider(p -> data[p], keys(data)), prob, d; by, order)

## the report
#
# What a diagnosis says, and the rules that keep every sentence of it true.
#
# A proof prints as one chain. The heading names the requirements the conflict
# answers for, and the body never says them again: the chain starts at the root
# fact the query narrowed, said as the user's ("your compat restricts A to
# 1.2"), runs through the registry's statements in antecedent-before-use
# order — each said to the package the one before it left bounded, with the
# packages an elimination reached it through in parentheses — and ends at the
# fact that contradicts what the chain has accumulated. Where that closing
# fact is one of the query's own it is printed; where it is a requirement the
# heading states, the heading has already said it.
#
# A clause has no direction, so which way a line is said is chosen when it is
# said, and a line that continues through a package is said to the package it
# rests on instead. Such a line reads its antecedent against the bound the chain
# left at that package — a weakening of what the line says, hence true, and
# exactly what the reader is holding. Only a meet of three or more sides refuses
# to linearize, since two of its sides would have to arrive from nowhere; that
# alone still prints whole, as the sides whose intersection is empty.
#
# What the page claims is its heading's requirements together with its lines,
# and a check of the report reads the two as one set: the lines alone are
# satisfied by installing nothing, and it is the heading that rules that out.
# What the chain chooses is the order of the lines and which way each is said,
# never which lines there are.
#
# Only a query line may say "your". Everything else is the registry's, and a
# registry statement never attributes a bound to a `Project.toml` it cannot see.

# print `text` filled to `width` columns, `lead` before the first line and
# `rest` before every later one — a report is read in a terminal, and a line
# that runs off the edge of one is a line the reader scrolls sideways for
function print_wrapped(io::IO, text::AbstractString, lead::String, rest::String;
                       width::Int = 78)
    col = textwidth(lead)
    print(io, lead)
    for (k, word) in enumerate(split(text))
        w = textwidth(word)
        if k > 1
            if col + 1 + w > width
                print(io, "\n", rest)
                col = textwidth(rest)
            else
                print(io, " ")
                col += 1
            end
        end
        print(io, word)
        col += w
    end
    println(io)
end

"""
    action_phrase(a::Action) :: String

One action, said as something the reader could carry out. Whatever a constraint
kind is called inside the resolver, what it reads as here is an edit.
"""
action_phrase(a::Action) = action_phrase(kind_base(a.kind), a.pkg, kind_sources(a.kind))

# the three forms of one action, each over a kind, the package, and the places
# it was declared: to do, being tried, and done
function action_phrase(kind::Symbol, pkg, srcs)
    kind === :drop && return "drop dependency $pkg$(paren(srcs))"
    kind === :compat && return "relax your compat on $pkg$(paren(srcs))"
    kind === :pin && return "unpin $pkg$(paren(srcs))"
    return "allow $kind versions of $pkg$(paren(srcs))"
end

# the same action, said as the thing tried rather than the thing to do: a
# blocked entry reports on a road not taken
function action_gerund(kind::Symbol, pkg, srcs)
    kind === :drop && return "dropping dependency $pkg$(paren(srcs))"
    kind === :compat && return "relaxing your compat on $pkg$(paren(srcs))"
    kind === :pin && return "unpinning $pkg$(paren(srcs))"
    return "allowing $kind versions of $pkg$(paren(srcs))"
end

# ... and as the thing that would have had to happen as well: the completion
# an "unless you also" names
function action_past(kind::Symbol, pkg, srcs)
    kind === :drop && return "dropped dependency $pkg$(paren(srcs))"
    kind === :compat && return "relaxed your compat on $pkg$(paren(srcs))"
    kind === :pin && return "unpinned $pkg$(paren(srcs))"
    return "allowed $kind versions of $pkg$(paren(srcs))"
end

# Where something was declared, said in parentheses after it, as the query
# gave it: a caller that passes `path:line` gets what an editor opens, and a
# query that said nothing gets nothing.
paren(srcs) = isempty(srcs) ? "" : " (" * join(srcs, ", ") * ")"

# the places a kind carries: the one inside a sourced kind, or none
kind_sources(kind::Symbol) =
    (s = kind_source(kind); s === nothing ? String[] : String[s])

# Actions said together, `say` being one of the three forms above. Actions of
# one kind on one package from several places — the compat on X in two files —
# are one thing to do, said once with every place named: "relax your compat on
# X (a, b)". A requirement is dropped by one action however many places
# require it, and `sources` says which those are.
function actions_phrase(say::Function, actions::AbstractVector{Action{P}},
                        sources::AbstractDict{P,Vector{String}}) where {P}
    groups = Tuple{Symbol,P,Vector{String}}[]
    for a in actions
        base = kind_base(a.kind)
        i = findfirst(g -> g[1] === base && g[2] == a.pkg, groups)
        i === nothing && (push!(groups, (base, a.pkg, String[])); i = length(groups))
        union!(groups[i][3], base === :drop ? get(sources, a.pkg, String[]) :
                                              kind_sources(a.kind))
    end
    return String[say(base, pkg, srcs) for (base, pkg, srcs) in groups]
end

# the constraint kinds a line rests on, as the reader's own: one phrase per
# kind whatever the places it was declared in, "your compat (a, b) and your pin"
function your_phrases(kinds::Vector{Symbol})
    bases = Symbol[]
    srcs = Dict{Symbol,Vector{String}}()
    for k in kinds
        b = kind_base(k)
        b in bases || push!(bases, b)
        union!(get!(Vector{String}, srcs, b), kind_sources(k))
    end
    return String["your $b$(paren(srcs[b]))" for b in bases]
end

no_sources(::Type{P}) where {P} = EmptyDict{P,Vector{String}}()

join_and(xs) = join(xs, ", ", " and ")
join_or(xs) = join(xs, ", ", " or ")

fix_phrase(f::Fix{P,V}, sources = no_sources(P)) where {P,V} =
    join_and(actions_phrase(action_phrase, f.actions, sources))

# The requirements a conflict's heading names: the ones it answers for, which
# are its reason's own. Every conflict reads under an implicit "given the rest
# of the requirements", so the heading is what this conflict is about.
heading_reqs(c::Conflict) = c.reqs

# What a conflict is about — the packages, and no claim about them. A sentence
# would either claim too much ("cannot be satisfied" is false absolutely and
# true only under the unstated *given the rest*) or spell the context out at
# absurd length; the bare list is as clear, shorter, and never wrong. The one
# sentence that survives is the absolute truth: a requirement whose package the
# universe holds nothing of has no argument to make, and what became of it is
# the whole of what there is to say.
function conflict_heading(c::Conflict{P,V}, also = nothing,
                          sources = no_sources(P)) where {P,V}
    rs = heading_reqs(c)
    # a requirement is named with where the query says it is required from:
    # the reader of a workspace's report goes to that file
    req(r) = string(r) * paren(get(sources, r, String[]))
    isempty(c.lines) && length(rs) == 1 &&
        return "no version of $(req(only(rs))) is available."
    isempty(rs) && return "the dependencies"
    parts = String[req(r) for r in rs]
    also === nothing || push!(parts, string(also))
    return join_and(parts)
end

# The packages a conflict's lines name, in the order the lines name them.
function line_packages(c::Conflict{P,V}) where {P,V}
    ps = P[]
    for l in c.lines, p in packages(l.clause)
        p in ps || push!(ps, p)
    end
    return ps
end

# Which package tells this conflict apart from the others its heading collides
# with: one its own lines name and `common` — the packages every one of them
# names — does not, or nothing where its lines say nothing the others do not.
# Among several, the package the chain closes against — the last query fact the
# page states, read off the chain itself rather than guessed at — since that is
# where this conflict contradicts, and so the difference the reader is being
# pointed at rather than a name picked off a list. Failing that the meet's
# pivot, which is what a page that states no query fact argues about. A
# requirement the heading already names is never the answer.
function distinguishing_package(c::Conflict{P,V}, common::Set{P}) where {P,V}
    cands = P[p for p in line_packages(c) if p ∉ common && p ∉ c.reqs]
    isempty(cands) && return nothing
    for p in Iterators.reverse(chain_closers(c))
        p in cands && return p
    end
    for l in Iterators.reverse(c.lines)
        l.pivot in cands && return l.pivot
    end
    return cands[1]
end

# The packages the page states the query's own facts about, in the order it
# states them — the chain's own walk, asked and not printed.
chain_closers(c::Conflict{P,V}) where {P,V} =
    print_chain(devnull, c, Line{P}[l for l in c.lines if l.given],
                Line{P}[l for l in c.lines if !l.given],
                p -> c.versions[p], string)

# Two conflicts rooted in the same requirements print the same bare list, and a
# heading repeated reads as one conflict said twice rather than as two separate
# problems with one requirement in common. So a colliding heading is extended
# with the package that conflict contradicts at: still a bare list, still
# claiming nothing, and now naming what makes it its own conflict. A heading
# nothing collides with is untouched, and where the lines overlap entirely
# there is nothing to add — the conflict's number is the whole of the
# difference. Presentation only: what the conflict answers for is `reqs`, which
# this does not touch.
function heading_extras(cs::Vector{Conflict{P,V}}) where {P,V}
    extras = Dict{Int,P}()
    groups = Dict{String,Vector{Int}}()
    for (i, c) in enumerate(cs)
        push!(get!(Vector{Int}, groups, conflict_heading(c)), i)
    end
    for is in values(groups)
        length(is) > 1 || continue
        common = reduce(intersect, (Set{P}(line_packages(cs[i])) for i in is))
        for i in is
            p = distinguishing_package(cs[i], common)
            p === nothing || (extras[i] = p)
        end
    end
    return extras
end

# Which of the query's kinds took versions of `p` away, and what they left.
# Read straight off the query, so no line here needs a solver's licence; and
# named as the user's, which nothing else on the page may be.
#
# The line is the query's own fact widened like every other (`widened`), so it
# speaks of the versions redundancy elimination removed as well as the ones the
# universe still holds -- and by (D3) it allows every one of them, since a
# shadow's dominators are versions the query left and `ω` admits a shadow
# wherever all of them are admitted. A line reading the survivors alone would
# credit the compat with the resolver's deletions: for `DataFrames = "1.7"` it
# says "your compat restricts DataFrames to >=1.7.1", although 1.7.0 exists and
# that compat admits it.
function constraint_phrase(c::Conflict{P,V}, p::P, l::Line{P}) where {P,V}
    kinds = Symbol[]
    for ks in c.excluded[p], k in ks
        k in kinds || push!(kinds, k)
    end
    sort!(kinds)
    yours = your_phrases(kinds)
    lead = join(yours, " and ")
    # every verb below is regular, so agreement is one suffix
    s = length(yours) > 1 ? "" : "s"
    m = l.clause[p]
    sel = selected(m)
    any(sel) || return "$lead eliminate$s all versions of $p"
    @assert all(sel[i] for (i, _) in get(c.shadows, p, ())) """
        the line saying what the query allows $p does not allow a version \
        redundancy elimination took"""
    r = range_phrase(c.versions[p], sel)
    isempty(r) && return "$lead allow$s every version of $p"
    return "$lead restrict$s $p to $r"
end

# is this given line the requirement itself, rather than a limit on it?
is_requirement(l::Line{P}, p::P) where {P} =
    (m = l.clause[p]; m !== nothing && !absent(m) &&
     all(m[i] for i = 1:nversions(m)))

# is this line one the heading already states? The heading names the
# requirements the conflict answers for, so the body prints no line for them.
function is_heading_fact(c::Conflict{P,V}, l::Line{P}) where {P,V}
    l.given || return false
    ps = packages(l.clause)
    length(ps) == 1 || return false
    return ps[1] in c.reqs && is_requirement(l, ps[1])
end

# What the heading asserts, as lines: each requirement it names, installed at
# one of the versions the conflict speaks of it in. A requirement the conflict
# carries no versions for states nothing here — the heading is the whole of its
# story. Whatever asks what the page claims puts these beside the printed lines.
function heading_facts(c::Conflict{P,V}) where {P,V}
    out = Line{P}[]
    for p in c.reqs
        haskey(c.versions, p) || continue
        n = length(c.versions[p])
        cl = clause([p => literal(n, 1:n)])
        cl === nothing || push!(out, Line{P}(cl, P[], true))
    end
    return out
end

# One statement, said to `subject`, and read against `acc` — what the chain has
# already left the packages it argues from. Widening a literal by everything the
# chain has ruled out at that package weakens the clause, so the line stays
# true; what it prints is then the bound the reader is holding rather than the
# whole of what the statement would say standing on its own.
function line_phrase(l::Line{P}, vers, names; subject = nothing,
                     acc::Dict{P,Lit} = Dict{P,Lit}()) where {P}
    cl = l.clause
    if subject !== nothing && !isempty(acc)
        pairs = Pair{P,Lit}[]
        for (p, m) in cl.lits
            w = p != subject && haskey(acc, p) ? Lit(m.bits .| .~acc[p].bits) : m
            push!(pairs, p => (all(w.bits) ? m : w))
        end
        d = clause(pairs)
        d === nothing || (cl = d)
    end
    s = clause_phrase(cl, vers, names; subject = subject)
    isempty(l.through) && return s
    return s * " (through " * join_and(String[names(q) for q in l.through]) * ")"
end

# do these lines leave the package they meet at nothing to be? Only then may
# the page say so: two lines that agree about a package leave it something, and
# claiming otherwise would claim more than the page shows.
function meet_is_empty(group::Vector{Line{P}}, pivot) where {P}
    acc = nothing
    for l in group
        m = l.clause[pivot]
        m === nothing && return false
        acc = acc === nothing ? copy(m.bits) : (acc .& m.bits)
    end
    return acc !== nothing && !any(acc)
end

# The query's own facts of a chain, by package: the constraint the page says as
# the user's, and whatever else the reason states about that package. A
# requirement the heading names states nothing here — the heading is where it is
# said — and a fact about no single package has no place to be introduced, so it
# is kept aside and printed last.
function given_facts(c::Conflict{P,V}, given::Vector{Line{P}}) where {P,V}
    order = P[]
    con = Dict{P,Line{P}}()
    extra = Dict{P,Vector{Line{P}}}()
    loose = Line{P}[]
    for l in given
        ps = packages(l.clause)
        if length(ps) != 1
            push!(loose, l)
            continue
        end
        p = ps[1]
        is_heading_fact(c, l) && continue
        p in order || push!(order, p)
        if !haskey(con, p) && absent(l.clause[p]) && haskey(c.excluded, p)
            con[p] = l
        else
            push!(get!(Vector{Line{P}}, extra, p), l)
        end
    end
    return order, con, extra, loose
end

# The statements of the body, in the units the page says them in: each on its
# own, since a chain says one thing at a time — except a meet of three or more
# sides, which no chain can say and which prints whole. A meet of two linearizes
# always: say one side forward to the package they meet at, and the other to the
# package it rests on, which is resolving on the meet by another name.
function derived_units(derived::Vector{Line{P}}) where {P}
    units = Vector{Line{P}}[]
    i = 1
    while i ≤ length(derived)
        l = derived[i]
        j = i
        if l.pivot !== nothing
            while j < length(derived) && derived[j+1].pivot == l.pivot &&
                  derived[j+1].proof == l.proof
                j += 1
            end
        end
        if j - i + 1 ≥ 3
            push!(units, derived[i:j])
        else
            for k = i:j
                push!(units, Line{P}[derived[k]])
            end
        end
        i = j + 1
    end
    return units
end

# the packages a unit argues from — everything it names, less the package a meet
# concludes about, which is what its sides are there to bound
function unit_sources(u::Vector{Line{P}}) where {P}
    ps = P[]
    for l in u, q in packages(l.clause)
        (length(u) ≥ 2 && q == u[1].pivot) || q in ps || push!(ps, q)
    end
    return ps
end

# What a unit costs the chain, as (packages it would have to introduce from
# nowhere, whether saying it moves the chain on). A statement introduces the one
# package it is said to, so all but one of its packages must already be reached;
# a meet introduces the package it meets at, so all of its sources must be.
function unit_cost(u::Vector{Line{P}}, seen::Set{P}) where {P}
    unseen = count(q -> q ∉ seen, unit_sources(u))
    length(u) ≥ 2 && return (unseen, u[1].pivot in seen ? 1 : 0)
    return (max(unseen - 1, 0), unseen == 0 ? 1 : 0)
end

# Which package a statement is said to: the one the chain has not reached, so
# that saying it moves the chain on. Where the chain has reached all of them the
# statement closes at its own pivot, and where it has reached none the pivot
# leads — as a statement standing in no chain would.
function unit_subject(u::Vector{Line{P}}, seen::Set{P}, vers) where {P}
    length(u) ≥ 2 && return u[1].pivot
    l = only(u)
    unseen = P[q for q in packages(l.clause) if q ∉ seen]
    length(unseen) == 1 && return unseen[1]
    if isempty(unseen)
        return l.pivot === nothing ?
            Clauses.default_subject(l.clause, vers) : l.pivot
    end
    l.pivot !== nothing && l.pivot in unseen && return l.pivot
    d = Clauses.default_subject(l.clause, vers)
    return d in unseen ? d : unseen[1]
end

# the packages the body argues *from*: everything its statements name, less the
# package each of them concludes about. A chain runs from facts to the
# contradiction, so a package the statements only arrive at is where it ends
function chain_sources(units::Vector{Vector{Line{P}}}) where {P}
    ps = Set{P}()
    for u in units, l in u, q in packages(l.clause)
        q == u[1].pivot || push!(ps, q)
    end
    return ps
end

# Where a chain starts: the heading's own subject, since that is what the
# conflict is about — said as the user's compat where the reason narrowed it,
# and taken as the heading's premise where it did not. A subject the statements
# only conclude about is where the chain ends instead, which is why a source is
# preferred to it whatever the query said about either. Among sources, one the
# reason did NOT narrow is preferred: its root costs nothing to state, and it
# leaves the narrowed subject's compat line free to close the chain — a chain
# that ends "your compat restricts X to …" names the range that would have
# worked, where one that ends against the heading's silent premise names
# nothing. A subject no statement names at all roots nothing, so the choice
# falls through to whatever package the query narrowed and the statements do
# reach.
function chain_root(c::Conflict{P,V}, order::Vector{P}, con::Dict{P,Line{P}},
                    sources::Set{P}, mentioned::Set{P}) where {P,V}
    heads = heading_reqs(c)
    for pool in (sources, mentioned), narrowed in (false, true)
        for p in heads
            p in pool && (narrowed == haskey(con, p)) && return p
        end
    end
    for narrowed in (true, false), p in order
        p in mentioned && (!narrowed || haskey(con, p)) && return p
    end
    return nothing
end

function print_meet(io::IO, u::Vector{Line{P}}, vers, names) where {P}
    if meet_is_empty(u, u[1].pivot)
        println(io, "  • incompatible constraints on ", names(u[1].pivot), ":")
        for g in u
            print_wrapped(io, line_phrase(g, vers, names), "      — ", "        ")
        end
    else
        for g in u
            print_wrapped(io, line_phrase(g, vers, names), "  • ", "    ")
        end
    end
end

# The body of a conflict, as the chain it is.
#
# A statement may be said only to a package the chain has not yet reached — that
# is what makes the body an argument rather than a list — so the walk takes, at
# each step, a statement all but one of whose packages are already bounded and
# says it to the one that is not. What the statement leaves that package is what
# the next one reads against, and the query's fact about a package prints where
# the package arrives: after the statement that reaches it, before the statement
# that argues from it.
#
# Nothing follows from nothing, so the walk is seeded with a root; and a
# statement that would still need two packages introduced brings its own, the
# facts it rests on printing above it. A meet of three or more sides is that
# case twice over, and prints whole.
#
# Answers with the packages it stated the query's own facts about, in the order
# it stated them: the last of them is the fact the chain closed against.
function print_chain(io::IO, c::Conflict{P,V}, given::Vector{Line{P}},
                     derived::Vector{Line{P}}, vers, names) where {P,V}
    order, con, extra, loose = given_facts(c, given)
    units = derived_units(derived)
    sources = chain_sources(units)
    mentioned = Set{P}(q for u in units for l in u for q in packages(l.clause))
    seen = Set{P}()
    told = Set{P}()
    acc = Dict{P,Lit}()

    closers = P[]
    function tell(p::P)
        p in told && return
        push!(told, p)
        if haskey(con, p)
            print_wrapped(io, constraint_phrase(c, p, con[p]), "  • ", "    ")
            push!(closers, p)
        end
        for l in get(extra, p, Line{P}[])
            print_wrapped(io, line_phrase(l, vers, names), "  • ", "    ")
        end
    end
    function reach(p::P)
        p in seen && return
        push!(seen, p)
        tell(p)
    end

    root = chain_root(c, order, con, sources, mentioned)
    root === nothing || reach(root)

    pending = collect(eachindex(units))
    while !isempty(pending)
        k = findfirst(i -> unit_cost(units[i], seen) == (0, 0), pending)
        k === nothing &&
            (k = findfirst(i -> first(unit_cost(units[i], seen)) == 0, pending))
        k === nothing && (k = 1)
        u = units[pending[k]]
        deleteat!(pending, k)
        s = unit_subject(u, seen, vers)
        for q in unit_sources(u)
            q == s || reach(q)
        end
        if length(u) ≥ 2
            print_meet(io, u, vers, names)
        else
            print_wrapped(io, line_phrase(only(u), vers, names;
                                          subject = s, acc = acc),
                          "  • ", "    ")
        end
        if s !== nothing
            for l in u
                m = l.clause[s]
                m === nothing && continue
                acc[s] = haskey(acc, s) ? Lit(acc[s].bits .& m.bits) : m
            end
            reach(s)
        end
    end
    # a fact about a package no statement reaches ends the page rather than
    # opening it: the chain is what the reader is following
    for p in order
        tell(p)
    end
    for l in loose
        print_wrapped(io, line_phrase(l, vers, names), "  • ", "    ")
    end
    return closers
end

# What the fix gets you, of the packages the page speaks of: the reader sees the
# witness land where the opened meet says it can, which is what the versions are
# on the page for. Where the entry is one of several under a bullet, the line
# says which entry it is for; where the bullet has only the one, it does not.
function print_allows(io::IO, pkgs, sol::Dict{P,V}, indent::String;
                      prefix::String = "allows: ") where {P,V}
    ps = sort!(P[p for p in pkgs if haskey(sol, p)])
    isempty(ps) && return
    print_wrapped(io, prefix * join(String["$p $(sol[p])" for p in ps], ", "),
                  indent * "→ ", indent * "  ")
end

print_allows(io::IO, pkgs, f::Fix{P,V}, indent::String;
             prefix::String = "allows: ") where {P,V} =
    print_allows(io, pkgs, f.solution, indent; prefix)

# A menu of one has exactly three honest wordings, and which one is the whole of
# what the reader learns about the gap. Never derived from the length of a
# vector; derived from the one decided question — whether anything larger
# exists — since the conflicts do reach every repair as cheap as theirs.
function print_menu(io::IO, c::Conflict{P,V}, others::Symbol, alone::Bool,
                    sources = no_sources(P)) where {P,V}
    isempty(c.fixes) && return
    if length(c.fixes) == 1
        # "only" is a claim about the world, and it is made only where the
        # page has settled what the world holds beside this entry
        word = !alone ? "One fix" :
               others === :none ? "The only fix" :
               others === :larger ? "The only minimal fix" : "One fix"
        println(io, "  ", word, ": ", fix_phrase(c.fixes[1], sources))
        print_allows(io, keys(c.versions), c.fixes[1], "    ")
    else
        println(io, "  Fix it by any one of:")
        for (i, f) in enumerate(c.fixes)
            println(io, "    ", i, ". ", fix_phrase(f, sources))
            print_allows(io, keys(c.versions), f, "       ")
        end
    end
end

# The entries of one menu, as the choice they are. The reader has to see where
# one thing to do ends and the next begins, and an entry may ask for several
# actions at once — so where any of them does, the entries are parted by
# semicolons, which the "and" inside an entry cannot be mistaken for. Where
# every entry is a single action, commas read better and cannot mislead.
function menu_phrase(menu::Vector{Fix{P,V}}, sources = no_sources(P)) where {P,V}
    ps = String[fix_phrase(f, sources) for f in menu]
    any(f -> length(f.actions) > 1, menu) ?
        join(ps, "; ", "; or ") : join(ps, ", ", ", or ")
end

# One layer of a cover, as the choices it leaves: one bullet per menu, and
# under each entry what taking it gets you with the layer's other menus settled
# the first way they offer. A menu of one entry has nothing to distinguish, so
# its witness is said plainly; where there is a choice, each witness names the
# entry it is for.
function print_layer(io::IO, pkgs, layer::Vector{Vector{Fix{P,V}}},
                     indent::String, sources = no_sources(P)) where {P,V}
    for menu in layer
        print_wrapped(io, menu_phrase(menu, sources), indent * "• ", indent * "  ")
        for f in menu
            prefix = length(menu) == 1 ? "allows: " :
                join_and(actions_phrase(action_gerund, f.actions, sources)) *
                " allows: "
            print_allows(io, pkgs, f, indent * "  "; prefix)
        end
    end
end

# What one alternative declines. Every selection of a later layer misses some
# leading menu of its block entirely (the theory page's Lemma 31), so there is
# something to name: where each of those menus offers a single fix, the label
# says that fix as the thing it is doing without, and where one of them offers
# a choice there is no single thing to name and the label points at the
# conflicts instead. Either way the alternative replaces the menus of its own
# block only — the rest of the report stands as printed.
function alternative_label(d::Diagnosis{P,V}, a::Alternative{P,V}) where {P,V}
    isempty(a.avoided) && return "Or, to fix another way:"
    if all(i -> length(d.conflicts[i].fixes) == 1, a.avoided)
        gs = actions_phrase(action_gerund, Action{P}[
            x for i in a.avoided for x in only(d.conflicts[i].fixes).actions],
            d.sources)
        # "without A or B" is neither, where "without A and B" leaves the
        # reader to decide whether the "and" is inside the "without"
        return "Or, to fix without " * join_or(gs) * ":"
    end
    ns = String[string(i) for i in a.avoided]
    return "Or, to fix without any of the fixes for " *
        (length(ns) == 1 ? "Conflict " : "Conflicts ") * join_and(ns) * ":"
end

# One alternative: what it declines, and then what it offers instead. Its
# menus of one entry are all to be done, so they are said as one thing, joined
# by "and"; a menu with a choice is numbered like a conflict's, one witness
# under each entry, since an entry there completes the whole alternative and
# the witness is for that completion. Where the layer leaves no choice at all
# it is one line and one witness. Several menus with a choice — rare — print
# as bullets to settle, each its entries joined by "or". The versions an
# alternative speaks of are the block's, since what it is measured against is
# what the conflicts it replaces put on the page.
function print_alternative(io::IO, d::Diagnosis{P,V},
                           a::Alternative{P,V}) where {P,V}
    print_wrapped(io, alternative_label(d, a), "", "")
    pkgs = Set{P}(p for i in a.conflicts for p in keys(d.conflicts[i].versions))
    singles = Vector{Fix{P,V}}[m for m in a.menus if length(m) == 1]
    choices = Vector{Fix{P,V}}[m for m in a.menus if length(m) > 1]
    acts = unique!(Action{P}[x for m in singles for x in only(m).actions])
    joint = join_and(actions_phrase(action_phrase, acts, d.sources))
    if isempty(choices)
        print_wrapped(io, joint, "  ", "  ")
        print_allows(io, pkgs, only(first(a.menus)), "  ")
    elseif length(choices) == 1
        print_wrapped(io, isempty(singles) ? "any one of:" : joint * ", and one of:",
                      "  ", "  ")
        for (i, f) in enumerate(only(choices))
            println(io, "    ", i, ". ", fix_phrase(f, d.sources))
            print_allows(io, pkgs, f, "       ")
        end
    else
        print_wrapped(io, isempty(singles) ? "settle each of these:" :
                          joint * ", and settle each of these:", "  ", "  ")
        print_layer(io, pkgs, choices, "  ", d.sources)
    end
end

"""
    print_conflict(io, c, index = nothing; others = :some, sources = Dict())

One conflict's page: its heading (where it is numbered), the lines that prove
it, what settles it, the verdict on each action the page makes tempting and no
fix takes, and the releases someone else could cut instead. `others` is what the
whole diagnosis knows about the repairs that cost more than the ones it offers,
which is what a menu of one is entitled to say about itself; `alone` says
whether this conflict's menu is the whole of what settles its block, which an
alternative to that block denies. `also` is a package to name in the heading
beside the requirements, which a page whose heading would otherwise repeat
another's is given (`heading_extras`). `sources` is the diagnosis's: where the
query said its requirements are required from.
"""
function print_conflict(io::IO, c::Conflict{P,V}, index = nothing;
                        others::Symbol = :some, alone::Bool = true,
                        also = nothing, sources = no_sources(P)) where {P,V}
    index === nothing ||
        println(io, "Conflict ", index, ": ", conflict_heading(c, also, sources))
    vers(p) = c.versions[p]
    names(p) = string(p)
    # One chain per reason. A conflict owns one reason and prints one chain
    # for it; a further chain appears only where its menu couples actions and
    # the first reason left a package it offers unspoken of. Each is an
    # argument of its own: run together they would read as one chain that is
    # none, and a statement two of them rest on would be said twice on the way.
    # Restated inside its own chain, it is a premise; repeated in one pooled
    # walk, it is a stutter.
    for (i, n) in enumerate(unique!(Int[l.proof for l in c.lines]))
        i == 1 || println(io, "  and also:")
        print_chain(io, c, Line{P}[l for l in c.lines if l.given && l.proof == n],
                    Line{P}[l for l in c.lines if !l.given && l.proof == n],
                    vers, names)
    end
    print_menu(io, c, others, alone, sources)
    print_blocked(io, c, sources)
    print_upstream(io, c)
end

# The actions this page makes tempting and leaves out, one sentence each. The
# page's own lines are what tempt: the reader sees "your compat restricts A to
# 1.2" and asks why relaxing it is not on the menu. So the section is indexed
# by action, not by reason — nothing is said twice, and nothing tempting goes
# unanswered — and each sentence is a solve's answer rather than a judgement:
# the action is dead weight in the cheapest repair that carries it, or that
# repair's remainder is what it would cost.
#
# Printed after the menu: the reader meets the offer first and the roads not
# taken second. No proof prints here — why a fix is not offered is a
# second-order question, and the verdict has already answered it.
#
# Said as a note rather than under a heading of its own. "Blocked fixes" named
# these for what the resolver did with them, which left the reader asking what
# blocked them; nothing did, and there is nothing to unblock — they are fixes
# that do not work, and a note is what a page calls an aside that stops a
# reader acting on something it has just made look plausible.
# how many further actions an unless-sentence names before it counts them
const UNLESS_NAMED = 4

function print_blocked(io::IO, c::Conflict{P,V},
                       sources = no_sources(P)) where {P,V}
    isempty(c.blocks) && return
    # one verdict is a remark and reads as one; several want the list they are
    single = length(c.blocks) == 1
    single || println(io, "  Note:")
    for (bundles, unless) in c.blocks
        acts = Action{P}[a for b in bundles for a in b]
        tried = join_and(actions_phrase(action_gerund, acts, sources))
        # a completion turns the flat refusal into the whole truth: what it
        # would take for this road to go somewhere; several tempting actions
        # exhibiting one repair are said once, as the choice they are not --
        # each is a road, and it is only the two together that go anywhere
        # the price is named in full while it is short enough to act on, and
        # counted beyond that: a dozen further edits is a verdict on the road,
        # not a list anyone will follow, and the exhibit behind it is checked
        # whether or not it prints
        long = length(unless) > UNLESS_NAMED
        lead = if length(bundles) > 1
            roads = join_or(actions_phrase(action_gerund, acts, sources))
            quantity = length(acts) == 2 ? "both" : "all of them"
            also = isempty(unless) ? "" :
                long ? " and $(length(unless)) other changes" :
                " and also " * join_and(actions_phrase(action_past, unless, sources))
            "$roads would only help if you do $quantity$also."
        elseif isempty(unless)
            help = length(acts) > 1 ? "do not help" : "does not help"
            "$tried $help."
        elseif long
            "$tried would not help without $(length(unless)) other changes."
        else
            also = join_and(actions_phrase(action_past, unless, sources))
            "$tried would not help unless you also $also."
        end
        single ? print_wrapped(io, lead, "  Note: ", "    ") :
                 print_wrapped(io, lead, "    • ", "      ")
    end
end

# One request, said as the reader would send it: what release would fix this,
# what the latest supports instead, and what the release would get them. The
# range is the versions of the bounded package that latest does support, printed
# as any range on the page is, and the versions under it are the witness on the
# packages this conflict speaks of — the release's own package aside, since the
# sentence has just said which version of it this is about.
#
# Printed after the blocked fixes: the menu first, the roads not taken second,
# and last the road that is not the reader's to take. Nothing prints for a
# conflict with no qualifying pair, and nothing prints for a candidate the probe
# budget left untried — a sentence the page did not print, and one it would have
# had to verify before printing.
function upstream_phrase(c::Conflict{P,V}, u::Upstream{P,V}) where {P,V}
    vs = c.versions[u.dep]
    r = range_phrase(vs, Bool[w in u.supported for w in vs])
    return "a release of $(u.pkg) supporting $(u.dep) $(u.supports) would fix " *
           "this; $(u.latest), its latest, supports only $r."
end

function print_upstream(io::IO, c::Conflict{P,V}) where {P,V}
    isempty(c.upstream) && return
    pkgs(u) = P[p for p in keys(c.versions) if p != u.pkg]
    if length(c.upstream) == 1
        u = only(c.upstream)
        print_wrapped(io, "Upstream fix: " * upstream_phrase(c, u), "  ", "    ")
        print_allows(io, pkgs(u), u.solution, "    "; prefix = "would allow: ")
    else
        println(io, "  Upstream fixes:")
        for u in c.upstream
            print_wrapped(io, upstream_phrase(c, u), "    • ", "      ")
            print_allows(io, pkgs(u), u.solution, "      ";
                         prefix = "would allow: ")
        end
    end
end

# how many repairs one block offers: one entry from each of its conflicts'
# menus in every combination, and each alternative's own product besides
function nselections(d::Diagnosis, g::Vector{Int})
    n = prod(length(d.conflicts[i].fixes) for i in g; init = 1)
    for a in d.alternatives
        a.conflicts == g || continue
        n += prod(length(m) for m in a.menus; init = 1)
    end
    return n
end

function Base.show(io::IO, d::Diagnosis)
    n = length(d.conflicts)
    # the ways of repairing the whole query: one of each block's own, in every
    # combination
    f = prod(nselections(d, g) for g in conflict_blocks(d); init = 1)
    print(io, "Diagnosis: ", n, n == 1 ? " conflict, " : " conflicts, ",
          f, f == 1 ? " fix" : " fixes")
end

function Base.show(io::IO, ::MIME"text/plain", d::Diagnosis)
    n = length(d.conflicts)
    print(io, "Unsatisfiable — ", n, n == 1 ? " conflict" : " conflicts")
    # "pick a fix for each" is what the page asks of the reader: every
    # solution resolves every conflict (Theorem 9), and one entry from each
    # menu, in every combination, is a cheapest repair. It is an instruction
    # and not a claim that those are the only ones — where a block's cover
    # has more than one layer, the alternatives after the conflicts say the
    # other ways in their own words, each opening with "Or,". The one gap
    # left, an enumeration cut short, the footer below says outright.
    n > 1 && print(io, ", pick a fix for each")
    println(io, ":")
    extras = heading_extras(d.conflicts)
    # a conflict whose block has an alternative is not the whole of what
    # settles that block, so its menu of one may not say "only"
    replaced = Set{Int}(i for a in d.alternatives for i in a.conflicts)
    for (i, c) in enumerate(d.conflicts)
        println(io)
        print_conflict(io, c, i; others = d.others, alone = i ∉ replaced,
                       also = get(extras, i, nothing), sources = d.sources)
    end
    # ... and then what a block's conflicts do not reach between them, after
    # the last of them: an alternative replaces the menus of its own block and
    # nothing else, which is what its label says.
    for a in d.alternatives
        println(io)
        print_alternative(io, d, a)
    end
    # An *unless* entry exhibits a costlier fix, named — and never merely one
    # the page has printed already (Lemma 28) — so where one printed, the
    # footer that announces costlier fixes in the abstract says nothing the
    # page has not already said better (Theorems 26–27) and is left off. An
    # idle verdict exhibits no fix at all and suppresses nothing. The other
    # footer is the enumeration's own gap, and nothing else says it.
    if d.others === :larger &&
       all(c -> all(b -> isempty(b[2]) && length(b[1]) == 1, c.blocks),
           d.conflicts)
        println(io)
        println(io, "Costlier fixes also exist.")
    elseif d.others === :some
        println(io)
        println(io, "There are more minimal fixes than are shown.")
    end
    # A reason walk cut short is recorded and not announced: every conflict
    # still has a reason of its very own (Theorem 10), every fix on the page
    # is checked, and the fixes' completeness is the enumeration's question
    # above, not the walk's — so there is nothing a reader could do with the
    # sentence, and the page owes only what it can be acted on.
end

## verification

# does `sol` satisfy `c`, reading a package it does not name as absent?
function models(c::Clause{P}, sol::Dict{P,V},
                versions::Dict{P,Vector{V}}) where {P,V}
    for (p, m) in c.lits
        v = get(sol, p, nothing)
        if v === nothing
            absent(m) && return true
        else
            i = findfirst(==(v), get(versions, p, V[]))
            i === nothing || m[i] && return true
        end
    end
    return false
end

# the packages a fix's withdrawal takes the query's word about
touched(f::Fix{P,V}) where {P,V} = Set{P}(a.pkg for a in f.actions)

"""
    report_problems(d; prob = nothing, data = nothing) :: Vector{String}

Everything Section 8's checker can decide without asking the solver:

  * **(V2) visible closure** — each meet's sides really do intersect emptily,
    so the contradiction is on the page rather than behind it. What the page
    claims is its heading's requirements together with its lines, and that is
    what closes;
  * **(V3) source coverage** — every package a conflict's menu asks the reader
    to act on is named by a line, and every requirement the report answers for
    is named by its heading. An alternative repartitions repairs and not
    reasons (Corollary 25), and owes menus and witnesses only;
  * **(V5) witness coherence** — each entry's witness lands inside every line
    its own withdrawal leaves standing, in the conflicts' menus and the
    alternatives alike. Silent breakage here is invisible to every other
    check, which is exactly why this one exists;
  * **(V8) widened lines** — every line is read over the versions redundancy
    elimination removed as well as the ones the universe kept, and each such
    version's membership in each literal is the conjunction of its dominators'
    — admitted where all of them are, excluded where any of them is. With
    (D3) beside it: no shadow and no dominator is a version the query
    excludes. What is not asked here is that a line's restriction to the
    survivors is the clause the diagnosis derived, which nothing but the
    construction ever held;
  * **(Theorem 29) an exact, once-only cover** — a block's conflicts and its
    alternatives present that block's share of the cheapest repairs and
    nothing else, so no two of its selections ask for the same thing and none
    of them is inside another;
  * **(Lemma 28) blocked completions** — no *unless* entry's completion holds
    a whole repair the page has already printed. Were one inside it, taking
    the completion alone would repair and the action it excuses would be idle,
    so the entry would be exhibiting a costlier fix that is not one.
  * **(V7) upstream fixes** — each one's witness takes the package it asks a
    release of at the version the sentence calls its latest, and the package
    that release would support at the version the sentence names; and that
    package is one the query narrows and one of this conflict's own lines says
    so about. Given `prob`, the query, and `data`, the package data the release
    was tried against — a `DepsProvider` or a dict of
    `PkgData` — the rest of Section 8's check is
    decidable too: the version is really the latest, the bound the sentence
    quotes is really that version's, the witness's version of the bounded
    package really lies outside it (Lemma 32, checked rather than trusted), and
    the user's own constraint really admits the latest. Without them those four
    are left unasked, since nothing on the page can answer them.

Empty when the report is sound. The remaining obligation — that each printed
line is true of the universe this query left (V1) — is one entailment query per
line and belongs to whoever holds the instance. The disclosures (V6) are read
off the decided questions when the page is printed and have no second place to
disagree: the menu wording off Section 4's table, the enumeration-cut sentence
off the cap's own deciding solve, and the costlier-fixes footer off Theorem 5
and whether an *unless* entry has already named a costlier fix concretely.

Every check is per explanation, never against a union: where two explanations'
lines are `S₁ ∪ S₂` and `S₂` alone contradicts, the union stays contradictory
whatever is deleted from `S₁`, so a union-level check would pass a page that
silently destroyed the whole account of `S₁`.
"""
function report_problems(d::Diagnosis{P,V}; prob = nothing,
                         data = nothing) where {P,V}
    bad = String[]
    # V5 is stated against the *full* withdrawal, never the single entry: an
    # owned reason can hold other conflicts' facts, and the witness respects
    # only the sides whose supports survive everything withdrawn. So each entry
    # is judged with every other conflict settled the way its own witness was
    # taken — the first entry of each conflict's menu.
    firsts = Vector{Action{P}}[isempty(c.fixes) ? Action{P}[] :
                               first(c.fixes).actions for c in d.conflicts]
    for (n, c) in enumerate(d.conflicts)
        rest = Set{P}(a.pkg for j in eachindex(firsts) if j != n
                             for a in firsts[j])
        for s in conflict_problems(c, rest)
            push!(bad, "conflict $n: $s")
        end
    end
    # (V5 again) an alternative's entries are withdrawn beside its own layer's
    # other menus and the rest of the page, and its block's lines are what they
    # answer to — the conflicts it replaces are the ones whose story it is a
    # different ending to.
    for (n, a) in enumerate(d.alternatives)
        outside = Set{P}(x.pkg for j in eachindex(firsts) if j ∉ a.conflicts
                                for x in firsts[j])
        for (i, m) in enumerate(a.menus), f in m
            mates = Set{P}(x.pkg for (j, q) in enumerate(a.menus) if j != i
                                  for x in first(q).actions)
            gone = union(outside, mates)
            for ci in a.conflicts, s in witness_problems(f, d.conflicts[ci], gone)
                push!(bad, "alternative $n: $s")
            end
        end
    end
    # (Theorem 29) the cover is exact and says each repair once: a block's
    # conflicts and its alternatives partition that block's share of the
    # family, so no selection repeats and none is inside another — a repair
    # that was would not be as cheap as the cheapest, since every member of the
    # family has the one size.
    for g in conflict_blocks(d)
        tag = length(g) == 1 ? "conflict $(only(g))" :
              "conflicts $(join_and(String[string(i) for i in g]))"
        sels = Set{Action{P}}[Set(s) for s in block_selections(d, g)]
        for i in eachindex(sels), j in eachindex(sels)
            i == j && continue
            if sels[i] == sels[j]
                i < j && push!(bad, "$tag: offers " *
                    join_and(actions_phrase(action_phrase, sort!(
                        collect(sels[i]); by = a -> (string(a.pkg), a.kind)),
                        d.sources)) *
                    " twice")
            elseif sels[i] ⊆ sels[j]
                push!(bad, "$tag: one of the fixes offered is inside another")
            end
        end
    end
    # (Lemma 28) a completion never restates the page's own fixes: a repair
    # inside it would repair on its own, and the action it is the price of
    # would be idle instead. One containment test per printed repair — a
    # selection of every block at once — and no solver.
    groups = conflict_blocks(d)
    for (n, c) in enumerate(d.conflicts), (_, unless) in c.blocks
        isempty(unless) && continue
        u = Set{Action{P}}(unless)
        all(g -> any(s -> Set{Action{P}}(s) ⊆ u, block_selections(d, g)),
            groups) || continue
        push!(bad, "conflict $n: the completion " *
              join_and(actions_phrase(action_phrase, unless, d.sources)) *
              " repairs on its own")
    end
    # (V7) each printed request is one the page has verified: its witness takes
    # the release at the version the sentence is about and the bounded package
    # at the version it names, and the bound it drops is one of the user's own
    # facts' opposite numbers. What the registry has to answer for — that the
    # version is the latest, that the bound is what the sentence quotes, and
    # that the witness lands outside it — is asked where the data is given.
    for (n, c) in enumerate(d.conflicts)
        for s in upstream_problems(c, prob, data)
            push!(bad, "conflict $n: $s")
        end
    end
    return bad
end

# the package data for one package, from whichever shape of it the checker was
# handed — the same two `resolve` itself takes
pkg_data_of(data::DepsProvider{P}, p::P) where {P} = data.provider(p)
pkg_data_of(data::AbstractDict{P,<:PkgData{P}}, p::P) where {P} = data[p]

# (V7), of one conflict's upstream fixes
function upstream_problems(c::Conflict{P,V}, prob, data) where {P,V}
    bad = String[]
    isempty(c.upstream) && return bad
    _, con, _, _ = given_facts(c, Line{P}[l for l in c.lines if l.given])
    for u in c.upstream
        said = "the upstream fix naming $(u.pkg) $(u.latest)"
        # the witness is what the sentence claims it is
        get(u.solution, u.pkg, nothing) == u.latest ||
            push!(bad, "$said: its witness does not take $(u.pkg) $(u.latest)")
        get(u.solution, u.dep, nothing) == u.supports ||
            push!(bad, "$said: its witness does not take $(u.dep) $(u.supports)")
        # the bound it drops meets one of the user's own facts, said by a line
        # of this conflict — never another registry package's bound
        haskey(con, u.dep) ||
            push!(bad, "$said: no line of it says the query narrows $(u.dep)")
        data === nothing && continue
        pd = pkg_data_of(data, u.pkg)
        u.latest == maximum(pd.versions) ||
            push!(bad, "$said: $(u.latest) is not the latest $(u.pkg)")
        if !haskey(pd.compat, u.latest) || !haskey(pd.compat[u.latest], u.dep)
            push!(bad, "$said: $(u.pkg) $(u.latest) has no bound on $(u.dep)")
        else
            s = pd.compat[u.latest][u.dep]
            # (Lemma 32) the release helps by exactly what the sentence says
            u.supports in s &&
                push!(bad, "$said: $(u.dep) $(u.supports) is inside the bound " *
                           "the release drops")
            u.supported == V[w for w in get(c.versions, u.dep, V[]) if w in s] ||
                push!(bad, "$said: the range it names is not what " *
                           "$(u.pkg) $(u.latest) supports")
        end
        prob === nothing && continue
        # the blame is current: a release the user has excluded already exists
        is_excluded(prob, u.pkg, u.latest) &&
            push!(bad, "$said: the query does not admit $(u.pkg) $(u.latest)")
    end
    return bad
end


function conflict_problems(c::Conflict{P,V}, rest::Set{P} = Set{P}()) where {P,V}
    bad = String[]
    given = Line{P}[l for l in c.lines if l.given && !is_heading_fact(c, l)]
    append!(given, heading_facts(c))
    derived = Line{P}[l for l in c.lines if !l.given]

    # (V2) every meet closes, on its own lines and what the page says besides
    # — the query's limits, and the requirements the heading states — never on
    # another proof's
    for n in unique!(Int[l.proof for l in derived])
        mine = Line{P}[l for l in derived if l.proof == n]
        for pivot in unique(P[l.pivot for l in mine if l.pivot !== nothing])
            haskey(c.versions, pivot) || continue
            acc = trues(length(c.versions[pivot]) + 1)
            closed = false
            for l in Line{P}[mine; given]
                m = l.clause[pivot]
                if m === nothing
                    # a side stated from a support the registry cannot satisfy
                    # names no bound at the pivot: it closes on its own
                    l.given || l.pivot != pivot || (closed = true)
                else
                    acc .&= m.bits
                end
            end
            (closed || !any(acc)) && continue
            push!(bad,
                "proof $n leaves $pivot something every one of its lines admits")
        end
    end

    # (V8) every line prints over the universe the user sees. A shadow -- a
    # version redundancy elimination removed -- is admitted by a literal
    # exactly where all the versions that dominated it are admitted, so the
    # check is to recompute that bit and compare, which is set arithmetic and
    # no solver. What cannot be asked here is the other half of (V8), that a
    # line's restriction to the survivors is the clause the diagnosis derived:
    # nothing but the construction ever held that clause. And (D3) with it: a
    # shadow and its dominators are versions the query left, since the query's
    # constraints are in force when redundancy is judged.
    for (p, sh) in c.shadows
        n = length(get(c.versions, p, V[]))
        ks = get(c.excluded, p, nothing)
        for (i, ds) in sh
            said = "$p $(1 ≤ i ≤ n ? string(c.versions[p][i]) : "#$i")"
            if !(1 ≤ i ≤ n) || any(d -> !(1 ≤ d ≤ n), ds)
                push!(bad, "the shadow $said is outside the version list")
                continue
            end
            isempty(ds) &&
                push!(bad, "the shadow $said has nothing that dominated it")
            ks === nothing && continue
            isempty(ks[i]) ||
                push!(bad, "the shadow $said is a version the query excludes")
            for d in ds
                isempty(ks[d]) || push!(bad, "the shadow $said is dominated " *
                    "by $(c.versions[p][d]), which the query excludes")
            end
        end
        for l in c.lines
            m = l.clause[p]
            m === nothing && continue
            if nversions(m) != n
                push!(bad, "a line reads $p over $(nversions(m)) versions " *
                      "where the page speaks of $n")
                continue
            end
            for (i, ds) in sh
                (1 ≤ i ≤ n && all(d -> 1 ≤ d ≤ n, ds)) || continue
                m[i] == all(m[d] for d in ds) && continue
                push!(bad, "the line " *
                      line_phrase(l, q -> c.versions[q], string) *
                      " does not read $(c.versions[p][i]) as " *
                      join_and(String[string(c.versions[p][d]) for d in ds]) *
                      " leave it")
            end
        end
    end

    # (V3) the report names what it asks to be changed, and every requirement
    # it answers for — the heading names those, and a conflict's requirements
    # are its own reasons', so what is left to check is what its menu offers.
    # An alternative owes no proof (Corollary 25).
    named = Set{P}(p for l in c.lines for p in packages(l.clause))
    if !isempty(c.lines)
        for f in c.fixes, a in f.actions
            a.pkg in named || push!(bad, "offers $(a.pkg) and no line mentions it")
        end
    end

    # (V5) the witness lands where the opened meet says it can. What is held
    # out beside an entry is the rest of the page, which is the withdrawal its
    # witness was taken for.
    for f in c.fixes
        append!(bad, witness_problems(f, c, rest))
    end
    return bad
end

# (V5), of one fix against one conflict's lines: everything the withdrawal
# leaves alone — this fix's own actions, and whatever else is held out beside
# it — the witness still has to satisfy.
function witness_problems(f::Fix{P,V}, c::Conflict{P,V},
                          rest::Set{P}) where {P,V}
    bad = String[]
    isempty(f.solution) && return bad
    gone = union(touched(f), rest)
    for l in c.lines
        any(p -> p in gone, packages(l.clause)) && continue
        models(l.clause, f.solution, c.versions) && continue
        push!(bad, "the witness for " * fix_phrase(f) * " does not satisfy: " *
              line_phrase(l, p -> c.versions[p], string))
    end
    return bad
end

end # module Diagnostics
