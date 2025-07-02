module FuzzySorting

_displaysize(io::IO) = displaysize(io)::Tuple{Int, Int}

# This code is duplicated from REPL.jl
# Considering breaking this into an independent package

# Search & Rescue
# Utilities for correcting user mistakes and (eventually)
# doing full documentation searches from the repl.

# Fuzzy Search Algorithm

function matchinds(needle, haystack; acronym::Bool = false)
    chars = collect(needle)
    is = Int[]
    lastc = '\0'
    for (i, char) in enumerate(haystack)
        while !isempty(chars) && isspace(first(chars))
            popfirst!(chars) # skip spaces
        end
        isempty(chars) && break
        if lowercase(char) == lowercase(chars[1]) &&
                (!acronym || !isletter(lastc))
            push!(is, i)
            popfirst!(chars)
        end
        lastc = char
    end
    return is
end

longer(x, y) = length(x) ≥ length(y) ? (x, true) : (y, false)

bestmatch(needle, haystack) =
    longer(
    matchinds(needle, haystack, acronym = true),
    matchinds(needle, haystack)
)

# Optimal string distance: Counts the minimum number of insertions, deletions,
# transpositions or substitutions to go from one string to the other.
function string_distance(a::AbstractString, lena::Integer, b::AbstractString, lenb::Integer)
    if lena > lenb
        a, b = b, a
        lena, lenb = lenb, lena
    end
    start = 0
    for (i, j) in zip(a, b)
        if a == b
            start += 1
        else
            break
        end
    end
    start == lena && return lenb - start
    vzero = collect(1:(lenb - start))
    vone = similar(vzero)
    prev_a, prev_b = first(a), first(b)
    current = 0
    for (i, ai) in enumerate(a)
        i > start || (prev_a = ai; continue)
        left = i - start - 1
        current = i - start
        transition_next = 0
        for (j, bj) in enumerate(b)
            j > start || (prev_b = bj; continue)
            # No need to look beyond window of lower right diagonal
            above = current
            this_transition = transition_next
            transition_next = vone[j - start]
            vone[j - start] = current = left
            left = vzero[j - start]
            if ai != bj
                # Minimum between substitution, deletion and insertion
                current = min(current + 1, above + 1, left + 1)
                if i > start + 1 && j > start + 1 && ai == prev_b && prev_a == bj
                    current = min(current, (this_transition += 1))
                end
            end
            vzero[j - start] = current
            prev_b = bj
        end
        prev_a = ai
    end
    return current
end

function fuzzyscore(needle::AbstractString, haystack::AbstractString)
    lena, lenb = length(needle), length(haystack)
    return 1 - (string_distance(needle, lena, haystack, lenb) / max(lena, lenb))
end

function fuzzysort(search::String, candidates::Vector{String})
    scores = map(cand -> (FuzzySorting.fuzzyscore(search, cand), -Float64(FuzzySorting.levenshtein(search, cand))), candidates)
    return candidates[sortperm(scores)] |> reverse, any(s -> s[1] >= print_score_threshold, scores)
end

# Levenshtein Distance

function levenshtein(s1, s2)
    a, b = collect(s1), collect(s2)
    m = length(a)
    n = length(b)
    d = Matrix{Int}(undef, m + 1, n + 1)

    d[1:(m + 1), 1] = 0:m
    d[1, 1:(n + 1)] = 0:n

    for i in 1:m, j in 1:n
        d[i + 1, j + 1] = min(
            d[i, j + 1] + 1,
            d[i + 1, j] + 1,
            d[i, j] + (a[i] != b[j])
        )
    end

    return d[m + 1, n + 1]
end

function levsort(search::String, candidates::Vector{String})
    scores = map(cand -> (Float64(levenshtein(search, cand)), -fuzzyscore(search, cand)), candidates)
    candidates = candidates[sortperm(scores)]
    i = 0
    for outer i in 1:length(candidates)
        levenshtein(search, candidates[i]) > 3 && break
    end
    return candidates[1:i]
end

# Result printing

function printmatch(io::IO, word, match)
    is, _ = bestmatch(word, match)
    for (i, char) in enumerate(match)
        if i in is
            printstyled(io, char, bold = true)
        else
            print(io, char)
        end
    end
    return
end

const print_score_threshold = 0.5

function printmatches(io::IO, word, matches; cols::Int = _displaysize(io)[2])
    total = 0
    for match in matches
        total + length(match) + 1 > cols && break
        fuzzyscore(word, match) < print_score_threshold && break
        print(io, " ")
        printmatch(io, word, match)
        total += length(match) + 1
    end
    return
end

printmatches(args...; cols::Int = _displaysize(stdout)[2]) = printmatches(stdout, args..., cols = cols)

function print_joined_cols(io::IO, ss::Vector{String}, delim = "", last = delim; cols::Int = _displaysize(io)[2])
    i = 0
    total = 0
    for outer i in 1:length(ss)
        total += length(ss[i])
        total + max(i - 2, 0) * length(delim) + (i > 1 ? 1 : 0) * length(last) > cols && (i -= 1; break)
    end
    join(io, ss[1:i], delim, last)
    return
end

print_joined_cols(args...; cols::Int = _displaysize(stdout)[2]) = print_joined_cols(stdout, args...; cols = cols)

function print_correction(io::IO, word::String, mod::Module)
    cors = map(quote_spaces, levsort(word, accessible(mod)))
    pre = "Perhaps you meant "
    print(io, pre)
    print_joined_cols(io, cors, ", ", " or "; cols = _displaysize(io)[2] - length(pre))
    println(io)
    return
end

end
