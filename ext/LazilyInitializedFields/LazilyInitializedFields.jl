"""
A package for handling lazily initialized fields.

### Exports:
* macros: `@lazy`, `@init!`, `@uninit!`, `@isinit`.
* functions: `init!` `uninit!`, `isinit`.
* objects: `uninit`.
* exceptions: `NonLazyFieldException`, `UninitializedFieldException`, `AlreadyInitializedException`

### Example usage:

```julia-repl
julia> @lazy struct Foo{T}
           a::T
           @lazy b::Int
           @lazy c::Union{Float64, Nothing}
           @lazy d::Union{Int, Nothing}
           e::Float64
       end

julia> f = Foo(2, uninit, 2.0, nothing, 3.0)
Foo{Int64}(2, uninit, 2.0, nothing, 3.0)

julia> @isinit f.b
false

julia> @isinit f.c
true

julia> f.b
ERROR: field `b` in struct of type `Foo{Int64}` is not initialized
[...]

julia> @init! f.b = 4
4

julia> f.b
4

julia> @init! f.a=2
ERROR: field `a` in struct of type `Foo{Int64}` is not lazy, lazy fields are `b` ,`c` ,`d`.
[...]

julia> @uninit! f.b
uninit

julia> @isinit f.b
false
```

"""
module LazilyInitializedFields

export @lazy, uninit,
       @init!, @isinit, @uninit!,
        init!,  isinit,  uninit!,
        NonLazyFieldException, UninitializedFieldException, AlreadyInitializedException


"""
    Uninitialized

A type with no fields that is the type of [`uninit`](@ref).
"""
struct Uninitialized end

"""
    uninit

The singleton instance of the type [`Uninitialized`](@ref), used
for fields that are currently uninitialized.
"""
const uninit = Uninitialized()
Base.show(io::IO, u::Uninitialized) = print(io, "uninit")

# The @lazy macro will extended this function
# for the struct getting defined so that we can use
# it to check if a field is lazy, for example:
# islazyfield(::Type{Foo}, s::Symbol) = s === :a || s === :b
function islazyfield end


struct NonLazyFieldException <: Exception
    T::DataType
    s::Symbol
end

Base.showerror(io::IO, err::NonLazyFieldException) =
    print(io, "field `$(err.s)` in struct of type `$(err.T)` is not lazy, lazy fields are ",
          join("`" .* string.(filter(x->islazyfield(err.T, x), fieldnames(err.T))) .* "`", ", "), ".")

struct UninitializedFieldException <: Exception
    T::DataType
    s::Symbol
end
Base.showerror(io::IO, err::UninitializedFieldException) =
    print(io, "field `", err.s, "` in struct of type `$(err.T)` is not initialized")

struct AlreadyInitializedException <: Exception
    T::DataType
    s::Symbol
end
Base.showerror(io::IO, err::AlreadyInitializedException) =
    print(io, "field `", err.s, "` in struct of type `$(err.T)` already initialized")


"""
    init!(a, s::Symbol)

Function version of [@init!](@ref).
"""
@inline function init!(x::T, s::Symbol, v) where {T}
    islazyfield(T, s) || throw(NonLazyFieldException(T, s))
    old = getfield(x, s)
    old isa Uninitialized || throw(AlreadyInitializedException(T, s))
    return setfield!(x, s, v)
end

_check_setproperty_expr(expr, s) =
    (expr isa Expr && expr.head === :(=) && expr.args[1].head === :.) || error("invalid usage of $s")
"""
    @init! a.b = v

Initialize the lazy field `b` in object `a` to `v`.
Throw a `NonLazyFieldException` if `b` is not a lazy field
of `a`. Throw an `AlreadyInitializedException` if `b` is already
initialized.
Macro version of `init!(a, :b, v)`

```jldoctest
julia> @lazy struct Foo
           @lazy b::Int
       end

julia> f = Foo(uninit)
Foo(uninit)

julia> f.b
ERROR: field `b` in struct of type `Foo` is not initialized
[...]

julia> @init! f.b = 3
3

julia> f.b
3

julia> @init! f.b = 2
ERROR: field `b` in struct of type `Foo` already initialized
[...]
```
"""
macro init!(expr)
    _check_setproperty_expr(expr, "@init!")
    v = expr.args[2]
    body, sym = expr.args[1].args
    return :(init!($(esc(body)), $(esc(sym)), $(esc(v))))
end


_check_getproperty_expr(expr, s) =
    (expr isa Expr && expr.head === :.) || error("invalid usage of $s")

"""
    isinit(a, s::Symbol)

Function version of [@isinit](@ref).
"""
@inline function isinit(x::T, s) where {T}
    islazyfield(T, s) || throw(NonLazyFieldException(T, s))
    !(getfield(x, s) isa Uninitialized)
end
"""
    @isinit a.b

Check if the lazy field `b` in the object `a` is initialized.
Throw a `NonLazyFieldException` if `b` is not a lazy field
of `a`.
Macro version of [`isinit(a, :b)`](@ref)

```jldoctest
julia> @lazy struct Foo
           @lazy b::Int
       end

julia> f = Foo(uninit)
Foo(uninit)

julia> @isinit f.b
false

julia> @init! f.b = 5
5

julia> @isinit f.b
true
```
"""
macro isinit(expr)
    _check_getproperty_expr(expr, "@isinit")
    return :(isinit($(esc.(expr.args)...)))
end

"""
    uninit!(a, s::Symbol)

Function version of [`@uninit!`](@ref).
"""

@inline function uninit!(x::T, s::Symbol) where {T}
    islazyfield(T, s) || throw(NonLazyFieldException(T, s))
    return setfield!(x, s, uninit)
end

"""
    @uninit! f.b

Uninitialize the field `b` in the object `f`
Throw a `NonLazyFieldException` if `b` is not a lazy field
of `a`.
Macro version of [`uninit`](@ref)

```jldoctest
julia> @lazy struct Foo
           @lazy b::Int
       end

julia> f = Foo(uninit)
Foo(uninit)

julia> @isinit f.b
false

julia> @init! f.b = 5
5

julia> @isinit f.b
true
```
"""
macro uninit!(expr)
    _check_getproperty_expr(expr, "@uninit!")
    return :(uninit!($(esc.(expr.args)...)))
end

global in_lazy_struct
"""
    @lazy struct Foo
        a::Int
        @lazy b::Int
        @lazy c::Float64
    end

Make a struct `Foo` with the lazy fields `b` and `c`.
"""
macro lazy(expr)
    if expr isa Expr && expr.head === :struct
        try
            global in_lazy_struct = true
            return lazy_struct(expr)
        finally
            global in_lazy_struct = false
        end
    elseif expr isa Expr && expr.head === :(::) && length(expr.args) == 2
        return lazy_field(expr)
    else
        _throw_invalid_usage()
    end
end

function lazy_field(expr)
    # expr is checked for correct form in @lazy
    in_lazy_struct || error("@lazy macro use outside of @lazy struct")
    name, T = expr.args
    :($(esc(name))::Union{$Uninitialized, $(esc(T))})
end

function lazy_struct(expr)
    mutable, structdef, body = expr.args
    structname = if structdef isa Symbol
        structdef
    elseif structdef isa Expr && structdef.head === :curly
        structdef.args[1]
    else
        error("internal error: unhandled expression $expr")
    end

    expr.args[1] = true # make mutable
    lazyfield = QuoteNode[]
    for (i, arg) in enumerate(body.args)
        if arg isa Expr && arg.head === :macrocall && arg.args[1] === Symbol("@lazy")
            body.args[i] = macroexpand(@__MODULE__, arg)
            name = body.args[i].args[1]
            @assert name isa Symbol
            push!(lazyfield, QuoteNode(name))
        end
    end

    if length(lazyfield) == 0
        error("expected a @lazy field inside the struct")
    end

    checks = foldr((a,b)->:(s === $a || $b), lazyfield[1:end-1]; init=:(s === $(lazyfield[end])))
    ret = Expr(:block)
    push!(ret.args, quote
        $(esc(expr))
        # is @pure overkill?
        Base.@pure $(LazilyInitializedFields).islazyfield(::Type{<:$(esc(structname))}, s::Symbol) = $checks
        function Base.getproperty(x::$(esc(structname)), s::Symbol)
            if $(LazilyInitializedFields).islazyfield($(esc(structname)), s)
                r = Base.getfield(x, s)
                r isa $Uninitialized && throw(UninitializedFieldException(typeof(x), s))
                return r
            end
            return Base.getfield(x, s)
        end
    end)
    if !mutable
        push!(ret.args, quote
            function Base.setproperty!(x::$(esc(structname)), s::Symbol, v)
                error("setproperty! for struct of type `", $(esc(structname)), "` has been disabled")
            end
        end)
    end
    return ret
end

end
