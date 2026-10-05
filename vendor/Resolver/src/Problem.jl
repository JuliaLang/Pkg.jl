# An empty dictionary that costs nothing to make: a singleton, since it has no
# fields. Constructing an unconstrained `Problem` — which every convenience
# `resolve` entry point does — must not allocate a pair of dictionaries just to
# say "no constraints", and the filter must not allocate a mask dictionary per
# round just to say "no masks".
struct EmptyDict{K,V} <: AbstractDict{K,V} end

Base.length(::EmptyDict) = 0
Base.iterate(::EmptyDict, state...) = nothing
Base.haskey(::EmptyDict, key) = false
Base.get(::EmptyDict, key, default) = default
Base.getindex(::EmptyDict, key) = throw(KeyError(key))

# What a constraint is made of matters only where it is built. Everywhere else
# it answers two questions: does it forbid this version of this package, and
# which packages does it speak about — `nothing` for one that speaks about every
# package, a predicate having no way to list them.
struct Constraint{P}
    forbids :: Any                     # (p, v) -> Bool
    named   :: Union{Nothing, Set{P}}  # the packages it names, or every package
end

"""
    Problem(reqs; compat = ..., pin = ..., \$kind = ...)

A resolution problem: the required packages `reqs`, plus the constraints that say
which versions are admissible. A `Problem` carries everything that determines
*satisfiability*; orderings (the `by` priority order, the `order` version rank
order) are `resolve` parameters instead.

`reqs` may instead be `pkg => sources` pairs, `sources` naming where `pkg` is
required from — the `Project.toml` files of a workspace, say. Satisfiability
does not depend on it; a report does, since the fix that drops the requirement
can then say where ("drop dependency X (a/Project.toml:12)"). A source is
printed as given, so `path:line` is what an editor opens.

Every keyword is a constraint, and its name is the constraint's *kind*:

  * `compat`: per package, the set of allowed versions (queried with `in`).
  * any of these from a named source ([`sourced_kind`](@ref
    Resolver.sourced_kind)): the same constraint, declared in one of several
    places — a workspace member's `Project.toml`, say — so that a report can
    say which one to relax, and where. Passed as a pair, since the name is not
    an identifier: `Problem(reqs; sourced_kind(:compat, "a/Project.toml") => d)`.
  * `pin`: per package, the one version it is held at.
  * anything else: a predicate `(p, v) -> Bool`, true for the versions that kind
    forbids — "no prereleases" is the one the resolver's own tooling uses. These
    speak about versions rather than about particular packages, so they reach
    every package.

Two constraints cannot share a kind, which needs no checking: a repeated
keyword is a syntax error.

Constraints for packages that don't exist, and constraints that exclude nothing,
are allowed and have no effect.

Every constraint here is a constraint on a *shared* package universe rather than
a deletion from a private one: that is what lets a single T1 artifact (see
[`pkg_info`](@ref Resolver.pkg_info)) serve queries that admit different things,
and what lets diagnostics eventually name the kind that ruled a version out.
"""
struct Problem{P, C<:AbstractDict{Symbol}, S<:AbstractDict{P,Vector{String}}}
    reqs :: Vector{P}
    # the constraints, by kind. Typed as a parameter so that an unconstrained
    # problem can share one immutable empty dictionary rather than make one
    constraints :: C
    # where each requirement is required from, for the ones the query said.
    # A parameter for the same reason: a query that said nothing, which is
    # every convenience `resolve`, shares the empty map rather than making one
    sources :: S
end

Problem(reqs::Vector{P}, constraints::AbstractDict{Symbol}) where {P} =
    Problem(reqs, constraints, EmptyDict{P,Vector{String}}())

# A kind can carry the place it was declared after an `@`: `compat@a/Project.toml`
# is that file's compat. A kind is a symbol wherever it goes — a report is plain
# data, and a caller rebuilding one over its own package names keeps the kinds
# as they are — so the source rides inside the symbol, and `kind_base` and
# `kind_source` read the halves back.
const SOURCE_SEP = '@'

"""
    sourced_kind(base, source) :: Symbol

The kind of a constraint of kind `base` declared at `source`: what a query
passes when constraints of one kind come from several places and a report
should say which one to relax, and where — "relax your compat on X
(a/Project.toml:12)". A `Problem` takes such a kind exactly as it takes `base`,
and each place is a constraint of its own, so a fix asks to relax exactly the
ones that exclude what it needs. The source is printed as given, so `path:line`
is what an editor opens. [`kind_base`](@ref Resolver.kind_base) and
[`kind_source`](@ref Resolver.kind_source) read the halves back.
"""
sourced_kind(base::Symbol, source::AbstractString) = Symbol(base, SOURCE_SEP, source)

# The bare kinds carry no source, and are answered by identity before the
# symbol is read as a string: reading it allocates, `check_constraints` asks
# for every kind of every `Problem`, and an unconstrained problem is promised
# to cost its vector and its struct and nothing else
const BARE_KINDS = (:compat, :pin, :drop)

"""
    kind_base(kind) :: Symbol

The kind a [`sourced_kind`](@ref Resolver.sourced_kind) was made from; any
other kind is its own base.
"""
function kind_base(kind::Symbol)
    kind in BARE_KINDS && return kind
    s = String(kind)
    i = findfirst(==(SOURCE_SEP), s)
    return i === nothing ? kind : Symbol(SubString(s, 1, prevind(s, i)))
end

"""
    kind_source(kind) :: Union{Nothing, String}

The source a [`sourced_kind`](@ref Resolver.sourced_kind) was made from, or
`nothing` for a kind declared in the one place there is.
"""
function kind_source(kind::Symbol)
    kind in BARE_KINDS && return nothing
    s = String(kind)
    i = findfirst(==(SOURCE_SEP), s)
    return i === nothing ? nothing : String(SubString(s, nextind(s, i)))
end

# the three ways to build one. A caller's dictionary is copied, so later
# mutation cannot change the problem
constraint(::Type{P}, ::Val{:compat}, d::AbstractDict) where {P} =
    (e = Dict(d); Constraint{P}(
        (p, v) -> (s = get(e, p, nothing); s !== nothing && v ∉ s), Set{P}(keys(e))))
constraint(::Type{P}, ::Val{:pin}, d::AbstractDict) where {P} =
    (e = Dict(d); Constraint{P}(
        (p, v) -> (w = get(e, p, nothing); w !== nothing && v != w), Set{P}(keys(e))))
# a sourced kind is built as its base is: the source changes what the report
# says, not what the constraint does
function constraint(::Type{P}, ::Val{K}, value) where {P,K}
    base = kind_base(K)
    return base === K ? Constraint{P}(value, nothing) : constraint(P, Val(base), value)
end

# this constraint no longer applying to `pkgs`, or `nothing` when nothing of it
# is left — so relaxing a kind for the packages it names relaxes it entirely,
# whatever its shape, and `nothing` never has to mean two things
relax(::Constraint, ::Nothing) = nothing
function relax(c::Constraint{P}, pkgs) where {P}
    isempty(pkgs) && return c
    names = c.named === nothing ? nothing : setdiff(c.named, pkgs)
    names !== nothing && isempty(names) && return nothing
    forbids = c.forbids
    return Constraint{P}((p, v) -> p ∉ pkgs && forbids(p, v)::Bool, names)
end

# `compat` and `pin` are dictionaries keyed by package, from whatever source;
# every other kind is a predicate. Checked once, here, so that nothing
# downstream has to look.
function check_constraints(::Type{P}, kinds::NamedTuple) where {P}
    for (kind, value) in pairs(kinds)
        want = kind_base(kind) in (:compat, :pin) ?
            (value isa AbstractDict{P} ? nothing : "a dictionary keyed by package ($P)") :
            (isempty(methods(value)) ? "a predicate, `(p, v) -> Bool`" : nothing)
        want === nothing || throw(ArgumentError(
            "constraint kind $(repr(kind)) wants $want; got a $(typeof(value))"))
    end
end

function Problem(reqs::SetOrVec{P}; kinds...) where {P}
    kws = values(kinds)
    check_constraints(P, kws)
    r = P[p for p in reqs]
    # a kind that forbids nothing is no constraint, and the map is made only
    # once there is one to put in it, so a problem that constrains nothing
    # shares the empty map whether it named no kind or only empty ones
    cs = nothing
    for (kind, value) in pairs(kws)
        value isa AbstractDict && isempty(value) && continue
        cs === nothing && (cs = Dict{Symbol,Constraint{P}}())
        cs[kind] = constraint(P, Val(kind), value)
    end
    return Problem(r, something(cs, EmptyDict{Symbol,Constraint{P}}()))
end

# the requirements with where each is required from: the same problem, which
# remembers the sources for the report
function Problem(reqs::AbstractVector{<:Pair{P}}; kinds...) where {P}
    prob = Problem(P[first(r) for r in reqs]; kinds...)
    sources = Dict{P,Vector{String}}()
    for (p, srcs) in reqs
        union!(get!(Vector{String}, sources, p), String[String(s) for s in srcs])
    end
    filter!(kv -> !isempty(last(kv)), sources)
    isempty(sources) && return prob
    return Problem(prob.reqs, prob.constraints, sources)
end

# `prob` no longer requiring `drop_reqs`, nor applying each constraint in
# `drop_constraints` to the packages named there — a relaxation being the same problem
# with demands lifted, and so built by lifting them
function relax(
    prob      :: Problem{P},
    drop_reqs        :: SetOrVec{P},
    drop_constraints :: AbstractDict{Symbol},
) where {P}
    gone = Set{P}(drop_reqs)
    cs = Dict{Symbol,Constraint{P}}()
    for (kind, c) in prob.constraints
        c′ = haskey(drop_constraints, kind) ? relax(c, drop_constraints[kind]) : c
        c′ === nothing || (cs[kind] = c′)
    end
    r = P[p for p in prob.reqs if p ∉ gone]
    srcs = Dict{P,Vector{String}}(p => s for (p, s) in prob.sources if p ∉ gone)
    return Problem(r, isempty(cs)   ? EmptyDict{Symbol,Constraint{P}}() : cs,
                      isempty(srcs) ? EmptyDict{P,Vector{String}}()     : srcs)
end

# does the problem constrain anything at all? the fast paths below lean on this:
# an unconstrained resolve must not do any per-version work
is_constrained(prob::Problem) = !isempty(prob.constraints)

# What a user constraint does, and the only thing it does, is forbid *members*
# of interchangeability classes. Members are indistinguishable to everything in
# the registry, so forbidding some of them changes nothing a class can be asked
# to do — unless it forbids all of them, and then the class is empty and cannot
# be selected. Nothing of a constraint therefore appears in a conflict matrix.
# Constraints are evaluated once, here, into the per-version masks below;
# `class_ranking` turns those into each class's representative; and a class left
# without one is deactivated in the universe (see `Universe`), which is a single
# relaxable unit clause in the SAT instance and one degradation trigger in the
# filter.
#
# The consequence worth naming: a constraint cannot make two versions'
# constraint rows identical, because it does not touch the rows — and versions
# whose rows *are* identical are one class sharing one column, so there is no
# pair of separately-deletable objects for a partial relaxation to fall
# between.

# does the problem forbid version v of package p?
is_excluded(prob::Problem{P}, p::P, v) where {P} =
    any(c -> c.forbids(p, v)::Bool, values(prob.constraints))

# Which of the problem's constraints forbid version `v` of package `p`: one
# symbol per source that does — `:compat` for an allowed-version set the version
# is not in, `:pin` for a pin at another version, and its own symbol for each
# admission kind whose predicate holds — in that order, and empty when the
# problem admits the version. Every source is named, where `is_excluded` stops
# at the first: lifting one source leaves the others in force, so what a
# question about lifting one needs is all of them.
exclusion_kinds(prob::Problem{P}, p::P, v) where {P} =
    sort!(Symbol[k for (k, c) in prob.constraints if c.forbids(p, v)::Bool])

# Why class `c` of package `p` holds nothing this problem admits: the class's
# members in version order, each paired with the sources that exclude it
# (`exclusion_kinds`). A constraint forbids versions, and a class is empty
# when every member of it is forbidden — so the class is empty exactly when no
# pair here has an empty source list, and these pairs are then the whole of what
# emptied it: which versions the class holds, and what rules each one out.
#
# Constraints and the partition are all this reads; no solver is involved.
function class_exclusions(
    prob   :: Problem{P},
    p      :: P,
    info_p,        # `p`'s PkgInfo (declared after this file)
    c      :: Integer,
) where {P}
    vers = info_p.versions
    return [vers[i] => exclusion_kinds(prob, p, vers[i])
            for i in info_p.members[c]]
end

# the packages a constraint could forbid a version of: the ones its constraints
# name, unless one of them speaks about every package
function exclusion_candidates(info::AbstractDict{P}, prob::Problem{P}) where {P}
    pkgs = Set{P}()
    for c in values(prob.constraints)
        c.named === nothing && return keys(info)
        union!(pkgs, c.named)
    end
    return pkgs
end

"""
    exclusion_masks(info, prob) :: AbstractDict{P, BitVector}

The versions of each package that `prob`'s constraints forbid, as a mask over
that package's version list in `info`. Only packages with a constraint that
actually excludes something get an entry, so packages nothing constrains — the
overwhelming majority, absent an admission knob — cost nothing downstream.

This is the only place a constraint is ever evaluated, and what reads it is
[`class_ranking`](@ref Resolver.class_ranking), which turns it into
representatives. Masks are index-based, so they are read against the version
list they were built from.
"""
function exclusion_masks(
    info :: AbstractDict{P}, # a PkgInfo dict (declared before PkgInfo)
    prob :: Problem{P},
) where {P}
    is_constrained(prob) || return EmptyDict{P,BitVector}()
    excl = Dict{P,BitVector}()
    for p in exclusion_candidates(info, prob)
        haskey(info, p) || continue # constraint on an absent package
        vers = info[p].versions
        e = falses(length(vers))
        any = false
        for (i, v) in enumerate(vers)
            is_excluded(prob, p, v) || continue
            e[i] = true
            any = true
        end
        any && (excl[p] = e) # allow-everything entries get no mask
    end
    return excl
end
