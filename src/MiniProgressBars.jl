module MiniProgressBars

export MiniProgressBar, start_progress, end_progress, show_progress, print_progress_bottom

using Printf

Base.@kwdef mutable struct MiniProgressBar
    max::Int = 1.0
    header::String = ""
    color::Symbol = :white
    width::Int = 40
    current::Int = 0.0
    prev::Int = 0.0
    has_shown::Bool = false
    time_shown::Float64 = 0.0
    percentage::Bool = true
    always_reprint::Bool = false
    indent::Int = 4
end

const NONINTERACTIVE_TIME_GRANULARITY = Ref(2.0)
const PROGRESS_BAR_PERCENTAGE_GRANULARITY = Ref(0.1)

function pretend_cursor()
    io = stderr
    bar = MiniProgressBar(; indent=2, header = "Progress", color = Base.info_color(),
    percentage=false, always_reprint=true)
    bar.max = 40
    start_progress(io, bar)
    sleep(0.5)
    for i in 1:40
        bar.current = i
        print_progress_bottom(io)
        println("Downloading ... $i")
        show_progress(io, bar)
        x = randstring(7)
        sleep(0.01)
    end
    end_progress(io, bar)
    print("Hello!")
end

function start_progress(io::IO, _::MiniProgressBar)
    ansi_disablecursor = "\e[?25l"
    print(io, ansi_disablecursor)
end

function show_progress(io::IO, p::MiniProgressBar)
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
    if !isinteractive()
        t = time()
        if p.has_shown && (t - p.time_shown) < NONINTERACTIVE_TIME_GRANULARITY[]
            return
        end
        p.time_shown = t
    end
    p.prev = p.current
    p.has_shown = true
    n_filled = ceil(Int, p.width * perc / 100)
    n_left = p.width - n_filled
    print(io, " "^p.indent)
    printstyled(io, p.header, color=p.color, bold=true)
    print(io, " [")
    print(io, "="^n_filled, ">")
    print(io, " "^n_left, "]  ", )
    if p.percentage
        @printf io "%2.1f %%" perc
    else
        print(io, p.current, "/",  p.max)
    end
    print(io, "\r")
end

function end_progress(io, p::MiniProgressBar)
    ansi_enablecursor = "\e[?25h"
    ansi_clearline = "\e[2K"
    print(io, ansi_enablecursor)
    print(io, ansi_clearline)
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
    print(io, "\e[S")
    ansi_clearline = "\e[2K"
    ansi_movecol1 = "\e[1G"
    ansi_moveup(n::Int) = string("\e[", n, "A")
    print(io, ansi_moveup(1))
    print(io, ansi_clearline)
    print(io, ansi_movecol1)
end

end
