import ..isdir_nothrow, ..Registry.RegistrySpec, ..isurl
using UUIDs

struct PackageIdentifier
    val::String
end

struct VersionToken
    version::String
end

struct Rev
    rev::String
end

struct Subdir
    dir::String
end

const PackageToken = Union{PackageIdentifier,
                           VersionToken,
                           Rev,
                           Subdir}

# Check if a string is a valid UUID
function is_valid_uuid(str::String)
    try
        UUID(str)
        return true
    catch
        return false
    end
end

# Simple URL detection
function looks_like_url(str::String)
    return startswith(str, "http://") || startswith(str, "https://") ||
           startswith(str, "git@") || startswith(str, "ssh://") ||
           contains(str, ".git")
end

# Simple path detection
function looks_like_path(str::String)
    return contains(str, '/') || contains(str, '\\') || str == "." || str == ".." ||
           (length(str) >= 2 && isletter(str[1]) && str[2] == ':')  # Windows drive letters
end

# Check if a string looks like a complete URL
function looks_like_complete_url(str::String)
    return (startswith(str, "http://") || startswith(str, "https://") ||
            startswith(str, "git@") || startswith(str, "ssh://")) &&
           (contains(str, '.') || contains(str, '/'))
end

# Check if a colon at given position is part of a Windows drive letter
function is_windows_drive_colon(input::String, colon_pos::Int)
    # Windows drive letters are single letters followed by colon at beginning
    # Examples: "C:", "D:", etc.
    if colon_pos == 2 && length(input) >= 2
        first_char = input[1]
        return isletter(first_char) && input[2] == ':'
    end
    return false
end

# Extract subdir specifier from the end of input (rightmost : that's not a Windows drive letter)
function extract_subdir(input::String)
    colon_pos = findlast(':', input)
    if colon_pos === nothing
        return input, nothing
    end

    # Skip Windows drive letters (e.g., C:, D:)
    if is_windows_drive_colon(input, colon_pos)
        return input, nothing
    end

    subdir_part = input[nextind(input, colon_pos):end]
    remaining = input[1:prevind(input, colon_pos)]
    return remaining, subdir_part
end

# Extract revision specifier from input (first # that separates base from revision)
function extract_revision(input::String)
    hash_pos = findfirst('#', input)
    if hash_pos === nothing
        return input, nothing
    end

    rev_part = input[nextind(input, hash_pos):end]
    remaining = input[1:prevind(input, hash_pos)]
    return remaining, rev_part
end

# Extract version specifier from the end of input (rightmost @)
function extract_version(input::String)
    at_pos = findlast('@', input)
    if at_pos === nothing
        return input, nothing
    end

    version_part = input[nextind(input, at_pos):end]
    remaining = input[1:prevind(input, at_pos)]
    return remaining, version_part
end

function preprocess_github_url(input::String)
    # Handle GitHub tree/commit URLs
    if (m = match(r"https://github.com/(.*?)/(.*?)/(?:tree|commit)/(.*?)$", input)) !== nothing
        return [PackageIdentifier("https://github.com/$(m.captures[1])/$(m.captures[2])"), Rev(m.captures[3])]
    # Handle GitHub pull request URLs
    elseif (m = match(r"https://github.com/(.*?)/(.*?)/pull/(\d+)$", input)) !== nothing
        return [PackageIdentifier("https://github.com/$(m.captures[1])/$(m.captures[2])"), Rev("pull/$(m.captures[3])/head")]
    else
        return nothing
    end
end

# Check if a colon in a URL string is part of URL structure (not a subdir separator)
function is_url_structure_colon(input::String, colon_pos::Int)
    after_colon = input[nextind(input, colon_pos):end]

    # Check for git@host:path syntax
    if startswith(input, "git@")
        at_pos = findfirst('@', input)
        if at_pos !== nothing
            between_at_colon = input[nextind(input, at_pos):prevind(input, colon_pos)]
            if !contains(between_at_colon, '/')
                return true
            end
        end
    end

    # Check for protocol:// syntax
    if colon_pos <= lastindex(input) - 2
        next_pos = nextind(input, colon_pos)
        if next_pos <= lastindex(input) - 1 &&
           input[colon_pos:nextind(input, nextind(input, colon_pos))] == "://"
            return true
        end
    end

    # Check for user:password@ syntax (: followed by text then @)
    if contains(after_colon, '@')
        at_in_after = findfirst('@', after_colon)
        if at_in_after !== nothing
            text_before_at = after_colon[1:prevind(after_colon, at_in_after)]
            if !contains(text_before_at, '/')
                return true
            end
        end
    end

    # Check for port numbers (: followed by digits then /)
    if occursin(r"^\d+(/|$)", after_colon)
        return true
    end

    return false
end

# Extract subdir from URL, being careful about URL structure
function extract_url_subdir(input::String)
    colon_pos = findlast(':', input)
    if colon_pos === nothing
        return input, nothing
    end

    # Check if this colon is part of URL structure
    if is_url_structure_colon(input, colon_pos)
        return input, nothing
    end

    after_colon = input[nextind(input, colon_pos):end]
    before_colon = input[1:prevind(input, colon_pos)]

    # Only treat as subdir if it looks like one and the part before looks like a URL
    if (contains(after_colon, '/') || (!contains(after_colon, '@') && !contains(after_colon, '#'))) &&
       (contains(before_colon, "://") || contains(before_colon, ".git") || contains(before_colon, '@'))
        return before_colon, after_colon
    end

    return input, nothing
end

# Extract revision from URL, only after a complete URL
function extract_url_revision(input::String)
    hash_pos = findfirst('#', input)
    if hash_pos === nothing
        return input, nothing
    end

    before_hash = input[1:prevind(input, hash_pos)]
    after_hash = input[nextind(input, hash_pos):end]

    if looks_like_complete_url(before_hash)
        return before_hash, after_hash
    end

    return input, nothing
end

# Parse URLs with specifiers
# URLs can only have revisions (#) and subdirs (:), NOT versions (@)
function parse_url_with_specifiers(input::String)
    tokens = PackageToken[]
    remaining = input

    # Extract subdir if present (rightmost : that looks like a subdir)
    remaining, subdir_part = extract_url_subdir(remaining)

    # Extract revision (first # that comes after a complete URL)
    remaining, rev_part = extract_url_revision(remaining)

    # What's left is the base URL
    push!(tokens, PackageIdentifier(remaining))

    # Add the specifiers in the correct order
    if rev_part !== nothing
        push!(tokens, Rev(rev_part))
    end
    if subdir_part !== nothing
        push!(tokens, Subdir(subdir_part))
    end

    return tokens
end

function parse_path_with_specifiers(input::String)
    tokens = PackageToken[]
    remaining = input

    # Extract subdir if present (rightmost :)
    remaining, subdir_part = extract_subdir(remaining)

    # Extract revision if present (rightmost #)
    remaining, rev_part = extract_revision(remaining)

    # What's left is the base path
    push!(tokens, PackageIdentifier(remaining))

    # Add specifiers in correct order
    if rev_part !== nothing
        push!(tokens, Rev(rev_part))
    end
    if subdir_part !== nothing
        push!(tokens, Subdir(subdir_part))
    end

    return tokens
end

# Parse package names with specifiers
function parse_name_with_specifiers(input::String)
    tokens = PackageToken[]
    remaining = input

    # Extract subdir if present (rightmost :)
    remaining, subdir_part = extract_subdir(remaining)

    # Extract version if present (rightmost @)
    remaining, version_part = extract_version(remaining)

    # Extract revision if present (rightmost #)
    remaining, rev_part = extract_revision(remaining)

    # What's left is the base name
    push!(tokens, PackageIdentifier(remaining))

    # Add specifiers in correct order
    if rev_part !== nothing
        push!(tokens, Rev(rev_part))
    end
    if version_part !== nothing
        push!(tokens, VersionToken(version_part))
    end
    if subdir_part !== nothing
        push!(tokens, Subdir(subdir_part))
    end

    return tokens
end

# Parse a single package specification
function parse_package_spec_new(input::String)
    # Handle quoted strings
    if (startswith(input, '"') && endswith(input, '"')) ||
       (startswith(input, '\'') && endswith(input, '\''))
        input = input[2:end-1]
    end

    # Handle GitHub tree/commit URLs first (special case)
    github_result = preprocess_github_url(input)
    if github_result !== nothing
        return github_result
    end

    # Handle name=uuid format
    if contains(input, '=')
        parts = split(input, '=', limit=2)
        if length(parts) == 2
            name = String(strip(parts[1]))
            uuid_str = String(strip(parts[2]))
            if is_valid_uuid(uuid_str)
                return [PackageIdentifier("$name=$uuid_str")]
            end
        end
    end

    # Check what type of input this is and parse accordingly
    if looks_like_url(input)
        return parse_url_with_specifiers(input)
    elseif looks_like_path(input)
        return parse_path_with_specifiers(input)
    else
        return parse_name_with_specifiers(input)
    end
end

function parse_package(args::Vector{QString}, options; add_or_dev=false)::Vector{PackageSpec}
    tokens = PackageToken[]

    i = 1
    while i <= length(args)
        arg = args[i]
        input = arg.isquoted ? arg.raw : arg.raw

        # Check if this argument is a standalone modifier (like #dev, @v1.0, :subdir)
        if !arg.isquoted && (startswith(input, '#') || startswith(input, '@') || startswith(input, ':'))
            # This is a standalone modifier - it should be treated as a token
            if startswith(input, '#')
                push!(tokens, Rev(input[2:end]))
            elseif startswith(input, '@')
                push!(tokens, VersionToken(input[2:end]))
            elseif startswith(input, ':')
                push!(tokens, Subdir(input[2:end]))
            end
        else
            # Parse this argument normally
            if arg.isquoted
                # For quoted arguments, treat as literal without specifier extraction
                arg_tokens = [PackageIdentifier(input)]
            else
                arg_tokens = parse_package_spec_new(input)
            end
            append!(tokens, arg_tokens)
        end

        i += 1
    end

    return parse_package_args(tokens; add_or_dev=add_or_dev)
end


function parse_package_args(args::Vector{PackageToken}; add_or_dev=false)::Vector{PackageSpec}
    # check for and apply PackageSpec modifier (e.g. `#foo` or `@v1.0.2`)
    function apply_modifier!(pkg::PackageSpec, args::Vector{PackageToken})
        (isempty(args) || args[1] isa PackageIdentifier) && return
        parsed_subdir = false
        parsed_version = false
        parsed_rev = false
        while !isempty(args)
            modifier = popfirst!(args)
            if modifier isa Subdir
                if parsed_subdir
                    pkgerror("Multiple subdir specifiers `$args` found.")
                end
                pkg.subdir = modifier.dir
                (isempty(args) || args[1] isa PackageIdentifier) && return
                modifier = popfirst!(args)
                parsed_subdir = true
            elseif modifier isa VersionToken
                if parsed_version
                    pkgerror("Multiple version specifiers `$args` found.")
                end
                pkg.version = modifier.version
                parsed_version = true
            elseif modifier isa Rev
                if parsed_rev
                    pkgerror("Multiple revision specifiers `$args` found.")
                end
                pkg.rev = modifier.rev
                parsed_rev = true
            else
                pkgerror("Package name/uuid must precede subdir specifier `$args`.")
            end
        end
    end

    pkgs = PackageSpec[]
    while !isempty(args)
        arg = popfirst!(args)
        if arg isa PackageIdentifier
            pkg = parse_package_identifier(arg; add_or_develop=add_or_dev)
            apply_modifier!(pkg, args)
            push!(pkgs, pkg)
        # Modifiers without a corresponding package identifier -- this is a user error
        else
            arg isa VersionToken ?
                pkgerror("Package name/uuid must precede version specifier `@$arg`.") :
            arg isa Rev ?
                pkgerror("Package name/uuid must precede revision specifier `#$(arg.rev)`.") :
                pkgerror("Package name/uuid must precede subdir specifier `[$arg]`.")
        end
    end
    return pkgs
end

let uuid = raw"(?i)[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}(?-i)",
    name = raw"(\w+)(?:\.jl)?"
    global const name_re = Regex("^$name\$")
    global const uuid_re = Regex("^$uuid\$")
    global const name_uuid_re = Regex("^$name\\s*=\\s*($uuid)\$")
end
# packages can be identified through: uuid, name, or name+uuid
# additionally valid for add/develop are: local path, url
function parse_package_identifier(pkg_id::PackageIdentifier; add_or_develop=false)::PackageSpec
    word = pkg_id.val
    if add_or_develop
        if occursin(name_re, word) && isdir(expanduser(word))
            @info "Use `./$word` to add or develop the local directory at `$(Base.contractuser(abspath(word)))`."
        end
        if isurl(word)
            return PackageSpec(; url=word)
        elseif any(occursin.(['\\','/'], word)) || word == "." || word == ".."
            return PackageSpec(; path=normpath(expanduser(word)))
        end
    end
    if occursin(uuid_re, word)
        return PackageSpec(;uuid=UUID(word))
    elseif occursin(name_re, word)
        m = match(name_re, word)
        return PackageSpec(String(something(m.captures[1])))
    elseif occursin(name_uuid_re, word)
        m = match(name_uuid_re, word)
        return PackageSpec(String(something(m.captures[1])), UUID(something(m.captures[2])))
    else
        pkgerror("Unable to parse `$word` as a package.")
    end
end

################
# RegistrySpec #
################
function parse_registry(raw_args::Vector{QString}, options; add=false)
    regs = RegistrySpec[]
    foreach(x -> push!(regs, parse_registry(x; add=add)), unwrap(raw_args))
    return regs
end

# Registries can be identified through: uuid, name, or name+uuid
# when updating/removing. When adding we can accept a local path or url.
function parse_registry(word::AbstractString; add=false)::RegistrySpec
    word = expanduser(word)
    registry = RegistrySpec()
    if add && isdir_nothrow(word)
        if isdir(joinpath(word, ".git")) # add path as url and clone it from there
            registry.url = abspath(word)
        else # put the path
            registry.path = abspath(word)
        end
    elseif occursin(uuid_re, word)
        registry.uuid = UUID(word)
    elseif occursin(name_re, word)
        m = match(name_re, word)
        registry.name = String(something(m.captures[1]))
    elseif occursin(name_uuid_re, word)
        m = match(name_uuid_re, word)
        registry.name = String(something(m.captures[1]))
        registry.uuid = UUID(something(m.captures[2]))
    elseif add
        # Guess it is a url then
        registry.url = String(word)
    else
        pkgerror("`$word` cannot be parsed as a registry")
    end
    return registry
end

#
# # Apps
#
function parse_app_add(raw_args::Vector{QString}, options)
    return parse_package(raw_args, options; add_or_dev=true)
end



#
# # Other
#
function parse_activate(args::Vector{QString}, options)
    isempty(args) && return [] # nothing to do
    if length(args) == 1
        x = first(args)
        if x.isquoted
            return [x.raw]
        end
        x = x.raw
        if x == "-"
            options[:prev] = true
            return []
        elseif first(x) == '@'
            options[:shared] = true
            return [x[2:end]]
        else
            return [expanduser(x)]
        end
    end
    return args # this is currently invalid input for "activate"
end

#
# # Option Maps
#
function do_preserve(x::String)
    x == "installed"        && return Types.PRESERVE_ALL_INSTALLED
    x == "all"              && return Types.PRESERVE_ALL
    x == "direct"           && return Types.PRESERVE_DIRECT
    x == "semver"           && return Types.PRESERVE_SEMVER
    x == "none"             && return Types.PRESERVE_NONE
    x == "tiered_installed" && return Types.PRESERVE_TIERED_INSTALLED
    x == "tiered"           && return Types.PRESERVE_TIERED
    pkgerror("`$x` is not a valid argument for `--preserve`.")
end
