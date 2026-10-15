module PicoSAT

using libpicosat_jll

const lib = libpicosat

const UNKNOWN = 0
const SATISFIABLE = 10
const UNSATISFIABLE = 20

init() =
    ccall((:picosat_init, lib), Ptr{Cvoid}, ())
reset(p::Ptr{Cvoid}) =
    ccall((:picosat_reset, lib), Cvoid, (Ptr{Cvoid},), p)
adjust(p::Ptr{Cvoid}, N::Integer) =
    ccall((:picosat_adjust, lib), Cvoid, (Ptr{Cvoid}, Cint), p, N)
add(p::Ptr{Cvoid}, v::Integer) =
    ccall((:picosat_add, lib), Cint, (Ptr{Cvoid}, Cint), p, v)
assume(p::Ptr{Cvoid}, v::Integer) =
    ccall((:picosat_assume, lib), Cint, (Ptr{Cvoid}, Cint), p, v)
set_default_phase_lit(p::Ptr{Cvoid}, lit::Integer, phase::Integer) =
    ccall((:picosat_set_default_phase_lit, lib), Cvoid,
          (Ptr{Cvoid}, Cint, Cint), p, lit, phase)
set_global_default_phase(p::Ptr{Cvoid}, phase::Integer) =
    ccall((:picosat_set_global_default_phase, lib), Cvoid,
          (Ptr{Cvoid}, Cint), p, phase)
sat(p::Ptr{Cvoid}, limit::Integer = -1) =
    ccall((:picosat_sat, lib), Cint, (Ptr{Cvoid}, Cint), p, limit)
deref(p::Ptr{Cvoid}, v::Integer) =
    ccall((:picosat_deref, lib), Cint, (Ptr{Cvoid}, Cint), p, v)
failed(p::Ptr{Cvoid}, v::Integer) =
    ccall((:picosat_failed_assumption, lib), Cint, (Ptr{Cvoid}, Cint), p, v)
push(p::Ptr{Cvoid}) =
    ccall((:picosat_push, lib), Cint, (Ptr{Cvoid},), p)
pop(p::Ptr{Cvoid}) =
    ccall((:picosat_pop, lib), Cint, (Ptr{Cvoid},), p)
var_count(p::Ptr{Cvoid}) =
    ccall((:picosat_variables, lib), Cint, (Ptr{Cvoid},), p)
clause_count(p::Ptr{Cvoid}) =
    ccall((:picosat_added_original_clauses, lib), Cint, (Ptr{Cvoid},), p)
inc_max_var(p::Ptr{Cvoid}) =
    ccall((:picosat_inc_max_var, lib), Cint, (Ptr{Cvoid},), p)

# for debugging by exporting CNF files
function print(p::Ptr{Cvoid}, path::AbstractString)
    f = ccall(:fopen, Ptr{Cvoid}, (Cstring, Cstring), path, "w")
    ccall((:picosat_print, lib), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), p, f)
    @assert ccall(:fclose, Cint, (Ptr{Cvoid},), f) == 0
end

end # module
