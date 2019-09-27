import ..isdir_windows_workaround

###############
# PackageSpec #
###############
"""
Parser for PackageSpec objects.
"""
function parse_package(args::Vector{QString}; add_or_dev=false)::Vector{PackageSpec}
    args::Vector{PackageToken} = map(PackageToken, package_lex(args))
    return parse_package_args(args; add_or_dev=add_or_dev)
end

struct Rev
    rev::String
end
const PackageIdentifier = String
const PackageToken = Union{PackageIdentifier, VersionRange, Rev}

const package_id_re =
    r"((git|ssh|http(s)?)|(git@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)(/)? | [^@\#\s]+\s*=\s*[^@\#\s]+ | \#\s*[^@\#\s]* | @\s*[^@\#\s]* | [^@\#\s]+"x

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
    first(word) == '@' ? VersionRange(word[2:end]) :
    first(word) == '#' ? Rev(word[2:end]) :
    String(word)

function parse_package_args(args::Vector{PackageToken}; add_or_dev=false)::Vector{PackageSpec}
    # check for and apply PackageSpec modifier (e.g. `#foo` or `@v1.0.2`)
    function apply_modifier!(pkg::PackageSpec, args::Vector{PackageToken})
        (isempty(args) || args[1] isa PackageIdentifier) && return
        modifier = popfirst!(args)
        if modifier isa VersionRange
            pkg.version = VersionSpec(modifier)
        else # modifier isa Rev
            pkg.repo.rev = modifier.rev
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
            arg isa VersionRange ?
                pkgerror("Package name/uuid must precede version specifier `@$arg`.") :
                pkgerror("Package name/uuid must precede revision specifier `#$(arg.rev)`.")
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
    if add_or_develop && isdir_windows_workaround(expanduser(word))
        if !occursin(Base.Filesystem.path_separator_re, word)
            @info "Resolving package identifier `$word` as a directory at `$(Base.contractuser(abspath(word)))`."
        end
        return PackageSpec(repo=Types.GitRepo(source=expanduser(word)))
    elseif occursin(uuid_re, word)
        return PackageSpec(uuid=UUID(word))
    elseif occursin(name_re, word)
        return PackageSpec(String(match(name_re, word).captures[1]))
    elseif occursin(name_uuid_re, word)
        m = match(name_uuid_re, word)
        return PackageSpec(String(m.captures[1]), UUID(m.captures[2]))
    elseif add_or_develop && isurl(word)
        return PackageSpec(repo=Types.GitRepo(source=word))
    else
        pkgerror("Unable to parse `$word` as a package.")
    end
end

################
# RegistrySpec #
################
function parse_registry(raw_args::Vector{QString}; add=false)
    regs = RegistrySpec[]
    foreach(x -> push!(regs, parse_registry(x; add=add)), unwrap(raw_args))
    return regs
end

# Registries can be identified through: uuid, name, or name+uuid
# when updating/removing. When adding we can accept a local path or url.
function parse_registry(word::AbstractString; add=false)::RegistrySpec
    word = replace(word, "~" => homedir())
    registry = RegistrySpec()
    if add && isdir_windows_workaround(word) # TODO: Should be casesensitive_isdir
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
function parse_activate(args::Vector{QString})::Vector{String}
    return [(x.isquoted ? x.raw : expanduser(x.raw)) for x in args]
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
