# TODO: Overload
function compat(ctx::Context; io = nothing)
    io = something(io, ctx.io)
    can_fancyprint(io) || pkgerror("Pkg.compat cannot be run interactively in this terminal")
    printpkgstyle(io, :Compat, pathrepr(ctx.env.project_file))
    longest_dep_len = max(5, length.(collect(keys(ctx.env.project.deps)))...)
    opt_strs = String[]
    opt_pkgs = String[]
    compat_str = Operations.get_compat_str(ctx.env.project, "julia")
    push!(opt_strs, Operations.compat_line(io, "julia", nothing, compat_str, longest_dep_len, indent = ""))
    push!(opt_pkgs, "julia")
    for (dep, uuid) in sort(collect(ctx.env.project.deps); by = x->x.first)
        compat_str = Operations.get_compat_str(ctx.env.project, dep)
        push!(opt_strs, Operations.compat_line(io, dep, uuid, compat_str, longest_dep_len, indent = ""))
        push!(opt_pkgs, dep)
    end
    menu = TerminalMenus.RadioMenu(opt_strs, pagesize=length(opt_strs))
    choice = try
        TerminalMenus.request("  Select an entry to edit:", menu)
    catch err
        if err isa InterruptException # if ^C is entered
            println(io)
            return false
        end
        rethrow()
    end
    choice == -1 && return false
    dep = opt_pkgs[choice]
    current_compat_str = something(Operations.get_compat_str(ctx.env.project, dep), "")
    resp = try
        prompt = "  Edit compat entry for $(dep):"
        print(io, prompt)
        buffer = current_compat_str
        cursor = length(buffer)
        start_pos = length(prompt) + 2
        move_start = "\e[$(start_pos)G"
        clear_to_end = "\e[0J"
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), stdin.handle, true)
        while true
            print(io, move_start, clear_to_end, buffer, "\e[$(start_pos + cursor)G")
            inp = TerminalMenus._readkey(stdin)
            if inp == '\r' # Carriage return
                println(io)
                break
            elseif inp == '\x03' # cltr-C
                println(io)
                return
            elseif inp == TerminalMenus.ARROW_RIGHT
                cursor = min(length(buffer), cursor + 1)
            elseif inp == TerminalMenus.ARROW_LEFT
                cursor = max(0, cursor - 1)
            elseif inp == TerminalMenus.HOME_KEY
                cursor = (0)
            elseif inp == TerminalMenus.END_KEY
                cursor = length(buffer)
            elseif inp == TerminalMenus.DEL_KEY
                if cursor == 0
                    buffer = buffer[2:end]
                elseif cursor < length(buffer)
                    buffer = buffer[1:cursor] * buffer[(cursor + 2):end]
                end
            elseif inp isa TerminalMenus.Key
                # ignore all other escaped (multi-byte) keys
            elseif inp == '\x7f' # backspace
                if cursor == 1
                    buffer = buffer[2:end]
                elseif cursor == length(buffer)
                    buffer = buffer[1:end - 1]
                elseif cursor > 0
                    buffer = buffer[1:(cursor-1)] * buffer[(cursor + 1):end]
                else
                    continue
                end
                cursor -= 1
            else
                if cursor == 0
                    buffer = inp * buffer
                elseif cursor == length(buffer)
                    buffer = buffer * inp
                else
                    buffer = buffer[1:cursor] * inp * buffer[(cursor + 1):end]
                end
                cursor += 1
            end
        end
        buffer
    finally
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), stdin.handle, false)
    end
    new_entry = strip(resp)
    compat(ctx, dep, string(new_entry))
    return
end
