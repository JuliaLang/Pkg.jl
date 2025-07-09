module MiniProgressBars

export MiniProgressBar, start_progress, end_progress, show_progress, print_progress_bottom, add_child_progress, remove_child_progress, show_multi_progress, MultiProgressDisplay, start_multi_progress, stop_multi_progress, update_multi_progress

using Printf

# Until Base.format_bytes supports sigdigits
function pkg_format_bytes(bytes; binary=true, sigdigits::Integer=3)
    units = binary ? Base._mem_units : Base._cnt_units
    factor = binary ? 1024 : 1000
    bytes, mb = Base.prettyprint_getunits(bytes, length(units), Int64(factor))
    if mb == 1
        return string(Int(bytes), " ", Base._mem_units[mb], bytes==1 ? "" : "s")
    else
        return string(Base.Ryu.writefixed(Float64(bytes), sigdigits), binary ? " $(units[mb])" : "$(units[mb])B")
    end
end

Base.@kwdef mutable struct MiniProgressBar
    max::Int = 1
    header::String = ""
    color::Symbol = :nothing
    width::Int = 40
    current::Int = 0
    status::String = "" # If not empty this string replaces the bar
    prev::Int = 0
    has_shown::Bool = false
    time_shown::Float64 = 0.0
    mode::Symbol = :percentage # :percentage :int :data
    always_reprint::Bool = false
    indent::Int = 4
    main::Bool = true
    children::Vector{MiniProgressBar} = MiniProgressBar[]
    parent::Union{MiniProgressBar, Nothing} = nothing
end

const PROGRESS_BAR_TIME_GRANULARITY = Ref(1 / 30.0) # 30 fps
const PROGRESS_BAR_PERCENTAGE_GRANULARITY = Ref(0.1)

# ANSI escape codes for terminal control
const ANSI_MOVEUP(n::Int) = string("\e[", n, "A")
const ANSI_MOVECOL1 = "\e[1G"
const ANSI_CLEARTOEND = "\e[0J"
const ANSI_CLEARTOENDOFLINE = "\e[0K"
const ANSI_CLEARLINE = "\e[2K"
const ANSI_ENABLECURSOR = "\e[?25h"
const ANSI_DISABLECURSOR = "\e[?25l"

mutable struct MultiProgressDisplay
    main_bar::MiniProgressBar
    io::IO
    timer::Union{Timer, Nothing}
    is_active::Bool
    update_interval::Float64

    function MultiProgressDisplay(main_bar::MiniProgressBar, io::IO; update_interval::Float64 = 0.1)
        return new(main_bar, io, nothing, false, update_interval)
    end
end

function start_progress(io::IO, _::MiniProgressBar)
    ansi_disablecursor = "\e[?25l"
    print(io, ansi_disablecursor)
end

function show_progress(io::IO, p::MiniProgressBar; termwidth=nothing, carriagereturn=true)
    if p.max == 0
        perc = 0.0
        prev_perc = 0.0
    else
        perc = p.current / p.max * 100
        prev_perc = p.prev / p.max * 100
    end
    # Bail early if we are not updating the progress bar,
    # Saves printing to the terminal
    if !p.always_reprint && p.has_shown && !((perc - prev_perc) > PROGRESS_BAR_PERCENTAGE_GRANULARITY[])
        return
    end
    t = time()
    if !p.always_reprint && p.has_shown && (t - p.time_shown) < PROGRESS_BAR_TIME_GRANULARITY[]
        return
    end
    p.time_shown = t
    p.prev = p.current
    p.has_shown = true

    progress_text = if p.mode == :percentage
        @sprintf "%2.1f %%" perc
    elseif p.mode == :int
        string(p.current, "/",  p.max)
    elseif p.mode == :data
        lpad(string(pkg_format_bytes(p.current; sigdigits=1), "/", pkg_format_bytes(p.max; sigdigits=1)), 20)
    else
        error("Unknown mode $(p.mode)")
    end
    termwidth = @something termwidth displaysize(io)[2]
    max_progress_width = max(0, min(termwidth - textwidth(p.header) - textwidth(progress_text) - 10 , p.width))
    n_filled = floor(Int, max_progress_width * perc / 100)
    partial_filled = (max_progress_width * perc / 100) - n_filled
    n_left = max_progress_width - n_filled
    headers = split(p.header)
    to_print = sprint(; context=io) do io
        print(io, " "^p.indent)
        if p.main
            printstyled(io, headers[1], " "; color=:green, bold=true)
            length(headers) > 1 && printstyled(io, join(headers[2:end], ' '), " ")
        else
            print(io, p.header, " ")
        end
        # Show progress bar
        hascolor = get(io, :color, false)::Bool
        printstyled(io, "━"^n_filled; color = p.color)
        if n_left > 0
            if hascolor
                if partial_filled > 0.5
                    printstyled(io, "╸"; color = p.color) # More filled, use ╸
                else
                    printstyled(io, "╺"; color = :light_black) # Less filled, use ╺
                end
            end
            c = hascolor ? "━" : " "
            printstyled(io, c^(n_left - 1 + !hascolor); color = :light_black)
        end
        printstyled(io, " "; color = :light_black)
        print(io, progress_text)

        # Append status if present
        if !isempty(p.status)
            print(io, " (", p.status, ")")
        end
        carriagereturn && print(io, "\r")
    end
    # Print everything in one call
    print(io, to_print)
    return
end

function end_progress(io, p::MiniProgressBar)
    ansi_enablecursor = "\e[?25h"
    ansi_clearline = "\e[2K"
    print(io, ansi_enablecursor * ansi_clearline)
end

# Useful when writing a progress bar in the bottom
# makes the bottom progress bar not flicker
# prog = MiniProgressBar(...)
# prog.end = n
# for progress in 1:n
#     print_progress_bottom(io)
#     println("stuff")
#     prog.current = progress
#     showprogress(io, prog)
#  end
#
function print_progress_bottom(io::IO)
    ansi_clearline = "\e[2K"
    ansi_movecol1 = "\e[1G"
    ansi_moveup(n::Int) = string("\e[", n, "A")
    print(io, "\e[S" * ansi_moveup(1) * ansi_clearline * ansi_movecol1)
end

function add_child_progress(parent::MiniProgressBar, child::MiniProgressBar)
    child.parent = parent
    child.main = false
    child.indent = parent.indent + 4
    push!(parent.children, child)
    return child
end

function remove_child_progress(parent::MiniProgressBar, child::MiniProgressBar)
    idx = findfirst(==(child), parent.children)
    if idx !== nothing
        deleteat!(parent.children, idx)
        child.parent = nothing
    end
    return child
end

function show_multi_progress(io::IO, parent::MiniProgressBar; termwidth = nothing, sort_children = true, max_depth = 3)
    # Show the parent progress bar
    show_progress(io, parent; termwidth, carriagereturn = false)
    println(io)

    # Show child progress bars recursively
    _show_children(io, parent, termwidth, sort_children, max_depth, 1)
    return
end

function _show_children(io::IO, parent::MiniProgressBar, termwidth, sort_children, max_depth, current_depth)
    if current_depth > max_depth
        return
    end

    # Show child progress bars
    children = parent.children
    if sort_children
        # Sort by max size descending, then by header
        children = sort(children, by = c -> (-c.max, c.header))
    end

    for child in children
        # Only show running children with significant progress or status
        if child.current > 0 || child.max > 1000 || !isempty(child.status)
            show_progress(io, child; termwidth, carriagereturn = false)
            println(io)

            # Recursively show grandchildren
            if !isempty(child.children) && current_depth < max_depth
                _show_children(io, child, termwidth, sort_children, max_depth, current_depth + 1)
            end
        end
    end
    return
end

function _count_visible_lines(parent::MiniProgressBar, current_depth, max_depth)
    if current_depth > max_depth
        return 0
    end

    count = 1  # Count the parent bar itself

    for child in parent.children
        if child.current > 0 || child.max > 1000 || !isempty(child.status)
            count += 1  # Count this child

            # Recursively count grandchildren
            if !isempty(child.children) && current_depth < max_depth
                count += _count_visible_lines(child, current_depth + 1, max_depth) - 1  # Subtract 1 to avoid double-counting the child itself
            end
        end
    end

    return count
end

function start_multi_progress(display::MultiProgressDisplay; child_filter = nothing)
    display.is_active = true
    print(display.io, ANSI_DISABLECURSOR)

    # Start the display loop in a separate thread
    display_task = Threads.@spawn begin
        try
            display.timer = Timer(0, interval = display.update_interval)
            first = true

            while display.is_active
                local str = sprint(context = display.io) do iostr
                    first || print(iostr, ANSI_CLEARTOEND)

                    # Filter children if a filter function is provided
                    if child_filter !== nothing
                        visible_children = filter(child_filter, display.main_bar.children)
                        original_children = display.main_bar.children
                        display.main_bar.children = visible_children

                        show_multi_progress(iostr, display.main_bar; sort_children = true)
                        n_printed = 1 + length(visible_children)

                        # Restore original children
                        display.main_bar.children = original_children
                    else
                        show_multi_progress(iostr, display.main_bar; sort_children = true)
                        n_printed = _count_visible_lines(display.main_bar, 1, 3)
                    end

                    display.is_active && print(iostr, ANSI_MOVEUP(n_printed), ANSI_MOVECOL1)
                    first = false
                end
                print(display.io, str)

                if display.is_active
                    wait(display.timer)
                end
            end
        catch e
            e isa InterruptException || rethrow()
        finally
            if display.timer !== nothing
                close(display.timer)
                display.timer = nothing
            end
        end
    end

    return display_task
end

function stop_multi_progress(display::MultiProgressDisplay, display_task::Task)
    display.is_active = false
    wait(display_task)

    # Final display without cursor positioning
    print(display.io, ANSI_CLEARTOEND)
    show_multi_progress(display.io, display.main_bar; sort_children = true)
    return print(display.io, ANSI_ENABLECURSOR)
end

function update_multi_progress(display::MultiProgressDisplay, update_fn::Function)
    # This function can be used to update progress bars safely
    # The update_fn receives the main_bar and can modify it and its children
    return update_fn(display.main_bar)
end

end
