module MiniProgressBars

export MiniProgressBar, start_progress, end_progress, show_progress, print_progress_bottom

using Printf

Base.@kwdef mutable struct MiniProgressBar
    max::Int = 1.0
    header::String = ""
    color::Symbol = :nothing
    width::Int = 40
    current::Int = 0.0
    prev::Int = 0.0
    has_shown::Bool = false
    time_shown::Float64 = 0.0
    percentage::Bool = true
    always_reprint::Bool = false
    indent::Int = 4
end

const PROGRESS_BAR_TIME_GRANULARITY = Ref(1 / 30.0) # 30 fps
const PROGRESS_BAR_PERCENTAGE_GRANULARITY = Ref(0.1)

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
    if p.has_shown && (t - p.time_shown) < PROGRESS_BAR_TIME_GRANULARITY[]
        return
    end
    p.time_shown = t
    p.prev = p.current
    p.has_shown = true

    progress_text = if p.percentage
        @sprintf "%2.1f %%" perc
    else
        string(p.current, "/",  p.max)
    end
    termwidth = @something termwidth displaysize(io)[2]
    max_progress_width = max(0, min(termwidth - textwidth(p.header) - textwidth(progress_text) - 10 , p.width))
    n_filled = ceil(Int, max_progress_width * perc / 100)
    n_left = max_progress_width - n_filled
    to_print = sprint(; context=io) do io
        print(io, " "^p.indent)
        printstyled(io, p.header, color=p.color, bold=true)
        print(io, " [")
        print(io, "="^n_filled, ">")
        print(io, " "^n_left, "]  ", )
        print(io, progress_text)
        carriagereturn && print(io, "\r")
    end
    # Print everything in one call
    print(io, to_print)
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
#     print_progree_bottom(io)
#     println("stuff")
#     prog.current = progress
#     showproress(io, prog)
#  end
#
function print_progress_bottom(io::IO)
    ansi_clearline = "\e[2K"
    ansi_movecol1 = "\e[1G"
    ansi_moveup(n::Int) = string("\e[", n, "A")
    print(io, "\e[S" * ansi_moveup(1) * ansi_clearline * ansi_movecol1)
end

end
