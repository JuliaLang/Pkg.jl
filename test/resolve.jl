# This file is a part of Julia. License is MIT: https://julialang.org/license

module ResolveTest
import ..Pkg # ensure we are using the correct Pkg

using Test
using Pkg.Types
using Pkg.Types: VersionBound
using UUIDs
using Pkg.Resolve
import Pkg.Resolve: VersionWeight, add_reqs!, simplify_graph!, ResolverError, ResolverTimeoutError, Fixed, Requires

include("utils.jl")
using .Utils
include("resolve_utils.jl")
using .ResolveUtils

# Check that VersionWeight keeps the same ordering as VersionNumber

vlst = [
    v"0.0.0",
    v"0.0.1",
    v"0.1.0",
    v"0.1.1",
    v"1.0.0",
    v"1.0.1",
    v"1.1.0",
    v"1.1.1",
]

for v1 in vlst, v2 in vlst
    vw1 = VersionWeight(v1)
    vw2 = VersionWeight(v2)
    clt = v1 < v2
    @test clt == (vw1 < vw2)
    ceq = v1 == v2
    @test ceq == (vw1 == vw2)
end

@testset "schemes" begin
    VERBOSE && @info("SCHEME 1")
    ## DEPENDENCY SCHEME 1: TWO PACKAGES, DAG
    deps_data = Any[
        ["A", v"1", "B", "1-*"],
        ["A", v"2", "B", "2-*"],
        ["B", v"1"],
        ["B", v"2"],
    ]

    @test sanity_tst(deps_data)
    @test sanity_tst(deps_data, pkgs = ["A", "B"])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["A"])

    # require just B
    reqs_data = Any[
        ["B", "*"],
    ]

    want_data = Dict("B" => v"2")
    resolve_tst(deps_data, reqs_data, want_data)
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A: must bring in B
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 2")
    ## DEPENDENCY SCHEME 2: TWO PACKAGES, CYCLIC
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"2", "B", "1-*"],
        ["B", v"1", "A", "2-*"],
        ["B", v"2", "A", "1-*"],
    ]

    @test sanity_tst(deps_data)

    # require just A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just B, force lower version
    reqs_data = Any[
        ["B", "1"],
    ]
    want_data = Dict("A" => v"2", "B" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A, force lower version
    reqs_data = Any[
        ["A", "1"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 3")
    ## DEPENDENCY SCHEME 3: THREE PACKAGES, CYCLIC, TWO MUTUALLY EXCLUSIVE SOLUTIONS
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"2", "B", "1"],
        ["B", v"1", "C", "2-*"],
        ["B", v"2", "C", "1"],
        ["C", v"1", "A", "1"],
        ["C", v"2", "A", "2-*"],
    ]

    @test sanity_tst(deps_data)

    # require just A (must choose solution which has the highest version for A)
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"1", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just B (must choose solution which has the highest version for B)
    reqs_data = Any[
        ["B", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A, force lower version
    reqs_data = Any[
        ["A", "1"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A and C, incompatible versions
    reqs_data = Any[
        ["A", "1"],
        ["C", "2-*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 4")
    ## DEPENDENCY SCHEME 4: TWO PACKAGES, DAG, WITH TRIVIAL INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["B", v"1"],
    ]

    @test sanity_tst(deps_data, [("A", v"1")])
    @test sanity_tst(deps_data, pkgs = ["B"])

    # require B (must not give errors)
    reqs_data = Any[
        ["B", "*"],
    ]
    want_data = Dict("B" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A (must give an error)
    reqs_data = Any[
        ["A", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 5")
    ## DEPENDENCY SCHEME 5: THREE PACKAGES, DAG, WITH IMPLICIT INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"1", "C", "2-*"],
        ["A", v"2", "B", "1"],
        ["A", v"2", "C", "1"],
        ["B", v"1", "C", "2-*"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1"],
        ["C", v"2"],
    ]

    @test sanity_tst(deps_data, [("A", v"2")])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["C"])

    # require A, any version (must use the highest non-inconsistent)
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A, force highest version (impossible)
    reqs_data = Any[
        ["A", "2-*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 6")
    ## DEPENDENCY SCHEME 6: TWO PACKAGES, CYCLIC, TOTALLY INCONSISTENT
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"2", "B", "1"],
        ["B", v"1", "A", "1"],
        ["B", v"2", "A", "2-*"],
    ]

    @test sanity_tst(
        deps_data, [
            ("A", v"1"), ("A", v"2"),
            ("B", v"1"), ("B", v"2"),
        ]
    )

    # require A (impossible)
    reqs_data = Any[
        ["A", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require B (impossible)
    reqs_data = Any[
        ["B", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 7")
    ## DEPENDENCY SCHEME 7: THREE PACKAGES, CYCLIC, WITH INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "1"],
        ["A", v"2", "B", "2-*"],
        ["B", v"1", "C", "1"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1", "A", "2-*"],
        ["C", v"2", "A", "2-*"],
    ]

    @test sanity_tst(
        deps_data, [
            ("A", v"1"), ("B", v"1"),
            ("C", v"1"),
        ]
    )

    # require A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require C
    reqs_data = Any[
        ["C", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require C, lowest version (impossible)
    reqs_data = Any[
        ["C", "1"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 8")
    ## DEPENDENCY SCHEME 8: THREE PACKAGES, CYCLIC, TOTALLY INCONSISTENT
    deps_data = Any[
        ["A", v"1", "B", "1"],
        ["A", v"2", "B", "2-*"],
        ["B", v"1", "C", "1"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1", "A", "2-*"],
        ["C", v"2", "A", "1"],
    ]

    @test sanity_tst(
        deps_data, [
            ("A", v"1"), ("A", v"2"),
            ("B", v"1"), ("B", v"2"),
            ("C", v"1"), ("C", v"2"),
        ]
    )

    # require A (impossible)
    reqs_data = Any[
        ["A", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require B (impossible)
    reqs_data = Any[
        ["B", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require C (impossible)
    reqs_data = Any[
        ["C", "*"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    VERBOSE && @info("SCHEME 9")
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
        ["F", "*"],
    ]
    want_data = Dict(
        "A" => v"3", "B" => v"2", "C" => v"2",
        "D" => v"2", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just F, lower version
    reqs_data = Any[
        ["F", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "B" => v"2", "D" => v"2",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and B; force lower B version -> must bring down F, A, and D versions too
    reqs_data = Any[
        ["F", "*"],
        ["B", "1"],
    ]
    want_data = Dict(
        "A" => v"1", "B" => v"1", "D" => v"1",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and D; force lower D version -> must not bring down F version
    reqs_data = Any[
        ["F", "*"],
        ["D", "1"],
    ]
    want_data = Dict(
        "A" => v"3", "B" => v"2", "C" => v"2",
        "D" => v"1", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and C; force lower C version -> must bring down F and A versions
    reqs_data = Any[
        ["F", "*"],
        ["C", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "B" => v"2", "C" => v"1",
        "D" => v"2", "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    VERBOSE && @info("SCHEME 10")
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
        ["E", v"2"],
    ]

    @test sanity_tst(deps_data, [("A", v"2")])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["D"])
    @test sanity_tst(deps_data, pkgs = ["E"])
    @test sanity_tst(deps_data, pkgs = ["B", "D"])

    # require A, any version (must use the highest non-inconsistent)
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just D: must bring in E
    reqs_data = Any[
        ["D", "*"],
    ]
    want_data = Dict("D" => v"2", "E" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    # require A and D, must be the merge of the previous two cases
    reqs_data = Any[
        ["A", "*"],
        ["D", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"2", "C" => v"2", "D" => v"2", "E" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 11")
    ## DEPENDENCY SCHEME 11: FOUR PACKAGES, WITH AN INCONSISTENCY
    ## ref Pkg.jl issue #2740
    deps_data = Any[
        ["A", v"1", "C", "1"],
        ["A", v"2", "C", "2"],
        ["A", v"2", "D", "1"],
        ["B", v"1", "D", "1"],
        ["B", v"2", "D", "2"],
        ["C", v"1", "D", "1"],
        ["C", v"1", "B", "1"],
        ["C", v"2", "D", "2"],
        ["C", v"2", "B", "2"],
        ["D", v"1"],
        ["D", v"2"],
    ]

    @test sanity_tst(deps_data, [("A", v"2")])

    # require A & B, any version (must use the highest non-inconsistent)
    reqs_data = Any[
        ["A", "*"],
        ["B", "*"],
    ]
    want_data = Dict("A" => v"1", "B" => v"1", "C" => v"1", "D" => v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 12")
    ## DEPENDENCY SCHEME 12: TWO PACKAGES, DAG, WEAK DEPENDENCY
    deps_data = Any[
        ["A", v"1", "B", "1-*", :weak],
        ["A", v"2", "B", "2-*", :weak],
        ["B", v"1"],
        ["B", v"2"],
    ]

    @test sanity_tst(deps_data)
    @test sanity_tst(deps_data, pkgs = ["A", "B"])
    @test sanity_tst(deps_data, pkgs = ["B"])
    @test sanity_tst(deps_data, pkgs = ["A"])

    # require just B
    reqs_data = Any[
        ["B", "*"],
    ]
    want_data = Dict("B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict("A" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A and B
    reqs_data = Any[
        ["A", "*"],
        ["B", "*"],
    ]
    want_data = Dict("A" => v"2", "B" => v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A and B, invompatible versions
    reqs_data = Any[
        ["A", "2-*"],
        ["B", "1"],
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 13")
    ## DEPENDENCY SCHEME 13: LIKE 9 (SIX PACKAGES, DAG), WITH SOME WEAK DEPENDENCIES
    deps_data = Any[
        ["A", v"1"],
        ["A", v"2"],
        ["A", v"3"],
        ["B", v"1", "A", "1"],
        ["B", v"2", "A", "*"],
        ["C", v"1", "A", "2", :weak],
        ["C", v"2", "A", "2-*"],
        ["D", v"1", "B", "1-*"],
        ["D", v"2", "B", "2-*", :weak],
        ["E", v"1", "D", "*"],
        ["F", v"1", "A", "1-2"],
        ["F", v"1", "E", "*"],
        ["F", v"2", "C", "2-*"],
        ["F", v"2", "E", "*"],
    ]

    @test sanity_tst(deps_data)

    # require just F
    reqs_data = Any[
        ["F", "*"],
    ]
    want_data = Dict(
        "A" => v"3", "C" => v"2",
        "D" => v"2", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just F, lower version
    reqs_data = Any[
        ["F", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "D" => v"2",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and B; force lower B version -> must bring down F, A, and D versions too
    reqs_data = Any[
        ["F", "*"],
        ["B", "1"],
    ]
    want_data = Dict(
        "A" => v"1", "B" => v"1", "D" => v"1",
        "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and D; force lower D version -> must not bring down F version, and bring in B
    reqs_data = Any[
        ["F", "*"],
        ["D", "1"],
    ]
    want_data = Dict(
        "A" => v"3", "B" => v"2", "C" => v"2",
        "D" => v"1", "E" => v"1", "F" => v"2"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require F and C; force lower C version -> must bring down F and A versions
    reqs_data = Any[
        ["F", "*"],
        ["C", "1"],
    ]
    want_data = Dict(
        "A" => v"2", "C" => v"1",
        "D" => v"2", "E" => v"1", "F" => v"1"
    )
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 14")
    ## DEPENDENCY SCHEME 14: A NASTY GRAPH WITH A LOCAL OPTIMUM
    ## (REDUCED VERSION OF REALISTIC SCHEME 17 BELOW, ref Pkg.jl issue #3232)
    deps_data = Any[
        ["A", v"1", "X", "*"],
        ["B", v"1"],
        ["B", v"2"],
        ["C", v"1"],
        ["C", v"2", "G", "2"],
        ["C", v"2", "H", "*"],
        ["D", v"1"],
        ["D", v"2", "C", "*"],
        ["Y", v"0.1"],
        ["Y", v"0.2.1", "B", "1"],
        ["Y", v"0.2.2"],
        ["X", v"0.1", "Y", "0.1"],
        ["X", v"0.2", "Y", "0.2"],
        ["E", v"1", "X", "0.1"],
        ["F", v"1", "I", "1"],
        ["G", v"1", "E", "*"],
        ["G", v"2"],
        ["H", v"1", "B", "*"],
        ["H", v"1", "F", "*"],
        ["H", v"1", "I", "*"],
        ["I", v"1"],
        ["I", v"2"],
    ]

    @test sanity_tst(deps_data)

    # require A and D
    reqs_data = Any[
        ["A", "*"],
        ["D", "*"],
    ]
    want_data = Dict(
        "A" => v"1",
        "B" => v"2",
        "C" => v"2",
        "D" => v"2",
        "Y" => v"0.2.2",
        "X" => v"0.2",
        "F" => v"1",
        "G" => v"2",
        "H" => v"1",
        "I" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just D
    reqs_data = Any[
        ["D", "*"],
    ]
    want_data = Dict(
        "B" => v"2",
        "C" => v"2",
        "D" => v"2",
        "F" => v"1",
        "G" => v"2",
        "H" => v"1",
        "I" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A
    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict(
        "A" => v"1",
        "Y" => v"0.2.2",
        "X" => v"0.2",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require A, D, and lower version of Y
    reqs_data = Any[
        ["A", "*"],
        ["D", "*"],
        ["Y", "0.2.1"],
    ]
    want_data = Dict(
        "A" => v"1",
        "B" => v"1",
        "C" => v"2",
        "D" => v"2",
        "Y" => v"0.2.1",
        "X" => v"0.2",
        "F" => v"1",
        "G" => v"2",
        "H" => v"1",
        "I" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 15")
    ## DEPENDENCY SCHEME 15: A GRAPH WITH A WEAK DEPENDENCE
    ## (REDUCED VERSION OF A REALISTIC SCHEME, ref Pkg.jl issue #4030)
    deps_data = Any[
        ["A", v"1"],
        ["A", v"2", "C", "*"],
        ["B", v"1", "D", "1", :weak],
        ["C", v"1", "E", "*"],
        ["C", v"2", "E", "*"],
        ["C", v"2", "B", "1"],
        ["E", v"1", "D", "1"],
        ["E", v"2", "F", "1"],
        ["F", v"1", "D", "*"],
        ["D", v"1"],
        ["D", v"2"],
    ]

    @test sanity_tst(deps_data)

    reqs_data = Any[
        ["A", "*"],
    ]
    want_data = Dict(
        "A" => v"2",
        "B" => v"1",
        "C" => v"2",
        "D" => v"1",
        "E" => v"2",
        "F" => v"1",
    )
    @test resolve_tst(deps_data, reqs_data, want_data)

end

@testset "realistic" begin
    tmp = mktempdir()
    Pkg.PlatformEngines.unpack(joinpath(@__DIR__, "resolvedata.tar.gz"), tmp; verbose = false)

    VERBOSE && @info("SCHEME REALISTIC 1")
    ## DEPENDENCY SCHEME 15: A REALISTIC EXAMPLE
    ## ref Julia issue #21485

    include(joinpath(tmp, "resolvedata1.jl"))

    @test sanity_tst(ResolveData.deps_data, ResolveData.problematic_data)
    @test resolve_tst(ResolveData.deps_data, ResolveData.reqs_data, ResolveData.want_data)

    VERBOSE && @info("SCHEME REALISTIC 2")
    ## DEPENDENCY SCHEME 16: A LARGER, MORE DIFFICULT REALISTIC EXAMPLE
    ## ref Pkg.jl issue #1949

    include(joinpath(tmp, "resolvedata2.jl"))

    @test sanity_tst(ResolveData2.deps_data, ResolveData2.problematic_data)
    @test resolve_tst(ResolveData2.deps_data, ResolveData2.reqs_data, ResolveData2.want_data)

    VERBOSE && @info("SCHEME REALISTIC 3")
    ## DEPENDENCY SCHEME 17: AN EVEN LARGER, MORE DIFFICULT REALISTIC EXAMPLE
    ## ref Pkg.jl issue #3232

    include(joinpath(tmp, "resolvedata3.jl"))

    @test sanity_tst(ResolveData3.deps_data, ResolveData3.problematic_data)
    @test resolve_tst(ResolveData3.deps_data, ResolveData3.reqs_data, ResolveData3.want_data)

    VERBOSE && @info("SCHEME REALISTIC 4")
    ## DEPENDENCY SCHEME 18: AN UNSAT REALISTIC EXAMPLE IN WHICH THE RESOLVER HANGS FOR MINUTES
    ## The resolve_tst call is intended to fail (by timeout) with validate_versions=false
    ## ref Pkg.jl issue #3878

    include(joinpath(tmp, "resolvedata4.jl"))

    @test sanity_tst(ResolveData4.deps_data, ResolveData4.problematic_data)
    withenv("JULIA_PKG_RESOLVE_MAX_TIME" => 10) do
        @test_throws ResolverError resolve_tst(ResolveData4.deps_data, ResolveData4.reqs_data, ResolveData4.want_data)
    end
    withenv("JULIA_PKG_RESOLVE_MAX_TIME" => 1.0e-5) do
        # this test may fail if graph preprocessing or the greedy solver get better
        @test_throws ResolverTimeoutError resolve_tst(ResolveData4.deps_data, ResolveData4.reqs_data, ResolveData4.want_data; validate_versions = false)
    end

end

@testset "nasty" begin
    VERBOSE && @info("SCHEME NASTY")
    ## DEPENDENCY SCHEME 19: A NASTY CASE

    include("NastyGenerator.jl")
    deps_data, reqs_data, want_data, problematic_data = NastyGenerator.generate_nasty(5, 20, q = 20, d = 4, sat = true)

    @test sanity_tst(deps_data, problematic_data)
    @test resolve_tst(deps_data, reqs_data, want_data)

    deps_data, reqs_data, want_data, problematic_data = NastyGenerator.generate_nasty(5, 20, q = 20, d = 4, sat = false)

    @test sanity_tst(deps_data, problematic_data)
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)
end

@testset "Stdlib resolve smoketest" begin
    # All stdlibs should be installable and resolvable
    temp_pkg_dir() do dir
        Pkg.activate(temp = true)
        Pkg.add(map(x -> x.name, values(Pkg.Types.load_stdlib())))    # add all stdlibs
        iob = IOBuffer()
        Pkg.resolve(io = iob)
        str = String(take!(iob))
        @test occursin(r"No packages added to or removed from .*Project.toml", str)
        @test occursin(r"No packages added to or removed from .*Manifest.toml", str)
    end
end

end # module
