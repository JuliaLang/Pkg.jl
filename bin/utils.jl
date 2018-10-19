#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

function packagelt(a::String, b::String)
    a == "julia" && b != "julia" && return true
    a != "julia" && b == "julia" && return false
    return lowercase(a) < lowercase(b)
end

function write_toml(f::Function, names::String...)
    path = joinpath(names...) * ".toml"
    mkpath(dirname(path))
    open(path, "w") do io
        f(io)
    end
end

toml_key(str::String) = occursin(r"[^\w-]", str) ? repr(str) : str
toml_key(strs::String...) = join(map(toml_key, [strs...]), '.')
