import ..isdir_nothrow, ..Registry.RegistrySpec, ..isurl

###############
# PackageSpec #
###############
"""
Parser for PackageSpec objects.
"""
function parse_package(args::Vector{QString}, options; add_or_dev=false)::Vector{PackageSpec}
    words′ = package_lex(args)
    words = String[]
    for word in words′
        if (m = match(r"https://github.com/(.*?)/(.*?)/(?:tree|commit)/(.*?)$", word)) !== nothing
            push!(words, "https://github.com/$(m.captures[1])/$(m.captures[2])")
            push!(words, "#$(m.captures[3])")
        else
            push!(words, word)
        end
    end
    args = PackageToken[PackageToken(pkgword) for pkgword in words]

    return parse_package_args(args; add_or_dev=add_or_dev)
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

const PackageIdentifier = String
const PackageToken = Union{PackageIdentifier, VersionToken, Rev, Subdir}

    # Match a git repository URL. This includes uses of `@` and `:` but
    # requires that it has `.git` at the end.
let url = raw"((git|ssh|http(s)?)|(git@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git$)(/)?",

    # Match a `NAME=UUID` package specifier.
    name_uuid = raw"[^@\#\s:]+\s*=\s*[^@\#\s:]+",

    # Match a `#BRANCH` branch or tag specifier.
    branch = raw"\#\s*[^@\#\s]*",

    # Match an `@VERSION` version specifier.
    version = raw"@\s*[^@\#\s]*",

    # Match a `:SUBDIR` subdir specifier.
    subdir = raw":[^@\#\s]+",

    # Match any other way to specify a package. This includes package
    # names, local paths, and URLs that don't match the `url` part. In
    # order not to clash with the branch, version, and subdir
    # specifiers, these cannot include `@` or `#`, and `:` is only
    # allowed if followed by `/` or `\`. For URLs matching this part
    # of the regex, that means that `@` (e.g. user names) and `:`
    # (e.g. port) cannot be used but it doesn't have to end with
    # `.git`.
    other = raw"([^@\#\s:] | :(/|\\))+"

    # Combine all of the above.
    global const package_id_re = Regex(
        "$url | $name_uuid | $branch | $version | $subdir | $other", "x")
end

function package_lex(qwords::Vector{QString})::Vector{String}
    words = String[]
    for qword in qwords
        qword.isquoted ?
            push!(words, qword.raw) :
            append!(words, map(m->m.match, eachmatch(package_id_re, qword.raw)))
    end
    return words
end

PackageToken(word::String)::PackageToken =
    first(word) == '@' ? VersionToken(word[2:end]) :
    first(word) == '#' ? Rev(word[2:end]) :
    first(word) == ':' ? Subdir(word[2:end]) :
    String(word)

function parse_package_args(args::Vector{PackageToken}; add_or_dev=false)::Vector{PackageSpec}
    # check for and apply PackageSpec modifier (e.g. `#foo` or `@v1.0.2`)
    function apply_modifier!(pkg::PackageSpec, args::Vector{PackageToken})
        (isempty(args) || args[1] isa PackageIdentifier) && return
        modifier = popfirst!(args)
        if modifier isa Subdir
            pkg.subdir = modifier.dir
            (isempty(args) || args[1] isa PackageIdentifier) && return
            modifier = popfirst!(args)
        end

        if modifier isa VersionToken
            pkg.version = modifier.version
        elseif modifier isa Rev
            pkg.rev = modifier.rev
        else
            pkgerror("Package name/uuid must precede subdir specifier `[$arg]`.")
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
function parse_package_identifier(word::AbstractString; add_or_develop=false)::PackageSpec
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
        return PackageSpec(String(match(name_re, word).captures[1]))
    elseif occursin(name_uuid_re, word)
        m = match(name_uuid_re, word)
        return PackageSpec(String(m.captures[1]), UUID(m.captures[2]))
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
        registry.name = String(match(name_re, word).captures[1])
    elseif occursin(name_uuid_re, word)
        m = match(name_uuid_re, word)
        registry.name = String(m.captures[1])
        registry.uuid = UUID(m.captures[2])
    elseif add
        # Guess it is a url then
        registry.url = String(word)
    else
        pkgerror("`$word` cannot be parsed as a registry")
    end
    return registry
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
    x == "all"    && return Types.PRESERVE_ALL
    x == "direct" && return Types.PRESERVE_DIRECT
    x == "semver" && return Types.PRESERVE_SEMVER
    x == "none"   && return Types.PRESERVE_NONE
    x == "tiered" && return Types.PRESERVE_TIERED
    pkgerror("`$x` is not a valid argument for `--preserve`.")
end
