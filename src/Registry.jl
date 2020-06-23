module Registry

import ..Pkg, ..Types, ..API
using ..Pkg: depots1
using ..Types: RegistrySpec, Context, Context!


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
add(reg::Union{String,RegistrySpec}; kwargs...) = add([reg]; kwargs...)
add(regs::Vector{String}; kwargs...) = add([RegistrySpec(name = name) for name in regs]; kwargs...)
add(regs::Vector{RegistrySpec}; kwargs...) = add(Context(), regs; kwargs...)
function add(ctx::Context, regs::Vector{RegistrySpec}; kwargs...)
    Context!(ctx; kwargs...)
    if isempty(regs)
        Types.clone_default_registries(ctx, only_if_empty = false)
    else
        Types.clone_or_cp_registries(ctx, regs)
    end
end

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
rm(reg::Union{String,RegistrySpec}; kwargs...) = rm([reg]; kwargs...)
rm(regs::Vector{String}; kwargs...) = rm([RegistrySpec(name = name) for name in regs]; kwargs...)
rm(regs::Vector{RegistrySpec}; kwargs...) = rm(Context(), regs; kwargs...)
function rm(ctx::Context, regs::Vector{RegistrySpec}; kwargs...)
    Context!(ctx; kwargs...)
    Types.remove_registries(ctx, regs)
end

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
update(reg::Union{String,RegistrySpec}; kwargs...) = update([reg]; kwargs...)
update(regs::Vector{String}; kwargs...) = update([RegistrySpec(name = name) for name in regs]; kwargs...)
update(regs::Vector{RegistrySpec} = RegistrySpec[]; kwargs...) =
    update(Context(), regs; kwargs...)
function update(ctx::Context,
                regs::Vector{RegistrySpec} = RegistrySpec[];
                kwargs...)
    isempty(regs) && (regs = Types.collect_registries(depots1()))
    Context!(ctx; kwargs...)
    Types.update_registries(ctx, regs; force=true)
end

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
status(; kwargs...) = status(Context(); kwargs...)
function status(ctx::Context; io::IO=stdout, as_api=false, kwargs...) # TODO split as_api into own function
    Context!(ctx; io=io, kwargs...)
    regs = Types.collect_registries()
    regs = unique(r -> r.uuid, regs) # Maybe not?
    as_api && return regs
    Types.printpkgstyle(ctx, Symbol("Registry Status"), "")
    if isempty(regs)
        println(ctx.io, "  (no registries found)")
    else
        for reg in regs
            printstyled(ctx.io, " [$(string(reg.uuid)[1:8])]"; color = :light_black)
            print(ctx.io, " $(reg.name)")
            reg.url === nothing || print(ctx.io, " ($(reg.url))")
            println(ctx.io)
        end
    end
end

end # module
