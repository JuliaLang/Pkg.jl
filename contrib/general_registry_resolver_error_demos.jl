module GeneralRegistryResolverErrorDemos

    import Pkg

    const Demo = NamedTuple{(:title, :prompt, :description, :specs), Tuple{String, String, String, Vector{Pkg.PackageSpec}}}

    const DEMOS = Demo[
        (
            title = "Old Flux with new CUDA",
            prompt = "add Flux@0.12 CUDA@5.0",
            description = "Flux 0.12 only allows CUDA 2.x, while the user requested CUDA 5.0.",
            specs = Pkg.PackageSpec[
                Pkg.PackageSpec(name = "Flux", version = v"0.12.0"),
                Pkg.PackageSpec(name = "CUDA", version = v"5.0.0"),
            ],
        ),
        (
            title = "Old DifferentialEquations with newer OrdinaryDiffEq",
            prompt = "add DifferentialEquations@6.16 OrdinaryDiffEq@6.0",
            description = "OrdinaryDiffEq 6.0 requires a newer DifferentialEquations than 6.16.",
            specs = Pkg.PackageSpec[
                Pkg.PackageSpec(name = "DifferentialEquations", version = v"6.16.0"),
                Pkg.PackageSpec(name = "OrdinaryDiffEq", version = v"6.0.0"),
            ],
        ),
        (
            title = "Old Makie with newer GLMakie",
            prompt = "add Makie@0.15 GLMakie@0.9",
            description = "Makie 0.15 only allows older GLMakie releases, while GLMakie 0.9 was requested.",
            specs = Pkg.PackageSpec[
                Pkg.PackageSpec(name = "Makie", version = v"0.15.0"),
                Pkg.PackageSpec(name = "GLMakie", version = v"0.9.0"),
            ],
        ),
        (
            title = "Old JuMP with newer MathOptInterface",
            prompt = "add JuMP@0.21 MathOptInterface@1.0",
            description = "JuMP 0.21 requires MathOptInterface 0.9, while version 1.0 was requested.",
            specs = Pkg.PackageSpec[
                Pkg.PackageSpec(name = "JuMP", version = v"0.21.0"),
                Pkg.PackageSpec(name = "MathOptInterface", version = v"1.0.0"),
            ],
        ),
    ]

    function resolver_error_message(demo::Demo)
        return mktempdir() do dir
            Pkg.activate(dir; io = devnull)
            err = try
                Pkg.add(demo.specs; io = devnull)
            catch err
                err isa Pkg.Resolve.ResolverError || rethrow()
                err
            end
            err isa Pkg.Resolve.ResolverError || error("demo resolved successfully: $(demo.title)")
            return sprint(showerror, err)
        end
    end

    function print_demo(io::IO, index::Int, demo::Demo)
        println(io, "="^80)
        println(io, "Demo $index: ", demo.title)
        println(io, demo.description)
        println(io)
        printstyled(io, "(@v1.14) pkg> ", color = :blue)
        println(io, demo.prompt)
        println(io, resolver_error_message(demo))
        println(io)
        return
    end

    function main(args = ARGS)
        isempty(args) || error("usage: julia --project=. contrib/general_registry_resolver_error_demos.jl")
        for (index, demo) in enumerate(DEMOS)
            print_demo(stdout, index, demo)
        end
        return
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GeneralRegistryResolverErrorDemos.main()
end
