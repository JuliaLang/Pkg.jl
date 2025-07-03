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
    return contains(str, '/') || contains(str, '\\') || str == "." || str == ".."
end

# Check if a string looks like a complete URL
function looks_like_complete_url(str::String)
    return (startswith(str, "http://") || startswith(str, "https://") ||
            startswith(str, "git@") || startswith(str, "ssh://")) &&
           (contains(str, '.') || contains(str, '/'))
end

# Handle GitHub tree/commit URLs by converting them to standard URL + rev format
function preprocess_github_tree_commit_url(input::String)
    m = match(r"https://github.com/(.*?)/(.*?)/(?:tree|commit)/(.*?)$", input)
    if m !== nothing
        base_url = "https://github.com/$(m.captures[1])/$(m.captures[2])"
        rev = m.captures[3]
        return [PackageIdentifier(base_url), Rev(rev)]
    end
    return nothing
end

# Parse URLs with specifiers  
# URLs can only have revisions (#) and subdirs (:), NOT versions (@)
function parse_url_with_specifiers(input::String)
    tokens = PackageToken[]
    remaining = input
    
    # First, extract subdir if present (rightmost : that looks like a subdir)
    subdir_part = nothing
    colon_pos = findlast(':', remaining)
    if colon_pos !== nothing
        after_colon = remaining[nextind(remaining, colon_pos):end]
        before_colon = remaining[1:prevind(remaining, colon_pos)]
        
        # Don't treat : as subdir separator if it's part of URL structure:
        # 1. git@host:path syntax
        # 2. protocol:// syntax  
        # 3. user:password@ syntax
        # 4. port numbers
        
        is_url_structure = false
        
        # Check for git@host:path syntax
        if startswith(remaining, "git@")
            at_pos = findfirst('@', remaining)
            if at_pos !== nothing
                between_at_colon = remaining[nextind(remaining, at_pos):prevind(remaining, colon_pos)]
                if !contains(between_at_colon, '/')
                    is_url_structure = true
                end
            end
        end
        
        # Check for protocol:// syntax
        if !is_url_structure && colon_pos <= lastindex(remaining) - 2
            # Check if the next characters after : are //
            next_pos = nextind(remaining, colon_pos)
            if next_pos <= lastindex(remaining) - 1 && 
               remaining[colon_pos:nextind(remaining, nextind(remaining, colon_pos))] == "://"
                is_url_structure = true
            end
        end
        
        # Check for user:password@ syntax (: followed by text then @)
        if !is_url_structure && contains(after_colon, '@')
            at_in_after = findfirst('@', after_colon)
            if at_in_after !== nothing
                # This could be user:password@host, check if there's no / before @
                text_before_at = after_colon[1:prevind(after_colon, at_in_after)]
                if !contains(text_before_at, '/')
                    is_url_structure = true
                end
            end
        end
        
        # Check for port numbers (: followed by digits then /)
        if !is_url_structure && occursin(r"^\d+(/|$)", after_colon)
            is_url_structure = true
        end
        
        # Only treat as subdir if it's not part of URL structure
        if !is_url_structure &&
           (contains(after_colon, '/') || (!contains(after_colon, '@') && !contains(after_colon, '#'))) &&
           (contains(before_colon, "://") || contains(before_colon, ".git") || contains(before_colon, '@'))
            subdir_part = after_colon
            remaining = before_colon
        end
    end
    
    # Extract revision (first # that comes after a complete URL)
    rev_part = nothing
    hash_pos = findfirst('#', remaining)
    if hash_pos !== nothing
        before_hash = remaining[1:prevind(remaining, hash_pos)]
        after_hash = remaining[nextind(remaining, hash_pos):end]
        
        if looks_like_complete_url(before_hash)
            rev_part = after_hash
            remaining = before_hash
        end
    end
    
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
    # Paths are just plain identifiers, no specifiers allowed
    return [PackageIdentifier(input)]
end

# Parse package names with specifiers
function parse_name_with_specifiers(input::String)
    tokens = PackageToken[]
    remaining = input
    
    # Extract subdir if present (rightmost :)
    subdir_part = nothing
    colon_pos = findlast(':', remaining)
    if colon_pos !== nothing
        subdir_part = remaining[nextind(remaining, colon_pos):end]
        remaining = remaining[1:prevind(remaining, colon_pos)]
    end
    
    # Extract version if present (rightmost @)
    version_part = nothing
    at_pos = findlast('@', remaining)
    if at_pos !== nothing
        version_part = remaining[nextind(remaining, at_pos):end]
        remaining = remaining[1:prevind(remaining, at_pos)]
    end
    
    # Extract revision if present (rightmost #)
    rev_part = nothing
    hash_pos = findlast('#', remaining)
    if hash_pos !== nothing
        rev_part = remaining[nextind(remaining, hash_pos):end]
        remaining = remaining[1:prevind(remaining, hash_pos)]
    end
    
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
    github_result = preprocess_github_tree_commit_url(input)
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
    # Use new string-based parsing instead of regex-based approach
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
            arg_tokens = parse_package_spec_new(input)
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
        if isurl(word)
            return PackageSpec(; url=word)
        elseif any(occursin.(['\\','/'], word)) || word == "." || word == ".."
            if casesensitive_isdir(expanduser(word))
                return PackageSpec(; path=normpath(expanduser(word)))
            else
                pkgerror("`$word` appears to be a local path, but directory does not exist")
            end
        end
        if occursin(name_re, word) && casesensitive_isdir(expanduser(word))
            @info "Use `./$word` to add or develop the local directory at `$(Base.contractuser(abspath(word)))`."
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
    if add && isdir_nothrow(word) # TODO: Should be casesensitive_isdir
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
