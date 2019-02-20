module Registry

import ..Pkg, ..Types, ..API
using ..Pkg: depots1
using ..Types: RegistrySpec, Context


"""
    Pkg.Registry.add(url::String)
    Pkg.Registry.add(registry::RegistrySpec)

Add new package registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.add("General")
Pkg.Registry.add(RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"))
Pkg.Registry.add(RegistrySpec(url = "https://github.com/JuliaRegistries/General.git"))
```
"""
function add end
add(reg::Union{String,RegistrySpec}) = add([reg])
add(regs::Vector{String}) = add([RegistrySpec(name = name) for name in regs])
add(regs::Vector{RegistrySpec}) = add(Context(), regs)
add(ctx::Context, regs::Vector{RegistrySpec}) =
    Types.clone_or_cp_registries(ctx, regs)

"""
    Pkg.Registry.rm(registry::String)
    Pkg.Registry.rm(registry::RegistrySpec)

Remove registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.rm("General")
Pkg.Registry.rm(RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"))
```
"""
function rm end
rm(reg::Union{String,RegistrySpec}) = rm([reg])
rm(regs::Vector{String}) = rm([RegistrySpec(name = name) for name in regs])
rm(regs::Vector{RegistrySpec}) = rm(Context(), regs)
rm(ctx::Context, regs::Vector{RegistrySpec}) = Types.remove_registries(ctx, regs)

"""
    Pkg.Registry.update()
    Pkg.Registry.update(registry::RegistrySpec)
    Pkg.Registry.update(registry::Vector{RegistrySpec})

Update registries. If no registries are given, update
all available registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.update()
Pkg.Registry.update("General")
Pkg.Registry.update(RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"))
```
"""
function update end
update(reg::Union{String,RegistrySpec}) = update([reg])
update(regs::Vector{String}) = update([RegistrySpec(name = name) for name in regs])
update(regs::Vector{RegistrySpec} = Types.collect_registries(depots1())) =
    update(Context(), regs)
update(ctx::Context, regs::Vector{RegistrySpec} = Types.collect_registries(depots1())) =
    Types.update_registries(ctx, regs; force=true)

"""
    Pkg.Registry.status()

Display information about available registries.

!!! compat "Julia 1.1"
    Pkg's registry handling requires at least Julia 1.1.

# Examples
```julia
Pkg.Registry.status()
```
"""
function status()
    regs = Types.collect_registries()
    regs = unique(r -> r.uuid, regs) # Maybe not?
    Types.printpkgstyle(stdout, Symbol("Registry Status"), "")
    if isempty(regs)
        println("  (no registries found)")
    else
        for reg in regs
            printstyled(" [$(string(reg.uuid)[1:8])]"; color = :light_black)
            print(" $(reg.name)")
            reg.url === nothing || print(" ($(reg.url))")
            println()
        end
    end
end

end # module
