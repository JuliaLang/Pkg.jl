# Overrides that make process spawning, `Cmd` display and `VersionNumber` hashing pass
# `juliac --trim=safe`. Mirror of the Base branch `kc/trim-process-version`, except that
# the fallbacks for IO / command types not defined in Base throw instead of dispatching
# dynamically.

@eval Base begin
    @noinline _trim_unsupported(@nospecialize(x)) =
        error("type `", typeof(x).name.name, "` is not supported here under --trim")

    ## version.jl (already on julia master)
    function hash(v::VersionNumber, h::UInt)
        h ⊻= 0x8ff4ffdb75f9fede % UInt
        h = hash(v.major, h)
        h = hash(v.minor, h)
        h = hash(v.patch, h)
        h = hash_idents(v.prerelease, ~h)
        h = hash_idents(v.build, ~h)
    end
    function hash_idents(@nospecialize(t::VerTuple), h::UInt)
        h ⊻= tuplehash_seed
        for i in length(t):-1:1
            h = hash(t[i]::Union{UInt64,String}, h)
        end
        return h
    end

    ## process.jl
    rawhandle(io::SyncCloseFD) = rawhandle(io.fd::OS_HANDLE)
    close_stdio(stdio::SyncCloseFD) = close_stdio(stdio.fd::OS_HANDLE)

    function _setup_stdio(@nospecialize(stdio), readable::Bool)
        stdio isa Union{DevNull,OS_HANDLE,RawFD} && return setup_stdio(stdio, readable)
        stdio isa PipeEndpoint && return setup_stdio(stdio, readable)
        stdio isa TTY && return setup_stdio(stdio, readable)
        stdio isa FileRedirect && return setup_stdio(stdio, readable)
        stdio isa IOStream && return setup_stdio(stdio, readable)
        stdio isa Filesystem.File && return setup_stdio(stdio, readable)
        stdio isa Pipe && return setup_stdio(stdio, readable)
        stdio isa Process && return setup_stdio(stdio, readable)
        stdio isa ProcessChain && return setup_stdio(stdio, readable)
        stdio isa IOBuffer && return setup_stdio(stdio, readable)
        stdio isa IOContext{IOBuffer} && return setup_stdio(stdio, readable)
        stdio isa BufferStream && return setup_stdio(stdio, readable)
        stdio isa Core.CoreSTDERR && return setup_stdio(stdio, readable)
        stdio isa Core.CoreSTDOUT && return setup_stdio(stdio, readable)
        _trim_unsupported(stdio)
    end
    setup_stdio(stdio::AbstractPipe, readable::Bool) =
        _setup_stdio(readable ? pipe_reader(stdio) : pipe_writer(stdio), readable)

    function setup_stdio(stdio::IO, child_readable::Bool)
        parent = PipeEndpoint()
        rd, wr = link_pipe(!child_readable, child_readable)
        try
            open_pipe!(parent, child_readable ? wr : rd)
        catch
            close_pipe_sync(rd)
            close_pipe_sync(wr)
            rethrow()
        end
        child = child_readable ? rd : wr
        try
            # one task per direction, so that each task body has concrete types
            t = child_readable ? @async(_copy_stdio(parent, stdio, parent)) :
                                 @async(_copy_stdio(stdio, parent, parent))
            return (SyncCloseFD(child, t), true)
        catch
            close_pipe_sync(child)
            rethrow()
        end
    end
    function _copy_stdio(in::IO, out::IO, parent::PipeEndpoint)
        try
            write(in, out)
        catch ex
            @warn "Process I/O error" exception=(ex, catch_backtrace())
            rethrow()
        finally
            close(parent)
        end
    end

    function _close_stdio(@nospecialize(stdio))
        stdio isa OS_HANDLE && return close_stdio(stdio)
        stdio isa SyncCloseFD && return close_stdio(stdio)
        stdio isa Filesystem.File && return close_stdio(stdio)
        _trim_unsupported(stdio)
    end

    function _rawhandle(@nospecialize(io))
        io isa SyncCloseFD && return rawhandle(io)
        io isa Union{DevNull,OS_HANDLE,RawFD} && return rawhandle(io)
        io isa PipeEndpoint && return rawhandle(io)
        io isa TTY && return rawhandle(io)
        io isa Filesystem.File && return rawhandle(io)
        _trim_unsupported(io)
    end

    function setup_stdios(f, stdios::Vector{Redirectable})
        nstdio = length(stdios)
        open_io = SpawnIOs(undef, nstdio)
        close_io = falses(nstdio)
        try
            for i in 1:nstdio
                open_io[i], close_io[i] = _setup_stdio(stdios[i], i == 1)
            end
            pp = f(open_io)
            return pp
        finally
            for i in 1:nstdio
                close_io[i] && _close_stdio(open_io[i])
            end
        end
    end

    function _spawn_cmd(@nospecialize(cmd::AbstractCmd), stdios::SpawnIOs, tok::MaybeToken)
        cmd isa Cmd && return _spawn(cmd, stdios, tok)
        cmd isa CmdRedirect && return _spawn(cmd, stdios, tok)
        cmd isa OrCmds && return _spawn(cmd, stdios, tok)
        cmd isa ErrOrCmds && return _spawn(cmd, stdios, tok)
        cmd isa AndCmds && return _spawn(cmd, stdios, tok)
        _trim_unsupported(cmd)
    end
    function _spawn_cmd(@nospecialize(cmd::AbstractCmd), stdios::SpawnIOs, chain::ProcessChain, tok::MaybeToken)
        cmd isa Cmd && return _spawn(cmd, stdios, chain, tok)
        cmd isa CmdRedirect && return _spawn(cmd, stdios, chain, tok)
        cmd isa OrCmds && return _spawn(cmd, stdios, chain, tok)
        cmd isa ErrOrCmds && return _spawn(cmd, stdios, chain, tok)
        cmd isa AndCmds && return _spawn(cmd, stdios, chain, tok)
        _trim_unsupported(cmd)
    end

    function _spawn(redirect::CmdRedirect, stdios::SpawnIOs, tok::MaybeToken=default_cancel_token())
        fdnum = redirect.stream_no + 1
        io, close_io = _setup_stdio(redirect.handle, redirect.readable)
        try
            stdios = _stdio_copy(stdios, fdnum, io)
            return _spawn_cmd(redirect.cmd, stdios, tok)
        finally
            close_io && _close_stdio(io)
        end
    end
    function _spawn(redirect::CmdRedirect, stdios::SpawnIOs, chain::ProcessChain, tok::MaybeToken)
        fdnum = redirect.stream_no + 1
        io, close_io = _setup_stdio(redirect.handle, redirect.readable)
        try
            stdios = _stdio_copy(stdios, fdnum, io)
            return _spawn_cmd(redirect.cmd, stdios, chain, tok)
        finally
            close_io && _close_stdio(io)
        end
    end
    function _spawn(cmds::OrCmds, stdios::SpawnIOs, chain::ProcessChain, tok::MaybeToken)
        in_pipe, out_pipe = link_pipe(false, false)
        try
            stdios_left = _stdio_copy(stdios, 2, out_pipe)
            _spawn_cmd(cmds.a, stdios_left, chain, tok)
            stdios_right = _stdio_copy(stdios, 1, in_pipe)
            _spawn_cmd(cmds.b, stdios_right, chain, tok)
        finally
            close_pipe_sync(out_pipe)
            close_pipe_sync(in_pipe)
        end
        return chain
    end
    function _spawn(cmds::ErrOrCmds, stdios::SpawnIOs, chain::ProcessChain, tok::MaybeToken)
        in_pipe, out_pipe = link_pipe(false, false)
        try
            stdios_left = _stdio_copy(stdios, 3, out_pipe)
            _spawn_cmd(cmds.a, stdios_left, chain, tok)
            stdios_right = _stdio_copy(stdios, 1, in_pipe)
            _spawn_cmd(cmds.b, stdios_right, chain, tok)
        finally
            close_pipe_sync(out_pipe)
            close_pipe_sync(in_pipe)
        end
        return chain
    end
    function _spawn(cmds::AndCmds, stdios::SpawnIOs, chain::ProcessChain, tok::MaybeToken)
        _spawn_cmd(cmds.a, stdios, chain, tok)
        _spawn_cmd(cmds.b, stdios, chain, tok)
        return chain
    end

@noinline function _spawn_primitive(file, cmd::Cmd, stdio::SpawnIOs,
                                    tok::MaybeToken=default_cancel_token())
    # Entry cancellation check before the child exists: a spawn under an
    # already-cancelled token must not run the command (its side effects
    # cannot be taken back). `tok` is the *resolved* token of the public
    # operation (run/open/success/read), threaded down here so an explicit
    # token - or an explicit `cancel = nothing` shield - governs the spawn
    # itself, not whatever the ambient scope happens to be.
    @cancel_check tok
    loop = eventloop()
    cpumask = cmd.cpus
    cpumask === nothing || (cpumask = as_cpumask(cpumask))
    GC.@preserve stdio begin
        iohandles = Tuple{Cint, UInt}[ # assuming little-endian layout
            let h = _rawhandle(io)
                h === C_NULL     ? (0x00, UInt(0)) :
                h isa OS_HANDLE  ? (0x02, UInt(cconvert(@static(Sys.iswindows() ? Ptr{Cvoid} : Cint), h))) :
                h isa Ptr{Cvoid} ? (0x04, UInt(h)) :
                error(lazy"invalid spawn handle $h from $io")
            end
            for io in stdio]
        syncd = Task[io.t for io in stdio if io isa SyncCloseFD]
        handle = Libc.malloc(_sizeof_uv_process)
        disassociate_julia_struct(handle)
        (; exec, flags, env, dir, uid, gid) = cmd
        flags ⊻= UV_PROCESS_WINDOWS_DISABLE_EXACT_NAME # libuv inverts the default for this, so flip this bit now
        if uid !== nothing
            flags |= UV_PROCESS_SETUID
        end
        if gid !== nothing
            flags |= UV_PROCESS_SETGID
        end
        iolock_begin()
        err = ccall(:jl_spawn, Int32,
                  (Cstring, Ptr{Cstring}, Ptr{Cvoid}, Ptr{Cvoid},
                   Ptr{Tuple{Cint, UInt}}, Int,
                   UInt32, Ptr{Cstring}, Cstring, Ptr{Bool}, Csize_t,
                   UInt32, UInt32, Ptr{Cvoid}),
            file, exec, loop, handle,
            iohandles, length(iohandles),
            flags,
            env === nothing ? C_NULL : env,
            isempty(dir) ? C_NULL : dir,
            cpumask === nothing ? C_NULL : cpumask,
            cpumask === nothing ? 0 : length(cpumask),
            uid === nothing ? typemax(UInt32) : uid,
            gid === nothing ? typemax(UInt32) : gid,
            @cfunction(uv_return_spawn, Cvoid, (Ptr{Cvoid}, Int64, Int32)))
        if err == 0
            pp = Process(cmd, handle, syncd)
            associate_julia_struct(handle, pp)
            iolock_end()
            return pp
        else
            ccall(:jl_forceclose_uv, Cvoid, (Ptr{Cvoid},), handle) # will call free on handle eventually
            iolock_end()
            throw(_UVError("could not spawn " * repr(cmd), err))
        end
    end
end

    function read(cmd::AbstractCmd; cancel::CancelTokenArg=DEFAULT_CANCEL)
        tok = resolve_cancel_token(cancel)
        @cancel_check tok
        procs = open(cmd, "r", devnull; cancel=tok)
        out = procs.out::PipeEndpoint
        bytes = tok === nothing ? read(out; cancel=nothing) : read(out; cancel=tok)
        success(procs; cancel=tok) || pipeline_error(procs)
        return bytes::Vector{UInt8}
    end

    const _ProcessPipe = Union{Process,ProcessChain}
    ## io.jl: `AbstractPipe` forwarding
    @inline function _pipe_split(f::F, io::IO) where {F}
        io isa PipeEndpoint && return f(io)
        io isa DevNull && return f(io)
        _trim_unsupported(io)
    end
    iswritable(io::_ProcessPipe) = _pipe_split(iswritable, pipe_writer(io)::IO)
    write(io::_ProcessPipe, byte::UInt8) = _pipe_split(w -> write(w, byte), pipe_writer(io)::IO)
    unsafe_write(io::_ProcessPipe, p::Ptr{UInt8}, nb::UInt; cancel::CancelTokenArg=DEFAULT_CANCEL) =
        _pipe_split(pipe_writer(io)::IO) do w
            cancel === DEFAULT_CANCEL ? unsafe_write(w, p, nb) : unsafe_write(w, p, nb; cancel)
        end::Union{Int,UInt}
    readavailable(io::_ProcessPipe; cancel::CancelTokenArg=DEFAULT_CANCEL) =
        _pipe_split(pipe_reader(io)::IO) do r
            cancel === DEFAULT_CANCEL ? readavailable(r) : readavailable(r; cancel)
        end
    read(io::_ProcessPipe, byte::Type{UInt8}; cancel::CancelTokenArg=DEFAULT_CANCEL) =
        _pipe_split(pipe_reader(io)::IO) do r
            cancel === DEFAULT_CANCEL ? read(r, byte) : read(r, byte; cancel)
        end::UInt8
    unsafe_read(io::_ProcessPipe, p::Ptr{UInt8}, nb::UInt) = _pipe_split(r -> unsafe_read(r, p, nb), pipe_reader(io)::IO)
    readbytes!(io::_ProcessPipe, target::AbstractVector{UInt8}, n=length(target); cancel::CancelTokenArg=DEFAULT_CANCEL) =
        _pipe_split(pipe_reader(io)::IO) do r
            cancel === DEFAULT_CANCEL ? readbytes!(r, target, n) : readbytes!(r, target, n; cancel)
        end
    wait_readnb(io::_ProcessPipe, nb::Int) = _pipe_split(r -> wait_readnb(r, nb), pipe_reader(io)::IO)
    eof(io::_ProcessPipe; cancel::CancelTokenArg=DEFAULT_CANCEL) =
        _pipe_split(pipe_reader(io)::IO) do r
            cancel === DEFAULT_CANCEL ? eof(r) : eof(r; cancel)
        end::Bool
    isopen(io::_ProcessPipe) = _pipe_split(isopen, pipe_writer(io)::IO) || _pipe_split(isopen, pipe_reader(io)::IO)
    close(io::_ProcessPipe) = (_pipe_split(close, pipe_writer(io)::IO); _pipe_split(close, pipe_reader(io)::IO))
    wait_close(io::_ProcessPipe) = (_pipe_split(wait_close, pipe_writer(io)::IO); _pipe_split(wait_close, pipe_reader(io)::IO))


    # `show(io, collect(Int, cpus))` without the generic array printing
    function show_cpus(io::IO, cpus::Vector{UInt16})
        isempty(cpus) && return print(io, "Int", Sys.WORD_SIZE, "[]")
        print(io, '[')
        join(io, cpus, ", ")
        print(io, ']')
    end
    function show(io::IO, cmd::Cmd)
        env = cmd.env
        if env !== nothing && get_show_env_mode(io) === :none
            env = nothing
        end
        print_env = env !== nothing
        print_dir = !isempty(cmd.dir)
        print_uid = cmd.uid !== nothing
        print_gid = cmd.gid !== nothing
        print_cpus = cmd.cpus !== nothing

        (print_env || print_dir) && print(io, "setenv(")
        print_cpus && print(io, "setcpuaffinity(")
        print_gid && print(io, "setgid(")
        print_uid && print(io, "setuid(")

        print(io, '`')
        join(io, map(arg -> sprint(_show_cmd_word, arg, true; context=io), cmd.exec), ' ')
        print(io, '`')

        print_uid && (print(io, ", "); show(io, Int64(cmd.uid)); print(io, ")"))
        print_gid && (print(io, ", "); show(io, Int64(cmd.gid)); print(io, ")"))
        if print_cpus
            print(io, ", ")
            show_cpus(io, something(cmd.cpus))
            print(io, ")")
        end
        if print_env || print_dir
            env === nothing || (print(io, ","); show_env(io, env))
            print_dir && (print(io, "; dir="); show(io, cmd.dir))
            print(io, ")")
        end
        nothing
    end

    function uv_readcb(handle::Ptr{Cvoid}, nread::Cssize_t, buf::Ptr{Cvoid})
        stream_unknown_type = @handle_as handle LibuvStream
        nrequested = ccall(:jl_uv_buf_len, Csize_t, (Ptr{Cvoid},), buf)
        function readcb_specialized(stream::LibuvStream, nread::Int, nrequested::UInt)
            lock(stream.cond)
            if nread < 0
                if nread == UV_ENOBUFS && nrequested == 0
                    # remind the client that stream.buffer is full
                    notify(stream.cond)
                elseif nread == UV_EOF # libuv called uv_stop_reading already
                    if stream.status != StatusClosing
                        stream.status = StatusEOF
                        notify(stream.cond)
                        if stream isa TTY
                            # stream can still be used by reseteof (or possibly write)
                        elseif !(stream isa PipeEndpoint) && ccall(:uv_is_writable, Cint, (Ptr{Cvoid},), stream.handle) != 0
                            # stream can still be used by write
                        else
                            # underlying stream is no longer useful: begin finalization
                            ccall(:jl_close_uv, Cvoid, (Ptr{Cvoid},), stream.handle)
                            stream.status = StatusClosing
                        end
                    end
                else
                    stream.readerror = _UVError("read", nread)
                    notify(stream.cond)
                    # This is a fatal connection error
                    ccall(:jl_close_uv, Cvoid, (Ptr{Cvoid},), stream.handle)
                    stream.status = StatusClosing
                end
            else
                notify_filled(stream.buffer, nread)
                notify(stream.cond)
            end
            unlock(stream.cond)

            # Stop background reading when
            # 1) there's nobody paying attention to the data we are reading
            # 2) we have accumulated a lot of unread data OR
            # 3) we have an alternate buffer that has reached its limit.
            if stream.status == StatusPaused ||
               (stream.status == StatusActive &&
                ((bytesavailable(stream.buffer) >= stream.throttle) ||
                 (bytesavailable(stream.buffer) >= stream.buffer.maxsize)))
                # save cycles by stopping kernel notifications from arriving
                ccall(:uv_read_stop, Cint, (Ptr{Cvoid},), stream)
                stream.status = StatusOpen
            end
            nothing
        end
        if stream_unknown_type isa PipeEndpoint
            readcb_specialized(stream_unknown_type, Int(nread), UInt(nrequested))
        elseif stream_unknown_type isa TTY
            readcb_specialized(stream_unknown_type, Int(nread), UInt(nrequested))
        else
            _trim_unsupported(stream_unknown_type)
        end
        nothing
    end

    ## asyncevent.jl: the error is printed without dispatching on `stderr` and `err`
    function Timer(cb::Function, timeout; spawn::Union{Nothing,Bool}=nothing, kwargs...)
        sticky = spawn === nothing ? current_task().sticky : !spawn
        timer = Timer(timeout; kwargs...)
        # The callback task carries the timer's lifetime (its preserve is
        # balanced in the body): shield it from the constructing scope's
        # cancellation token, so a cancelled scope can neither leak the preserve
        # nor stop the timer - `close(timer)` is what ends it.
        t = ScopedValues.with(CANCEL_TOKEN => nothing) do
            @task begin
                unpreserve_handle(timer)
                while _trywait(timer)
                    try
                        cb(timer)
                    catch err
                        showerror_nostdio(err, "Error in Timer")
                        return
                    end
                    isopen(timer) || return
                end
            end
        end
        t.sticky = sticky
        # here we are mimicking parts of _trywait, in coordination with task `t`
        preserve_handle(timer)
        @lock timer.cond begin
            if timer.set
                schedule(t)
            else
                schedule_on_notify!(timer.cond, t)
            end
        end
        return timer
    end

    ## cmd.jl
    setenv(cmd::Cmd, env; dir=cmd.dir) =
        Cmd(cmd, cmd.ignorestatus, cmd.flags, byteenv(env), dir, cmd.cpus, cmd.uid, cmd.gid)

    function _show_cmd_word(io::IO, word::AbstractString, underline::Bool)
        special = startswith(word, '~') ? _shell_display_special * '~' : _shell_display_special
        s = sprint(print_shell_word, word, special; context=io)
        if underline && get(io, :color, false)::Bool
            s = output_color_string(IOBuffer(), s, :underline, false, false, false, false, false, false)
        end
        print(io, replace(s, '`' => "\\`"))
    end
end

for f in (:mark, :unmark, :reset, :ismarked, :read, :bytesavailable, :reseteof, :isreadable)
    @eval Base $(f)(io::_ProcessPipe) = _pipe_split($(f), pipe_reader(io)::IO)
end
for f in (:flush, :closewrite)
    @eval Base $(f)(io::_ProcessPipe; cancel::CancelTokenArg=DEFAULT_CANCEL) =
        _pipe_split(pipe_writer(io)::IO) do w
            cancel === DEFAULT_CANCEL ? $(f)(w) : $(f)(w; cancel)
        end
end

# `open(f, cmd)` uses the `in`/`out`/`err` fields of the process directly (Pkg reads 7z output this way)
@eval Base function open(f::Function, cmds::AbstractCmd, args...; kwargs...)
    P = open(cmds, args...; kwargs...)
    function waitkill(P::Union{Process,ProcessChain})
        close(P)
        local t = Timer(2) do t
            process_running(P) && kill(P)
        end
        wait(P, false)
        close(t)
    end
    ret = try
        f(P)
    catch
        waitkill(P)
        rethrow()
    end
    _pipe_split(close, P.in::IO)
    closestdio = @async begin
        wait(P)
        _pipe_split(x -> x isa PipeEndpoint && closewrite(x), P.err::IO)
        _pipe_split(x -> x isa PipeEndpoint && closewrite(x), P.out::IO)
        nothing
    end
    if !(_pipe_split(eof, P.out::IO)::Bool)
        waitkill(P)
        throw(_UVError("open(do)", UV_EPIPE))
    end
    wait(closestdio)
    success(P) || pipeline_error(P)
    return ret
end
