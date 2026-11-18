# Method redefinitions applied when compiling Pkg with `--trim`.

# Compile-time switch that removes code paths a trimmed binary can not have.
@eval Pkg trimmed() = true

# A trimmed binary leaves `stdout`/`stderr` as `Core.stdout`/`Core.stderr`, so the stream
# behind Pkg's `IOContext{IO}` is one of a few concrete types.
@eval Base begin
    @inline function _pkg_trim_split(f::F, io::IO) where {F}
        io isa Core.CoreSTDOUT && return f(io)
        io isa Core.CoreSTDERR && return f(io)
        io isa IOBuffer && return f(io)
        io isa IOStream && return f(io)
        io isa DevNull && return f(io)
        throw(ArgumentError("unsupported stream in a trimmed binary"))
    end
    write(io::IOContext{IO}, byte::UInt8) = _pkg_trim_split(x -> write(x, byte), io.io)
    unsafe_write(io::IOContext{IO}, p::Ptr{UInt8}, nb::UInt; cancel::CancelTokenArg = DEFAULT_CANCEL) =
        _pkg_trim_split(x -> unsafe_write(x, p, nb), io.io)
    flush(io::IOContext{IO}) = _pkg_trim_split(flush, io.io)
    isopen(io::IOContext{IO}) = _pkg_trim_split(isopen, io.io)
    iswritable(io::IOContext{IO}) = _pkg_trim_split(iswritable, io.io)
    close(io::IOContext{IO}) = _pkg_trim_split(close, io.io)
    lock(io::IOContext{IO}) = _pkg_trim_split(lock, io.io)
    unlock(io::IOContext{IO}) = _pkg_trim_split(unlock, io.io)
    displaysize(io::IOContext{IO}) = haskey(io, :displaysize) ? io[:displaysize]::Tuple{Int, Int} :
        _pkg_trim_split(displaysize, io.io)::Tuple{Int, Int}
end

# `Context.io` is typed `IO`; in a trimmed binary it always holds `stderr_f()`/`stdout_f()`
@eval Pkg.Types Base.getproperty(ctx::Context, s::Symbol) =
    s === :io ? getfield(ctx, :io)::IOContext{IO} : getfield(ctx, s)
