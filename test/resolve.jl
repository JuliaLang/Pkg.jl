# This file is a part of Julia. License is MIT: https://julialang.org/license

module ResolveTest
import ..Pkg # ensure we are using the correct Pkg

using Test
using Pkg.Types
using Pkg.Types: VersionBound
using UUIDs
using Pkg.Resolve
import Pkg.Resolve: VersionWeight, add_reqs!, simplify_graph!, ResolverError, Fixed, Requires

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

@testset "schemes" begin
    VERBOSE && @info("SCHEME 1")
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
    resolve_tst(deps_data, reqs_data, want_data)
    @test resolve_tst(deps_data, reqs_data, want_data)

    # require just A: must bring in B
    reqs_data = Any[
        ["A", "*"]
    ]
    want_data = Dict("A"=>v"2", "B"=>v"2")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 2")
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


    VERBOSE && @info("SCHEME 3")
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
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 4")
    ## DEPENDENCY SCHEME 4: TWO PACKAGES, DAG, WITH TRIVIAL INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["B", v"1"]
    ]

    @test sanity_tst(deps_data, [("A", v"1")])
    @test sanity_tst(deps_data, pkgs=["B"])

    # require B (must not give errors)
    reqs_data = Any[
        ["B", "*"]
    ]
    want_data = Dict("B"=>v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)


    VERBOSE && @info("SCHEME 5")
    ## DEPENDENCY SCHEME 5: THREE PACKAGES, DAG, WITH IMPLICIT INCONSISTENCY
    deps_data = Any[
        ["A", v"1", "B", "2-*"],
        ["A", v"1", "C", "2-*"],
        # ["A", v"1", "julia", "10"],
        ["A", v"2", "B", "1"],
        ["A", v"2", "C", "1"],
        ["B", v"1", "C", "2-*"],
        ["B", v"2", "C", "2-*"],
        ["C", v"1"],
        ["C", v"2"]
    ]

    @test sanity_tst(deps_data, [("A", v"2")])
    @test sanity_tst(deps_data, pkgs=["B"])
    @test sanity_tst(deps_data, pkgs=["C"])

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
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)


    VERBOSE && @info("SCHEME 6")
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
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require B (impossible)
    reqs_data = Any[
        ["B", "*"]
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

    @test sanity_tst(deps_data, [("A", v"1"), ("A", v"2"),
                                ("B", v"1"), ("B", v"2"),
                                ("C", v"1"), ("C", v"2")])

    # require A (impossible)
    reqs_data = Any[
        ["A", "*"]
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require B (impossible)
    reqs_data = Any[
        ["B", "*"]
    ]
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)

    # require C (impossible)
    reqs_data = Any[
        ["C", "*"]
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
        ["E", v"2"]
    ]

    @test sanity_tst(deps_data, [("A", v"2")])
    @test sanity_tst(deps_data, pkgs=["B"])
    @test sanity_tst(deps_data, pkgs=["D"])
    @test sanity_tst(deps_data, pkgs=["E"])
    @test sanity_tst(deps_data, pkgs=["B", "D"])

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
    want_data = Dict("A"=>v"1", "B"=>v"1", "C"=>v"1", "D"=>v"1")
    @test resolve_tst(deps_data, reqs_data, want_data)

end

@testset "realistic" begin
    VERBOSE && @info("SCHEME REALISTIC")
    ## DEPENDENCY SCHEME 12: A REALISTIC EXAMPLE
    ## ref Julia issue #21485

    include("resolvedata1.jl")

    @test sanity_tst(ResolveData.deps_data, ResolveData.problematic_data)
    @test resolve_tst(ResolveData.deps_data, ResolveData.reqs_data, ResolveData.want_data)

    ## DEPENDENCY SCHEME 13: A LARGER, MORE DIFFICULT REALISTIC EXAMPLE
    ## ref Pkg.jl issue #1949

    include("resolvedata2.jl")

    @test sanity_tst(ResolveData2.deps_data, ResolveData2.problematic_data)
    @test resolve_tst(ResolveData2.deps_data, ResolveData2.reqs_data, ResolveData2.want_data)
end

@testset "nasty" begin
    VERBOSE && @info("SCHEME NASTY")
    ## DEPENDENCY SCHEME 13: A NASTY CASE

    include("NastyGenerator.jl")
    deps_data, reqs_data, want_data, problematic_data = NastyGenerator.generate_nasty(5, 20, q=20, d=4, sat = true)

    @test sanity_tst(deps_data, problematic_data)
    @test resolve_tst(deps_data, reqs_data, want_data)

    deps_data, reqs_data, want_data, problematic_data = NastyGenerator.generate_nasty(5, 20, q=20, d=4, sat = false)

    @test sanity_tst(deps_data, problematic_data)
    @test_throws ResolverError resolve_tst(deps_data, reqs_data)
end

@testset "Resolving for another version of Julia" begin
    temp_pkg_dir() do dir
        function find_by_name(versions, name)
            idx = findfirst(p -> p.name == name, versions)
            if idx === nothing
                return nothing
            end
            return versions[idx]
        end

        # First, we're going to resolve for specific versions of Julia, ensuring we get the right dep versions:
        Pkg.Registry.download_default_registries(Pkg.stdout_f())
        ctx = Pkg.Types.Context(;julia_version=v"1.5")
        versions, deps = Pkg.Operations._resolve(ctx.io, ctx.env, ctx.registries, [
            Pkg.Types.PackageSpec(name="MPFR_jll", uuid=Base.UUID("3a97d323-0669-5f0c-9066-3539efd106a3")),
        ], Pkg.Types.PRESERVE_TIERED, ctx.julia_version)
        gmp = find_by_name(versions, "GMP_jll")
        @test gmp !== nothing
        @test gmp.version.major == 6 && gmp.version.minor == 1
        ctx = Pkg.Types.Context(;julia_version=v"1.6")
        versions, deps = Pkg.Operations._resolve(ctx.io, ctx.env, ctx.registries, [
            Pkg.Types.PackageSpec(name="MPFR_jll", uuid=Base.UUID("3a97d323-0669-5f0c-9066-3539efd106a3")),
        ], Pkg.Types.PRESERVE_TIERED, ctx.julia_version)
        gmp = find_by_name(versions, "GMP_jll")
        @test gmp !== nothing
        @test gmp.version.major == 6 && gmp.version.minor == 2

        # We'll also test resolving an "impossible" manifest; one that requires two package versions that
        # are not both loadable by the same Julia:
        ctx = Pkg.Types.Context(;julia_version=nothing)
        versions, deps = Pkg.Operations._resolve(ctx.io, ctx.env, ctx.registries, [
            # This version of GMP only works on Julia v1.6
            Pkg.Types.PackageSpec(name="GMP_jll", uuid=Base.UUID("781609d7-10c4-51f6-84f2-b8444358ff6d"), version=v"6.2.0"),
            # This version of MPFR only works on Julia v1.5
            Pkg.Types.PackageSpec(name="MPFR_jll", uuid=Base.UUID("3a97d323-0669-5f0c-9066-3539efd106a3"), version=v"4.0.2"),
        ], Pkg.Types.PRESERVE_TIERED, ctx.julia_version)
        gmp = find_by_name(versions, "GMP_jll")
        @test gmp !== nothing
        @test gmp.version.major == 6 && gmp.version.minor == 2
        mpfr = find_by_name(versions, "MPFR_jll")
        @test mpfr !== nothing
        @test mpfr.version.major == 4 && mpfr.version.minor == 0
    end
end

@testset "Stdlib resolve smoketest" begin
    # All stdlibs should be installable and resolvable
    temp_pkg_dir() do dir
        Pkg.activate(temp=true)
        Pkg.add(map(first, values(Pkg.Types.load_stdlib())))    # add all stdlibs
        iob = IOBuffer()
        Pkg.resolve(io = iob)
        str = String(take!(iob))
        @test occursin(r"No Changes to .*Project.toml", str)
        @test occursin(r"No Changes to .*Manifest.toml", str)
    end
end

end # module
