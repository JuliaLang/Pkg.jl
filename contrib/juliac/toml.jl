# `Base.TOML.Printer` prints the value types that `TOML.parse` returns without dynamic
# dispatch and sends values of other types through `printvalue_generic` / `_invoke_generic`.
# A trimmed binary can not dispatch dynamically, so here the Dates types (which Dates
# supports by extending `printvalue` / `is_valid_toml_value`) are handled explicitly and
# values of any other type are an error.
import Dates
@eval Base.TOML.Printer begin
    _is_valid_toml_value(@nospecialize(x)) =
        x isa BaseTOMLValue || x isa $(Dates.DateTime) || x isa $(Dates.Date) || x isa $(Dates.Time)
    function printvalue_generic(f::Function, io::IO, @nospecialize(value), sorted::Bool)
        value isa $(Dates.DateTime) && return printvalue(f, io, value, sorted)
        value isa $(Dates.Date) && return printvalue(f, io, value, sorted)
        value isa $(Dates.Time) && return printvalue(f, io, value, sorted)
        error("TOML.print: values of type `", typeof(value), "` are not supported in a trimmed binary")
    end
    _invoke_generic(@nospecialize(f), @nospecialize(args...)) =
        error("TOML.print: value not supported in a trimmed binary, use `Dict{String, Any}` tables")
end
