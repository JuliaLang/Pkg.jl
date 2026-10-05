"""
    Resolver.Clauses

The statements a report is made of, and the one rule that composes them.

A **literal** on a package is a set of its versions, possibly together with ⊥
("not installed"); a **clause** carries at most one literal per package and is
satisfied when some package takes a value its literal admits. Every constraint
either actor supplies — the registry's dependency edges and compatibility
bounds, the query's requirements and its own version limits — is one clause of
this shape, and the six readings of the shape are what
[`clause_phrase`](@ref Resolver.Clauses.clause_phrase) prints.

Clauses compose by resolution on a package
([`resolve_on`](@ref Resolver.Clauses.resolve_on)): intersect that package's
literals, union every other package's. Whether a statement *forces* a package
or merely *bounds* it is whether ⊥ is in the consequent — data in the clause,
never a flag beside it — so a rule written for one reaches both, and no
direction has to be carried: a clause has none, and which way it is said is
chosen when it is said.
"""
module Clauses

export Clause, Lit, literal, packages, isbottom, subsumes,
    resolve_on, resolve_raw, resolve_all, clause_phrase

## literals

"""
    Lit(bits)

A set of values a package may take: `bits[i]` for its `i`-th version and
`bits[end]` for ⊥. The trailing slot is why `eachindex` runs one past the
version list — a literal is a subset of `V(p) ∪ {⊥}`, and ⊥ is a value like any
other.
"""
struct Lit
    bits :: BitVector # length n+1; the last slot is ⊥
end

Base.length(m::Lit) = length(m.bits)
Base.eachindex(m::Lit) = eachindex(m.bits)
Base.getindex(m::Lit, i::Integer) = m.bits[i]
Base.:(==)(a::Lit, b::Lit) = a.bits == b.bits
Base.hash(m::Lit, h::UInt) = hash(m.bits, hash(:Lit, h))
Base.show(io::IO, m::Lit) =
    print(io, "Lit(", join(Int[i for i in eachindex(m) if m[i]], ","),
          absent(m) ? "|⊥)" : ")")

# the number of versions the literal is over — one less than its length
nversions(m::Lit) = length(m.bits) - 1

# does the literal admit the package being absent?
absent(m::Lit) = m.bits[end]

# the indices of the versions the literal admits
present(m::Lit) = Int[i for i = 1:nversions(m) if m.bits[i]]

# a literal admitting nothing is no disjunct, and one admitting everything is
# no statement: the two degenerate cases `clause` drops and returns `nothing`
# for, respectively
isnull(m::Lit) = !any(m.bits)
isfull(m::Lit) = all(m.bits)

"""
    literal(n, versions, complement = false; absent = false) :: Lit

The literal on a package of `n` versions admitting `versions` (indices into its
version list), or everything but them when `complement`, together with ⊥ when
`absent`. The complement is taken over versions alone: ⊥ is put in or left out
by `absent`, whichever way the version part was named.
"""
function literal(n::Integer, versions, complement::Bool = false;
                 absent::Bool = false)
    bits = falses(n + 1)
    for i in versions
        bits[i] = true
    end
    if complement
        for i = 1:n
            bits[i] = !bits[i]
        end
    end
    bits[n+1] = absent
    return Lit(bits)
end

## clauses

"""
    Clause{P}(lits)

One statement: at most one literal per package, in package order, satisfied by
an installation that gives some package a value its literal admits. Equal
statements are `==`, which the ordering and the dropping of empty literals is
what buys.

Build one with [`clause`](@ref Resolver.Clauses.clause), which normalizes; the
constructor takes the normal form as given.
"""
struct Clause{P}
    lits :: Vector{Pair{P,Lit}}
end

Base.:(==)(a::Clause, b::Clause) = a.lits == b.lits
Base.hash(c::Clause, h::UInt) = hash(c.lits, hash(:Clause, h))

# the packages the clause speaks about, in order
packages(c::Clause{P}) where {P} = P[first(x) for x in c.lits]

# the clause's literal on `p`, or `nothing` where it says nothing about `p`
function Base.getindex(c::Clause{P}, p) where {P}
    for (q, m) in c.lits
        q == p && return m
    end
    return nothing
end

"""
    isbottom(c) :: Bool

Is `c` the empty clause — the contradiction? A clause with no literal left has
no way to be satisfied, which is what deriving one proves.
"""
isbottom(c::Clause) = isempty(c.lits)

"""
    clause(pairs) :: Union{Clause{P}, Nothing}

The clause with these literals, normalized: literals nothing can satisfy are
dropped (they are no disjunct), entries are put in package order so that equal
statements are `==`, and repeated packages are merged by union. `nothing` when
some package's literal admits everything — the clause is then a tautology, and
a tautology is not a statement.
"""
function clause(pairs::AbstractVector{<:Pair{P,Lit}}) where {P}
    out = Pair{P,Lit}[]
    for (p, m) in pairs
        k = findfirst(x -> first(x) == p, out)
        if k === nothing
            push!(out, p => m)
        else
            out[k] = p => Lit(out[k][2].bits .| m.bits)
        end
    end
    any(x -> isfull(last(x)), out) && return nothing
    filter!(x -> !isnull(last(x)), out)
    sort!(out; by = first)
    return Clause{P}(out)
end

"""
    subsumes(c, d) :: Bool

Does `c` say at least as much as `d` — `c(p) ⊆ d(p)` at every package? Then
every model of `c` models `d`, so printing both says nothing the stronger one
did not.
"""
function subsumes(c::Clause{P}, d::Clause{P}) where {P}
    for (p, m) in c.lits
        n = d[p]
        n === nothing && return false
        any(m.bits .& .~n.bits) && return false
    end
    return true
end

"""
    resolve_raw(clauses, q) :: Union{Clause{P}, Nothing}

The resolvent of `clauses` on `q`: `q`'s literal is their intersection, every
other package's their union. Sound whatever the clauses are — a model of all of
them models the resolvent — so everything derived inherits soundness rather
than re-establishing it. `nothing` when the result is a tautology.

A clause not mentioning `q` contributes the empty literal there, as it should:
saying nothing about `q` is saying `q` can be nothing.
"""
function resolve_raw(clauses, q)
    P = typeof(q)
    acc = Dict{P,BitVector}()
    order = P[]
    qbits = nothing
    for c in clauses
        m = c[q]
        b = m === nothing ? nothing : copy(m.bits)
        if qbits === nothing
            qbits = b
        elseif b === nothing
            fill!(qbits, false)
        else
            qbits .&= b
        end
        for (p, l) in c.lits
            p == q && continue
            if haskey(acc, p)
                acc[p] .|= l.bits
            else
                acc[p] = copy(l.bits)
                push!(order, p)
            end
        end
    end
    qbits === nothing && return nothing
    out = Pair{P,Lit}[q => Lit(qbits)]
    for p in order
        push!(out, p => Lit(acc[p]))
    end
    return clause(out)
end

"""
    resolve_on(c, d, q) :: Union{Clause{P}, Nothing}

The resolvent of two clauses on `q`, where there is progress to be had:
`nothing` when either says nothing about `q`, when the intersection at `q` is
no smaller than a parent's literal — the resolvent is then that parent,
weakened, and a weakening is not a derivation — or when what comes out is a
tautology.
"""
function resolve_on(c::Clause{P}, d::Clause{P}, q::P) where {P}
    a, b = c[q], d[q]
    (a === nothing || b === nothing) && return nothing
    inter = Lit(a.bits .& b.bits)
    (inter == a || inter == b) && return nothing
    return resolve_raw((c, d), q)
end

"""
    resolve_all(clauses, q) :: Union{Clause{P}, Nothing}

[`resolve_raw`](@ref Resolver.Clauses.resolve_raw) over a whole family at once,
declining the same two non-derivations [`resolve_on`](@ref
Resolver.Clauses.resolve_on) declines. Stated for families because literals are
sets: three of them can have empty intersection while every two overlap, so
pairs do not suffice to empty a package.
"""
function resolve_all(clauses, q)
    isempty(clauses) && return nothing
    r = resolve_raw(clauses, q)
    r === nothing && return nothing
    m = r[q]
    for c in clauses
        a = c[q]
        a !== nothing && m == a && return nothing
    end
    return r
end

## saying it in English

"""
    letters(p) :: String

A package's name. Integers name themselves in spreadsheet columns — `1` is
`A`, `27` is `AA` — so that a test can write packages and versions as
different kinds of thing and have a wrong assertion look wrong.
"""
letters(p) = string(p)

function letters(i::Integer)
    s = ""
    while i > 0
        i, r = divrem(i - 1, 26)
        s = string('A' + r) * s
    end
    return s
end

"""
    version_order(versions) :: Int

Which way a package's version list runs: `1` ascending, `-1` descending, `0`
neither. A range prints as `≤v` or `≥v` only where one end of the list is
known to be one end of the order; where it is not, the versions are named.
"""
function version_order(vs::AbstractVector{V}) where {V}
    n = length(vs)
    n < 2 && return 0
    hasmethod(isless, Tuple{V,V}) || return 0
    all(i -> isless(vs[i], vs[i+1]), 1:n-1) && return 1
    all(i -> isless(vs[i+1], vs[i]), 1:n-1) && return -1
    return 0
end

# the maximal runs of indices `sel` selects
function selected_runs(sel::AbstractVector{Bool})
    out = UnitRange{Int}[]
    n = length(sel)
    i = 1
    while i ≤ n
        if sel[i]
            lo = i
            while i < n && sel[i+1]
                i += 1
            end
            push!(out, lo:i)
        end
        i += 1
    end
    return out
end

# one run, said as the narrowing it is: a run touching an end of the order is
# the inequality that end names, an interior one names both its ends, and a
# single version names itself
function run_phrase(vs, r::UnitRange{Int}, dir::Int)
    n = length(vs)
    length(r) == 1 && return string(vs[first(r)])
    dir == 0 && return join((string(vs[i]) for i in r), ", ")
    if first(r) == 1
        return (dir == 1 ? "≤" : "≥") * string(vs[last(r)])
    elseif last(r) == n
        return (dir == 1 ? "≥" : "≤") * string(vs[first(r)])
    else
        lo, hi = dir == 1 ? (first(r), last(r)) : (last(r), first(r))
        return string(vs[lo]) * "–" * string(vs[hi])
    end
end

"""
    range_phrase(vs, sel) :: String

The versions `sel` picks out of `vs`, low to high. The empty string where `sel`
is everything: a range that is the package's whole offering prints as the bare
package name, since naming it in full reads as a narrowing that never happened.

One version is not a range, and the same reasoning does not reach it. Where the
offering is a single version, saying which one identifies what the line speaks
of and claims nothing about having selected it -- and the line is otherwise left
naming no version at all, which is the harder thing to read: "julia constrains
Statistics" leaves the reader to work out which julia.
"""
function range_phrase(vs, sel::AbstractVector{Bool}, dir::Int = version_order(vs))
    rs = selected_runs(sel)
    isempty(rs) && return ""
    length(rs) == 1 && first(rs) == 1:length(vs) && length(vs) > 1 && return ""
    dir == -1 && reverse!(rs)
    return join((run_phrase(vs, r, dir) for r in rs), ", ")
end

# the version part of a literal, and of its complement, as selection vectors
selected(m::Lit) = Bool[m[i] for i = 1:nversions(m)]
unselected(m::Lit) = Bool[!m[i] for i = 1:nversions(m)]

# "the package, held where the literal does not reach" — the condition under
# which a clause's other literals have to carry it. A literal that admits ⊥ is
# denied by a version; one that does not is denied by absence too, and says so.
function antecedent_phrase(q, m::Lit, vers, names)
    vs = vers(q)
    sel = unselected(m)
    r = range_phrase(vs, sel)
    if absent(m)
        return isempty(r) ? names(q) : "$(names(q)) $r"
    else
        any(sel) || return "$(names(q)) absent"
        return isempty(r) ? names(q) : "$(names(q)) $r or absent"
    end
end

# "the package, held where the literal does reach" — what the statement leaves
# it, printed with no verb: the verb is read off ⊥ by the caller, which also
# says how it joins. A bare name takes no joiner: there is no range for it to
# reach, and *constrains B to* with nothing after it is not a sentence.
function consequent_phrase(s, m::Lit, vers, names, joiner = " ")
    vs = vers(s)
    r = range_phrase(vs, selected(m))
    return isempty(r) ? names(s) : "$(names(s))$joiner$r"
end

# Which package a two-or-more-package statement is said *to*. A clause has no
# direction, so one is chosen here: the side that must be installed declares
# the edge where exactly one does, and among readings equally free of that, the
# one whose consequent has versions to name — a consequent with an empty range
# prints shortest and says least, and choosing it throws away the very bound the
# reader was about to hold against another. What is left is broken toward the
# later package, so that the same clause always reads the same way.
function default_subject(c::Clause{P}, vers) where {P}
    best = nothing
    bestkey = (true, true)
    for (p, m) in c.lits
        key = (absent(m), !any(selected(m)))
        if best === nothing || key ≤ bestkey
            best, bestkey = p, key
        end
    end
    return best
end

"""
    clause_phrase(c, vers, names = letters; subject = nothing) :: String

The clause as one English sentence. `vers` maps a package to its version list
and `names` to its name; `subject` names the package to say the statement *to*,
which is otherwise chosen (see `default_subject`).

Six readings of one shape cover everything a report says: a package that must
be installed, a package a range of which cannot be, and — with two or more
literals — one package's versions requiring another's, constraining another's,
or leaving another none at all. Which verb is not a flag: *requires* is a
consequent that excludes ⊥ and so brings the package in, *constrains* one that
admits it and so binds only if it is there, and *allows no version of* one that
admits ⊥ alone. So a statement said the other way round re-derives its own
verb, which is what makes contraposition safe to print.
"""
function clause_phrase(c::Clause{P}, vers, names = letters;
                       subject = nothing) where {P}
    isbottom(c) && return "nothing can be installed"
    ps = packages(c)
    if length(ps) == 1
        p = ps[1]
        m = c.lits[1][2]
        vs = vers(p)
        if absent(m)
            sel = unselected(m)
            all(sel) && return "no version of $(names(p)) can be installed"
            return "$(names(p)) $(range_phrase(vs, sel)) cannot be installed"
        else
            r = range_phrase(vs, selected(m))
            isempty(r) && return "$(names(p)) must be installed"
            return "$(names(p)) must be installed at $r"
        end
    end
    s = subject === nothing ? default_subject(c, vers) : subject
    c[s] === nothing && (s = default_subject(c, vers))
    ants = String[antecedent_phrase(q, c[q], vers, names) for q in ps if q != s]
    m = c[s]
    plural = length(ants) > 1
    lead = plural ? join(ants, ", ", " and ") * " together" : ants[1]
    # a consequent with no version in it is no range to name: what the
    # statement leaves the package is nothing, and the bare name would read as
    # the package arriving rather than as its going
    any(selected(m)) ||
        return "$lead $(plural ? "allow" : "allows") no version of $(names(s))"
    # *constrains* takes "to", as the query's *restricts* does: both name a
    # bound on a package rather than a version of it to install, which is what
    # *requires* names and why that one reads right with no preposition
    verb = absent(m) ? (plural ? "constrain" : "constrains") :
                       (plural ? "require" : "requires")
    joiner = absent(m) ? " to " : " "
    return "$lead $verb $(consequent_phrase(s, m, vers, names, joiner))"
end

end # module Clauses
