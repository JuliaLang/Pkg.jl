module Contexts

export Context, Context!, printpkgstyle, manifest_info

using  UUIDs
using  ..EnvCaches, ..Utils

###
### RegistryCache
###
Base.@kwdef struct RegistryCache
    uuids::Dict{String,Vector{UUID}} = Dict{String,Vector{UUID}}()
    paths::Dict{UUID,Vector{String}} = Dict{UUID,Vector{String}}()
    names::Dict{UUID,Vector{String}} = Dict{UUID,Vector{String}}()
end

###
### Context
###
# ENV variables to set some of these defaults?
Base.@kwdef mutable struct Context
    env::EnvCache = EnvCache()
    reg::RegistryCache = RegistryCache()
    io::IO = stderr
    preview::Bool = false
    use_libgit2_for_all_downloads::Bool = false
    use_only_tarballs_for_downloads::Bool = false
    # NOTE: The JULIA_PKG_CONCURRENCY environment variable is likely to be removed in
    # the future. It currently stands as an unofficial workaround for issue #795.
    num_concurrent_downloads::Int = haskey(ENV, "JULIA_PKG_CONCURRENCY") ? parse(Int, ENV["JULIA_PKG_CONCURRENCY"]) : 8
    graph_verbose::Bool = false
    stdlibs::Dict{UUID,String} = stdlib()
    # Remove next field when support for Pkg2 CI scripts is removed
    currently_running_target::Bool = false
    old_pkg2_clone_name::String = ""
end

Context!(kw_context::Vector{Pair{Symbol,Any}}) = Context!(Context(); kw_context...)
function Context!(ctx::Context; kwargs...)
    for (k, v) in kwargs
        setfield!(ctx, k, v)
    end
    return ctx
end


###
### Utilities
###
function printpkgstyle(ctx::Context, cmd::Symbol, text::String, ignore_indent::Bool=false)
    indent = textwidth(string(:Downloaded))
    ignore_indent && (indent = 0)
    printstyled(ctx.io, lpad(string(cmd), indent), color=:green, bold=true)
    println(ctx.io, " ", text)
end

# Find package by UUID in the manifest file
manifest_info(ctx::Context, uuid::Nothing) = nothing
manifest_info(ctx::Context, uuid::UUID) = get(ctx.env.manifest, uuid, nothing)

end #module
