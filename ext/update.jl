lazy_dir = joinpath(@__DIR__, "LazilyInitializedFields")
lazy_file = joinpath(lazy_dir, "LazilyInitializedFields.jl")
mkpath(lazy_dir)
download("https://raw.githubusercontent.com/KristofferC/LazilyInitializedFields.jl/master/src/LazilyInitializedFields.jl",
         lazy_file)
