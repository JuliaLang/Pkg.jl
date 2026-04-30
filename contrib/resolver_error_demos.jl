module ResolverErrorDemos

    import Pkg

    include(joinpath(@__DIR__, "..", "test", "resolve_utils.jl"))
    using .ResolveUtils

    const Demo = NamedTuple{(:title, :prompt, :description, :deps_data, :reqs_data), Tuple{String, String, String, Vector{Any}, Vector{Any}}}

    const DEMOS = Demo[
        (
            title = "Unavailable dependency version",
            prompt = "pkg> add A",
            description = "A requires B 2.x, but only B 1.0 exists.",
            deps_data = Any[
                ["A", v"1.0.0", "B", "2-*"],
                ["B", v"1.0.0"],
            ],
            reqs_data = Any[
                ["A", "*"],
            ],
        ),
        (
            title = "Diamond dependency conflict",
            prompt = "pkg> add A B",
            description = "A and B both need D, but they require disjoint D versions.",
            deps_data = Any[
                ["A", v"1.0.0", "D", "0.1"],
                ["B", v"1.0.0", "D", "0.2"],
                ["D", v"0.1.0"],
                ["D", v"0.2.0"],
            ],
            reqs_data = Any[
                ["A", "*"],
                ["B", "*"],
            ],
        ),
        (
            title = "Transitive dependency conflict",
            prompt = "pkg> add A B",
            description = "A reaches D through C, while B requires an incompatible D version directly.",
            deps_data = Any[
                ["A", v"1.0.0", "C", "0.2"],
                ["B", v"1.0.0", "D", "0.1"],
                ["C", v"0.1.0", "D", "0.1"],
                ["C", v"0.2.0", "D", "0.2"],
                ["D", v"0.1.0"],
                ["D", v"0.2.0"],
            ],
            reqs_data = Any[
                ["A", "*"],
                ["B", "*"],
            ],
        ),
        (
            title = "Cyclic incompatibility",
            prompt = "pkg> add C@1",
            description = "A, B, and C form a cycle where the requested C version forces inconsistent choices.",
            deps_data = Any[
                ["A", v"1.0.0", "B", "1"],
                ["A", v"2.0.0", "B", "2-*"],
                ["B", v"1.0.0", "C", "1"],
                ["B", v"2.0.0", "C", "2-*"],
                ["C", v"1.0.0", "A", "2-*"],
                ["C", v"2.0.0", "A", "2-*"],
            ],
            reqs_data = Any[
                ["C", "1"],
            ],
        ),
    ]

    function resolver_error_message(demo::Demo)
        err = try
            resolve_tst(demo.deps_data, demo.reqs_data)
        catch err
            err isa Pkg.Resolve.ResolverError || rethrow()
            err
        end
        err isa Pkg.Resolve.ResolverError || error("demo resolved successfully: $(demo.title)")
        return sprint(showerror, err)
    end

    function print_demo(io::IO, index::Int, demo::Demo)
        println(io, "="^80)
        println(io, "Demo $index: ", demo.title)
        println(io, demo.prompt)
        println(io, demo.description)
        println(io, "-"^80)
        println(io, resolver_error_message(demo))
        println(io)
        return
    end

    function main(args = ARGS)
        isempty(args) || error("usage: julia --project=. contrib/resolver_error_demos.jl")
        for (index, demo) in enumerate(DEMOS)
            print_demo(stdout, index, demo)
        end
        return
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    ResolverErrorDemos.main()
end
