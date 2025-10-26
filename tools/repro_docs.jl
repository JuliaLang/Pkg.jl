using Pkg

println("PWD: ", pwd())
println("Activating docs project and instantiating...")
Pkg.activate("docs")
Pkg.instantiate()
println("Instantiate finished.")
