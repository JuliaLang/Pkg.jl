module FuzzySorting

_displaysize(io::IO) = displaysize(io)::Tuple{Int, Int}

# Character confusion weights for fuzzy matching
const CHARACTER_CONFUSIONS = Dict(
    ('a', 'e') => 0.5, ('e', 'a') => 0.5,
    ('i', 'y') => 0.5, ('y', 'i') => 0.5,
    ('u', 'o') => 0.5, ('o', 'u') => 0.5,
    ('c', 'k') => 0.3, ('k', 'c') => 0.3,
    ('s', 'z') => 0.3, ('z', 's') => 0.3,
    # Keyboard proximity (QWERTY layout)
    ('q', 'w') => 0.4, ('w', 'q') => 0.4,
    ('w', 'e') => 0.4, ('e', 'w') => 0.4,
    ('e', 'r') => 0.4, ('r', 'e') => 0.4,
    ('r', 't') => 0.4, ('t', 'r') => 0.4,
    ('t', 'y') => 0.4, ('y', 't') => 0.4,
    ('y', 'u') => 0.4, ('u', 'y') => 0.4,
    ('u', 'i') => 0.4, ('i', 'u') => 0.4,
    ('i', 'o') => 0.4, ('o', 'i') => 0.4,
    ('o', 'p') => 0.4, ('p', 'o') => 0.4,
    ('a', 's') => 0.4, ('s', 'a') => 0.4,
    ('s', 'd') => 0.4, ('d', 's') => 0.4,
    ('d', 'f') => 0.4, ('f', 'd') => 0.4,
    ('f', 'g') => 0.4, ('g', 'f') => 0.4,
    ('g', 'h') => 0.4, ('h', 'g') => 0.4,
    ('h', 'j') => 0.4, ('j', 'h') => 0.4,
    ('j', 'k') => 0.4, ('k', 'j') => 0.4,
    ('k', 'l') => 0.4, ('l', 'k') => 0.4,
    ('z', 'x') => 0.4, ('x', 'z') => 0.4,
    ('x', 'c') => 0.4, ('c', 'x') => 0.4,
    ('c', 'v') => 0.4, ('v', 'c') => 0.4,
    ('v', 'b') => 0.4, ('b', 'v') => 0.4,
    ('b', 'n') => 0.4, ('n', 'b') => 0.4,
    ('n', 'm') => 0.4, ('m', 'n') => 0.4,
)

# Enhanced fuzzy scoring with multiple factors
function fuzzyscore(needle::AbstractString, haystack::AbstractString)
    needle_lower, haystack_lower = lowercase(needle), lowercase(haystack)

    # Factor 1: Prefix matching bonus (highest priority)
    prefix_score = prefix_match_score(needle_lower, haystack_lower)

    # Factor 2: Subsequence matching
    subseq_score = subsequence_score(needle_lower, haystack_lower)

    # Factor 3: Character-level similarity (improved edit distance)
    char_score = character_similarity_score(needle_lower, haystack_lower)

    # Factor 4: Case preservation bonus
    case_score = case_preservation_score(needle, haystack)

    # Factor 5: Length penalty for very long matches
    length_penalty = length_penalty_score(needle, haystack)

    # Weighted combination
    base_score = 0.4 * prefix_score + 0.3 * subseq_score + 0.2 * char_score + 0.1 * case_score
    final_score = base_score * length_penalty

    return final_score
end

# Prefix matching: exact prefix gets maximum score
function prefix_match_score(needle::AbstractString, haystack::AbstractString)
    if startswith(haystack, needle)
        return 1.0
    elseif startswith(needle, haystack)
        return 0.9  # Partial prefix match
    else
        # Check for prefix after common separators
        for sep in ['_', '-', '.']
            parts = split(haystack, sep)
            for part in parts
                if startswith(part, needle)
                    return 0.7  # Component prefix match
                end
            end
        end
        return 0.0
    end
end

# Subsequence matching with position weighting
function subsequence_score(needle::AbstractString, haystack::AbstractString)
    if isempty(needle)
        return 1.0
    end

    needle_chars = collect(needle)
    haystack_chars = collect(haystack)

    matched_positions = Int[]
    haystack_idx = 1

    for needle_char in needle_chars
        found = false
        for i in haystack_idx:length(haystack_chars)
            if haystack_chars[i] == needle_char
                push!(matched_positions, i)
                haystack_idx = i + 1
                found = true
                break
            end
        end
        if !found
            return 0.0
        end
    end

    # Calculate score based on how clustered the matches are
    if length(matched_positions) <= 1
        return 1.0
    end

    # Penalize large gaps between matches
    gaps = diff(matched_positions)
    avg_gap = sum(gaps) / length(gaps)
    gap_penalty = 1.0 / (1.0 + avg_gap / 3.0)

    # Bonus for matches at word boundaries
    boundary_bonus = 0.0
    for pos in matched_positions
        if pos == 1 || haystack_chars[pos - 1] in ['_', '-', '.']
            boundary_bonus += 0.1
        end
    end

    coverage = length(needle) / length(haystack)
    return min(1.0, gap_penalty + boundary_bonus) * coverage
end

# Improved character-level similarity
function character_similarity_score(needle::AbstractString, haystack::AbstractString)
    if isempty(needle) || isempty(haystack)
        return 0.0
    end

    # Use Damerau-Levenshtein distance with character confusion weights
    distance = weighted_edit_distance(needle, haystack)
    max_len = max(length(needle), length(haystack))

    return max(0.0, 1.0 - distance / max_len)
end

# Weighted edit distance accounting for common typos
function weighted_edit_distance(s1::AbstractString, s2::AbstractString)

    a, b = collect(s1), collect(s2)
    m, n = length(a), length(b)

    # Initialize distance matrix
    d = Matrix{Float64}(undef, m + 1, n + 1)
    d[1:(m + 1), 1] = 0:m
    d[1, 1:(n + 1)] = 0:n

    for i in 1:m, j in 1:n
        if a[i] == b[j]
            d[i + 1, j + 1] = d[i, j]  # No cost for exact match
        else
            # Standard operations
            insert_cost = d[i, j + 1] + 1.0
            delete_cost = d[i + 1, j] + 1.0

            # Check for repeated character deletion (common typo)
            if i > 1 && a[i] == a[i - 1] && a[i - 1] == b[j]
                delete_cost = d[i, j + 1] + 0.3  # Low cost for deleting repeated char
            end

            # Check for repeated character insertion (common typo)
            if j > 1 && b[j] == b[j - 1] && a[i] == b[j - 1]
                insert_cost = d[i, j + 1] + 0.3  # Low cost for inserting repeated char
            end

            # Substitution with confusion weighting
            confusion_key = (a[i], b[j])
            subst_cost = d[i, j] + get(CHARACTER_CONFUSIONS, confusion_key, 1.0)

            d[i + 1, j + 1] = min(insert_cost, delete_cost, subst_cost)

            # Transposition
            if i > 1 && j > 1 && a[i] == b[j - 1] && a[i - 1] == b[j]
                d[i + 1, j + 1] = min(d[i + 1, j + 1], d[i - 1, j - 1] + 1.0)
            end
        end
    end

    return d[m + 1, n + 1]
end

# Case preservation bonus
function case_preservation_score(needle::AbstractString, haystack::AbstractString)
    if isempty(needle) || isempty(haystack)
        return 0.0
    end

    matches = 0
    min_len = min(length(needle), length(haystack))

    for i in 1:min_len
        if needle[i] == haystack[i]
            matches += 1
        end
    end

    return matches / min_len
end

# Length penalty for very long matches
function length_penalty_score(needle::AbstractString, haystack::AbstractString)
    needle_len = length(needle)
    haystack_len = length(haystack)

    if needle_len == 0
        return 0.0
    end

    # Strong preference for similar lengths
    length_ratio = haystack_len / needle_len
    length_diff = abs(haystack_len - needle_len)

    # Bonus for very close lengths (within 1-2 characters)
    if length_diff <= 1
        return 1.1  # Small bonus for near-exact length
    elseif length_diff <= 2
        return 1.05
    elseif length_ratio <= 1.5
        return 1.0
    elseif length_ratio <= 2.0
        return 0.8
    elseif length_ratio <= 3.0
        return 0.6
    else
        return 0.4  # Heavy penalty for very long matches
    end
end

# Main sorting function with optional popularity weighting
function fuzzysort(search::String, candidates::Vector{String}; popularity_weights::Dict{String, Float64} = Dict{String, Float64}())
    scores = map(candidates) do cand
        base_score = fuzzyscore(search, cand)
        weight = get(popularity_weights, cand, 1.0)
        score = base_score * weight
        return (score, cand)
    end

    # Sort by score descending, then by candidate name for ties
    sorted_scores = sort(scores, by = x -> (-x[1], x[2]))

    # Extract candidates and check if any meet threshold
    result_candidates = [x[2] for x in sorted_scores]
    has_good_matches = any(x -> x[1] >= print_score_threshold, sorted_scores)

    return result_candidates, has_good_matches
end

# Keep existing interface functions for compatibility
function matchinds(needle, haystack; acronym::Bool = false)
    chars = collect(needle)
    is = Int[]
    lastc = '\0'
    for (i, char) in enumerate(haystack)
        while !isempty(chars) && isspace(first(chars))
            popfirst!(chars)  # skip spaces
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

const print_score_threshold = 0.25

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


end
