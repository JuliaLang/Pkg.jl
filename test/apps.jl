module AppsTests

import ..Pkg # ensure we are using the correct Pkg

using Test

Pkg.Apps.develop(path=joinpath(@__DIR__, "test_packages", "Rot13.jl"))

#Pkg.Apps.status()

#setenv(, )



end
