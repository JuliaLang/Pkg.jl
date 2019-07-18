# This file is a part of Julia. License is MIT: https://julialang.org/license

const TYPE = Union{AbstractDict,AbstractArray,AbstractString,DateTime,Bool}

"Identify if character in subset of bare key symbols"
isbare(c::AbstractChar) = 'A' <= c <= 'Z' || 'a' <= c <= 'z' || isdigit(c) || c == '-' || c == '_'

function printkey(io::IO, keys::Vector{String})
    for (i, k) in enumerate(keys)
        i != 1 && Base.print(io, ".")
        if length(k) == 0
            # empty key
            Base.print(io, "\"\"")
        elseif !all([isbare(c) for c in k])
            # quoted key
            Base.print(io, "\"$(escape_string(k))\"")
        else
            Base.print(io, k)
        end
    end
end

function printvalue(io::IO, value::AbstractArray; sorted=false)
    Base.print(io, "[")
    for (i, x) in enumerate(value)
        i != 1 && Base.print(io, ", ")
        if isa(x, AbstractDict)
            _print(io, x, sorted=sorted)
        else
            printvalue(io, x, sorted=sorted)
        end
    end
    Base.print(io, "]")
end
printvalue(io::IO, value::AbstractDict; sorted=false) =
    _print(io, value, sorted=sorted)
printvalue(io::IO, value::DateTime; sorted=false) =
    Base.print(io, Dates.format(value, dateformat"YYYY-mm-dd\THH:MM:SS.sss\Z"))
printvalue(io::IO, value::Bool; sorted=false) =
    Base.print(io, value ? "true" : "false")
printvalue(io::IO, value::Integer; sorted=false) =
    Base.print(io, Int(value))  # TOML specifies 64-bit signed long range for integer
printvalue(io::IO, value::AbstractFloat; sorted=false) =
    Base.print(io, Float64(value))  # TOML specifies IEEE 754 binary64 for float
printvalue(io::IO, value; sorted=false) =
    Base.print(io, "\"$(escape_string(string(value)))\"")

is_table(value)           = isa(value, AbstractDict)
is_array_of_tables(value) = isa(value, AbstractArray) &&
                            length(value) > 0 && isa(value[1], AbstractDict)
is_tabular(value)         = is_table(value) || is_array_of_tables(value)

function _print(io::IO, a::AbstractDict,
    ks::Vector{String} = String[];
    indent::Int = 0,
    first_block::Bool = true,
    sorted::Bool = false,
    by = identity,
)
    akeys = keys(a)
    if sorted
        akeys = sort!(collect(akeys), by = by)
    end

    for key in akeys
        value = a[key]
        is_tabular(value) && continue
        Base.print(io, ' '^4max(0,indent-1))
        printkey(io, [String(key)])
        Base.print(io, " = ") # print separator
        printvalue(io, value, sorted = sorted)
        Base.print(io, "\n")  # new line?
        first_block = false
    end

    for key in akeys
        value = a[key]
        if is_table(value)
            push!(ks, String(key))
            header = !all(is_tabular(v) for v in values(value))
            if header
                # print table
                first_block || println(io)
                first_block = false
                Base.print(io, ' '^4indent)
                Base.print(io,"[")
                printkey(io, ks)
                Base.print(io,"]\n")
            end
            _print(io, value, ks,
                indent = indent + header, first_block = header, sorted = sorted, by = by)
            pop!(ks)
        elseif is_array_of_tables(value)
            # print array of tables
            first_block || println(io)
            first_block = false
            push!(ks, String(key))
            for v in value
                Base.print(io, ' '^4indent)
                Base.print(io,"[[")
                printkey(io, ks)
                Base.print(io,"]]\n")
                !isa(v, AbstractDict) && error("array should contain only tables")
                _print(io, v, ks, indent = indent + 1, sorted = sorted, by = by)
            end
            pop!(ks)
        end
    end
end

print(io::IO, a::AbstractDict; kwargs...) = _print(io, a; kwargs...)
print(a::AbstractDict; kwargs...) = print(stdout, a; kwargs...)
