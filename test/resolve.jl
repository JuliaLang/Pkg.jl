# This file is a part of Julia. License is MIT: https://julialang.org/license

module ResolveTest

using ..Test
using Pkg3.Types
using Pkg3.Query
using Pkg3.Resolve
using Pkg3.Resolve.VersionWeights
import Pkg3.Types: uuid5, uuid_package

# Check that VersionWeight keeps the same ordering as VersionNumber

vlst = [
    v"0.0.0",
    v"0.0.1",
    v"0.1.0",
    v"0.1.1",
    v"1.0.0",
    v"1.0.1",
    v"1.1.0",
    v"1.1.1"
    ]

for v1 in vlst, v2 in vlst
    vw1 = VersionWeight(v1)
    vw2 = VersionWeight(v2)
    clt = v1 < v2
    @test clt == (vw1 < vw2)
    ceq = v1 == v2
    @test ceq == (vw1 == vw2)
end

# TODO: check that these are unacceptable for VersionSpec
vlst_invalid = [
    v"1.0.0-pre",
    v"1.0.0-pre1",
    v"1.0.1-pre",
    v"1.0.0-0.pre.2",
    v"1.0.0-0.pre.3",
    v"1.0.0-0.pre1.tst",
    v"1.0.0-pre.1+0.1",
    v"1.0.0-pre.1+0.1plus",
    v"1.0.0-pre.1-+0.1plus",
    v"1.0.0-pre.1-+0.1Plus",
    v"1.0.0-pre.1-+0.1pLUs",
    v"1.0.0-pre.1-+0.1pluS",
    v"1.0.0+0.1plus",
    v"1.0.0+0.1plus-",
    v"1.0.0+-",
    v"1.0.0-",
    v"1.0.0+",
    v"1.0.0--",
    v"1.0.0---",
    v"1.0.0--+-",
    v"1.0.0+--",
    v"1.0.0+-.-",
    v"1.0.0+0.-",
    v"1.0.0+-.0",
    v"1.0.0-a+--",
    v"1.0.0-a+-.-",
    v"1.0.0-a+0.-",
    v"1.0.0-a+-.0"
    ]


# auxiliary functions
pkguuid(p::String) = uuid5(uuid_package, p)
function storeuuid(p::String, uuid_to_name::Dict{UUID,String})
    uuid = pkguuid(p)
    if haskey(uuid_to_name, uuid)
        @assert uuid_to_name[uuid] == p
    else
        uuid_to_name[uuid] = p
    end
    return uuid
end
wantuuids(want_data) = Dict{UUID,VersionNumber}(pkguuid(p) => v for (p,v) in want_data)

function deps_from_data(deps_data, uuid_to_name = Dict{UUID,String}())
    deps = DepsGraph()
    uuid(p) = storeuuid(p, uuid_to_name)
    for d in deps_data
        p, vn, r = uuid(d[1]), d[2], d[3:end]
        if !haskey(deps, p)
            deps[p] = Dict{VersionNumber,Requires}()
        end
        if !haskey(deps[p], vn)
            deps[p][vn] = Dict{UUID,VersionSpec}()
        end
        isempty(r) && continue
        rp = uuid(r[1])
        rvs = VersionSpec(r[2:end])
        deps[p][vn][rp] = rvs
    end
    deps, uuid_to_name
end
function reqs_from_data(reqs_data, uuid_to_name = Dict{UUID,String}())
    reqs = Dict{UUID,VersionSpec}()
    uuid(p) = storeuuid(p, uuid_to_name)
    for r in reqs_data
        p = uuid(r[1])
        reqs[p] = VersionSpec(r[2:end])
    end
    reqs, uuid_to_name
end
function sanity_tst(deps_data, expected_result; pkgs=[])
    deps, uuid_to_name = deps_from_data(deps_data)
    id(p) = pkgID(pkguuid(p), uuid_to_name)
    #println("deps=$deps")
    #println()
    result = sanity_check(deps, uuid_to_name, Set(pkguuid(p) for p in pkgs))
    length(result) == length(expected_result) || return false
    expected_result_uuid = [(id(p), vn) for (p,vn) in expected_result]
    for (p, vn, pp) in result
        (p, vn) ∈ expected_result_uuid || return  false
    end
    return true
end
sanity_tst(deps_data; kw...) = sanity_tst(deps_data, []; kw...)

function resolve_tst(deps_data, reqs_data, want_data = nothing)
    deps, uuid_to_name = deps_from_data(deps_data)
    reqs, uuid_to_name = reqs_from_data(reqs_data, uuid_to_name)

    #println()
    #println("deps=$deps")
    #println("reqs=$reqs")
    deps = Query.prune_dependencies(reqs, deps, uuid_to_name)
    want = resolve(reqs, deps, uuid_to_name)
    return want == wantuuids(want_data)
end

## DEPENDENCY SCHEME 1: TWO PACKAGES, DAG
deps_data = Any[
    ["A", v"1", "B", "1-*"],
    ["A", v"2", "B", "2-*"],
    ["B", v"1"],
    ["B", v"2"]
]

@test sanity_tst(deps_data)
@test sanity_tst(deps_data, pkgs=["A", "B"])
@test sanity_tst(deps_data, pkgs=["B"])
@test sanity_tst(deps_data, pkgs=["A"])

# require just B
reqs_data = Any[
    ["B", "*"]
]

want_data = Dict("B"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just A: must bring in B
reqs_data = Any[
    ["A", "*"]
]
want_data = Dict("A"=>v"2", "B"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)


## DEPENDENCY SCHEME 2: TWO PACKAGES, CYCLIC
deps_data = Any[
    ["A", v"1", "B", "2-*"],
    ["A", v"2", "B", "1-*"],
    ["B", v"1", "A", "2-*"],
    ["B", v"2", "A", "1-*"]
]

@test sanity_tst(deps_data)

# require just A
reqs_data = Any[
    ["A", "*"]
]
want_data = Dict("A"=>v"2", "B"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just B, force lower version
reqs_data = Any[
    ["B", "1"]
]
want_data = Dict("A"=>v"2", "B"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just A, force lower version
reqs_data = Any[
    ["A", "1"]
]
want_data = Dict("A"=>v"1", "B"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)


## DEPENDENCY SCHEME 3: THREE PACKAGES, CYCLIC, TWO MUTUALLY EXCLUSIVE SOLUTIONS
deps_data = Any[
    ["A", v"1", "B", "2-*"],
    ["A", v"2", "B", "1"],
    ["B", v"1", "C", "2-*"],
    ["B", v"2", "C", "1"],
    ["C", v"1", "A", "1"],
    ["C", v"2", "A", "2-*"]
]

@test sanity_tst(deps_data)

# require just A (must choose solution which has the highest version for A)
reqs_data = Any[
    ["A", "*"]
]
want_data = Dict("A"=>v"2", "B"=>v"1", "C"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just B (must choose solution which has the highest version for B)
reqs_data = Any[
    ["B", "*"]
]
want_data = Dict("A"=>v"1", "B"=>v"2", "C"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just A, force lower version
reqs_data = Any[
    ["A", "1"]
]
want_data = Dict("A"=>v"1", "B"=>v"2", "C"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)

# require A and C, incompatible versions
reqs_data = Any[
    ["A", "1"],
    ["C", "2-*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)


## DEPENDENCY SCHEME 4: TWO PACKAGES, DAG, WITH TRIVIAL INCONSISTENCY
deps_data = Any[
    ["A", v"1", "B", "2-*"],
    ["B", v"1"]
]

@test sanity_tst(deps_data, [("A", v"1")])
@test sanity_tst(deps_data, [("A", v"1")], pkgs=["B"])

# require B (must not give errors)
reqs_data = Any[
    ["B", "*"]
]
want_data = Dict("B"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)


## DEPENDENCY SCHEME 5: THREE PACKAGES, DAG, WITH IMPLICIT INCONSISTENCY
deps_data = Any[
    ["A", v"1", "B", "2-*"],
    ["A", v"1", "C", "2-*"],
    ["A", v"2", "B", "1"],
    ["A", v"2", "C", "1"],
    ["B", v"1", "C", "2-*"],
    ["B", v"2", "C", "2-*"],
    ["C", v"1"],
    ["C", v"2"]
]

@test sanity_tst(deps_data, [("A", v"2")])
@test sanity_tst(deps_data, [("A", v"2")], pkgs=["B"])
@test sanity_tst(deps_data, [("A", v"2")], pkgs=["C"])

# require A, any version (must use the highest non-inconsistent)
reqs_data = Any[
    ["A", "*"]
]
want_data = Dict("A"=>v"1", "B"=>v"2", "C"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require A, force highest version (impossible)
reqs_data = Any[
    ["A", "2-*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)


## DEPENDENCY SCHEME 6: TWO PACKAGES, CYCLIC, TOTALLY INCONSISTENT
deps_data = Any[
    ["A", v"1", "B", "2-*"],
    ["A", v"2", "B", "1"],
    ["B", v"1", "A", "1"],
    ["B", v"2", "A", "2-*"]
]

@test sanity_tst(deps_data, [("A", v"1"), ("A", v"2"),
                             ("B", v"1"), ("B", v"2")])

# require A (impossible)
reqs_data = Any[
    ["A", "*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)

# require B (impossible)
reqs_data = Any[
    ["B", "*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)


## DEPENDENCY SCHEME 7: THREE PACKAGES, CYCLIC, WITH INCONSISTENCY
deps_data = Any[
    ["A", v"1", "B", "1"],
    ["A", v"2", "B", "2-*"],
    ["B", v"1", "C", "1"],
    ["B", v"2", "C", "2-*"],
    ["C", v"1", "A", "2-*"],
    ["C", v"2", "A", "2-*"],
]

@test sanity_tst(deps_data, [("A", v"1"), ("B", v"1"),
                             ("C", v"1")])

# require A
reqs_data = Any[
    ["A", "*"]
]
want_data = Dict("A"=>v"2", "B"=>v"2", "C"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require C
reqs_data = Any[
    ["C", "*"]
]
want_data = Dict("A"=>v"2", "B"=>v"2", "C"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require C, lowest version (impossible)
reqs_data = Any[
    ["C", "1"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)


## DEPENDENCY SCHEME 8: THREE PACKAGES, CYCLIC, TOTALLY INCONSISTENT
deps_data = Any[
    ["A", v"1", "B", "1"],
    ["A", v"2", "B", "2-*"],
    ["B", v"1", "C", "1"],
    ["B", v"2", "C", "2-*"],
    ["C", v"1", "A", "2-*"],
    ["C", v"2", "A", "1"],
]

@test sanity_tst(deps_data, [("A", v"1"), ("A", v"2"),
                             ("B", v"1"), ("B", v"2"),
                             ("C", v"1"), ("C", v"2")])

# require A (impossible)
reqs_data = Any[
    ["A", "*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)

# require B (impossible)
reqs_data = Any[
    ["B", "*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)

# require C (impossible)
reqs_data = Any[
    ["C", "*"]
]
@test_throws PkgError resolve_tst(deps_data, reqs_data)

## DEPENDENCY SCHEME 9: SIX PACKAGES, DAG
deps_data = Any[
    ["A", v"1"],
    ["A", v"2"],
    ["A", v"3"],
    ["B", v"1", "A", "1"],
    ["B", v"2", "A", "*"],
    ["C", v"1", "A", "2"],
    ["C", v"2", "A", "2-*"],
    ["D", v"1", "B", "1-*"],
    ["D", v"2", "B", "2-*"],
    ["E", v"1", "D", "*"],
    ["F", v"1", "A", "1-2"],
    ["F", v"1", "E", "*"],
    ["F", v"2", "C", "2-*"],
    ["F", v"2", "E", "*"],
]

@test sanity_tst(deps_data)

# require just F
reqs_data = Any[
    ["F", "*"]
]
want_data = Dict("A"=>v"3", "B"=>v"2", "C"=>v"2",
                 "D"=>v"2", "E"=>v"1", "F"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just F, lower version
reqs_data = Any[
    ["F", "1"]
]
want_data = Dict("A"=>v"2", "B"=>v"2", "D"=>v"2",
                 "E"=>v"1", "F"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)

# require F and B; force lower B version -> must bring down F, A, and D versions too
reqs_data = Any[
    ["F", "*"],
    ["B", "1"]
]
want_data = Dict("A"=>v"1", "B"=>v"1", "D"=>v"1",
                 "E"=>v"1", "F"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)

# require F and D; force lower D version -> must not bring down F version
reqs_data = Any[
    ["F", "*"],
    ["D", "1"]
]
want_data = Dict("A"=>v"3", "B"=>v"2", "C"=>v"2",
                 "D"=>v"1", "E"=>v"1", "F"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require F and C; force lower C version -> must bring down F and A versions
reqs_data = Any[
    ["F", "*"],
    ["C", "1"]
]
want_data = Dict("A"=>v"2", "B"=>v"2", "C"=>v"1",
                 "D"=>v"2", "E"=>v"1", "F"=>v"1")
@test resolve_tst(deps_data, reqs_data, want_data)

## DEPENDENCY SCHEME 10: FIVE PACKAGES, SAME AS SCHEMES 5 + 1, UNCONNECTED
deps_data = Any[
    ["A", v"1", "B", "2-*"],
    ["A", v"1", "C", "2-*"],
    ["A", v"2", "B", "1"],
    ["A", v"2", "C", "1"],
    ["B", v"1", "C", "2-*"],
    ["B", v"2", "C", "2-*"],
    ["C", v"1"],
    ["C", v"2"],
    ["D", v"1", "E", "1-*"],
    ["D", v"2", "E", "2-*"],
    ["E", v"1"],
    ["E", v"2"]
]

@test sanity_tst(deps_data, [("A", v"2")])
@test sanity_tst(deps_data, [("A", v"2")], pkgs=["B"])
@test sanity_tst(deps_data, pkgs=["D"])
@test sanity_tst(deps_data, pkgs=["E"])
@test sanity_tst(deps_data, [("A", v"2")], pkgs=["B", "D"])

# require A, any version (must use the highest non-inconsistent)
reqs_data = Any[
    ["A", "*"]
]
want_data = Dict("A"=>v"1", "B"=>v"2", "C"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

# require just D: must bring in E
reqs_data = Any[
    ["D", "*"]
]
want_data = Dict("D"=>v"2", "E"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)


# require A and D, must be the merge of the previous two cases
reqs_data = Any[
    ["A", "*"],
    ["D", "*"]
]
want_data = Dict("A"=>v"1", "B"=>v"2", "C"=>v"2", "D"=>v"2", "E"=>v"2")
@test resolve_tst(deps_data, reqs_data, want_data)

## DEPENDENCY SCHEME 11: A REALISTIC EXAMPLE
## ref issue #21485

include("resolvedata1.jl")

@test sanity_tst(deps_data, problematic_data)
@test resolve_tst(deps_data, reqs_data, want_data)

end # module
