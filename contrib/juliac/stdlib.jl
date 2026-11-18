# Method redefinitions in Base and the standard libraries for `--trim`, copied from
# julia nightly with the marked changes. Each one should become a fix upstream.

const _Tar = Base.loaded_modules[Base.PkgId(Base.UUID("a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"), "Tar")]
const _Artifacts = Base.loaded_modules[Base.PkgId(Base.UUID("56f22d72-fd6d-98f1-02f0-08ddc0907c33"), "Artifacts")]

# `_typeinfo_implicit` hides its call in `invoke_in_world` against invalidations (#56080)
@eval Base _typeinfo_implicit(@nospecialize(T)) = typeinfo_implicit(T)::Bool

# `string` with more than a few arguments compiles to a `Vararg` specialization
@eval Base setfield!(typeof(string).name, :max_args, Int32(10), :monotonic)
@eval Base setfield!(typeof(_string).name, :max_args, Int32(10), :monotonic)

# `lock(f, l)` on an `AbstractLock` does not specialize on `f`
@eval Base function lock(f::F, l::AbstractLock) where {F}
    lock(l)
    try
        return f()
    finally
        unlock(l)
    end
end

# CHANGED: `err.msg` is an `AbstractString`
@eval _Tar function read_standard_header(
    io::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)
    data = read_data(io, size=512, buf=buf, tee=tee)
    # zero block indicates end of tarball
    if all(iszero, data)
        while !eof(io)
            r = Int(readbytes!(io, buf))::Int
            write(tee, view(buf, 1:r))
        end
        return nothing
    end
    # verify valid header
    try
        check_version_field(buf)
        check_checksum_field(buf)
    catch err
        if err isa ErrorException
            m = match(r"^(.*?)\s*\[header block data\]"s, (err.msg isa String ? err.msg : ""))::RegexMatch
            msg = something(m.captures[1])
            msg = "This does not appear to be a TAR file/stream — $msg. Note: Tar.jl does not handle decompression; if the tarball is compressed you must use an external command like `gzcat` or package like CodecZlib.jl to decompress it. See the README file for examples."
            err = ErrorException(msg)
        end
        rethrow(err)
    end
    # extract fields we care about
    size = read_header_size(buf)
    name = read_header_str(buf, :name)
    mode = read_header_int(buf, :mode)
    type = read_header_chr(buf, :typeflag)
    link = read_header_str(buf, :linkname)
    # only ustar headers have a prefix field: old GNU headers use those
    # bytes for atime, ctime, etc. and v7 headers don't have one at all
    prefix = has_prefix_field(buf) ? read_header_str(buf, :prefix) : ""
    # check that mode isn't too big
    mode ≤ typemax(UInt16) ||
        header_error(buf, "mode value too large: $(string(mode, base=8))")
    # combine prefix & name fields
    path = isempty(prefix) ? name : "$prefix/$name"
    return Header(path, to_symbolic_type(type), mode, size, link)
end
# CHANGED: `meta isa Vector{Any}`, the type of a TOML array of tables
@eval _Artifacts function artifact_meta(name::String, artifact_dict::Dict, artifacts_toml::String;
                       platform::AbstractPlatform = HostPlatform())
    if !haskey(artifact_dict, name)
        return nothing
    end
    meta = artifact_dict[name]

    # If it's an array, find the entry that best matches our current platform
    if isa(meta, Vector{Any})
        dl_dict = Dict{Platform,Dict{String,Any}}()
        for x in meta
            x = x::Dict{String, Any}
            dl_dict[unpack_platform(x, name, artifacts_toml)::Platform] = x
        end
        meta = select_platform(dl_dict, platform)
    # If it's NOT a dict, complain
    elseif !isa(meta, Dict)
        @error("Invalid artifacts file at $(artifacts_toml): artifact '$name' malformed, must be array or dict!")
        return nothing
    end

    # This is such a no-no, we are going to call it out right here, right now.
    if meta !== nothing
        meta = meta::Dict{String, Any}
        if !haskey(meta, "git-tree-sha1")
            @error("Invalid artifacts file at $(artifacts_toml): artifact '$name' contains no `git-tree-sha1`!")
            return nothing
        end
    end

    # Return the full meta-dict.
    return meta
end
# CHANGED: call the two comparators Base defines instead of `@invokelatest` on a `Function`
@eval Base.BinaryPlatforms function platforms_match(a::AbstractPlatform, b::AbstractPlatform)
    for k in union(keys(tags(a)::Dict{String,String}), keys(tags(b)::Dict{String,String}))
        ak = get(tags(a), k, nothing)
        bk = get(tags(b), k, nothing)

        # A tag missing from one side acts as a wildcard, except for strict tags
        if ak === nothing || bk === nothing
            if k in strict_presence_tags
                return false
            end
            continue
        end

        a_comp = get_compare_strategy(a, k)
        b_comp = get_compare_strategy(b, k)

        # Throw an error if `a` and `b` have both set non-default comparison strategies for `k`
        # and they're not the same strategy.
        if a_comp !== compare_default && b_comp !== compare_default && a_comp !== b_comp
            throw(ArgumentError("Cannot compare Platform objects with two different non-default comparison strategies for the same key \"$(k)\""))
        end

        # Select the custom comparator, if we have one.
        comparator = a_comp
        if b_comp !== compare_default
            comparator = b_comp
        end

        # Call the comparator, passing in which objects requested this comparison (one, the other, or both)
        # For some comparators this doesn't matter, but for non-symmetrical comparisons, it does.
        matched = comparator === compare_default ? compare_default(ak, bk, a_comp === comparator, b_comp === comparator) :
            comparator === compare_version_cap ? compare_version_cap(ak, bk, a_comp === comparator, b_comp === comparator) :
            error("custom platform comparators are not supported in a trimmed binary")
        if !matched
            return false
        end
    end
    return true
end
# CHANGED: no `@invokelatest`
@eval Base.BinaryPlatforms function select_platform(download_info::Dict, platform::AbstractPlatform = HostPlatform())
    ps = collect(filter(p -> platforms_match(p, platform), keys(download_info)))

    if isempty(ps)
        return nothing
    end

    # At this point, we may have multiple possibilities.  We now engage a multi-
    # stage selection algorithm, where we first sort the matches by how complete
    # the match is, e.g. preferring matches where the intersection of tags is
    # equal to the union of the tags:
    function match_loss(a, b)
        a_tags = Set(keys(tags(a)))
        b_tags = Set(keys(tags(b)))
        return length(union(a_tags, b_tags)) - length(intersect(a_tags, b_tags))
    end

    # We prefer these better matches, and secondarily reverse-sort by triplet so
    # as to generally choose the latest release (e.g. a `libgfortran5` tarball
    # over a `libgfortran3` tarball).
    sort!(ps, lt = (a, b) -> begin
        loss_a = match_loss(a, platform)
        loss_b = match_loss(b, platform)
        if loss_a != loss_b
            return loss_a < loss_b
        end
        return triplet(a) > triplet(b)
    end)

    # @invokelatest here to not get invalidated by new defs of `==(::Function, ::Function)`
    return getindex(download_info, first(ps))
end

# The keyword method of `lock(f, ::ReentrantLock)` does not specialize on `f` either
@eval Base @inline function lock(f::F, l::ReentrantLock; cancel::CancelTokenArg=DEFAULT_CANCEL) where {F}
    lock(l; cancel)
    try
        return f()
    finally
        unlock(l)
    end
end

const _LibGit2 = Base.loaded_modules[Base.PkgId(Base.UUID("76f85450-5226-5b5a-8eaa-529ad045b433"), "LibGit2")]
# CHANGED: the error message shows the `Consts.OBJECT` value rather than `objtype(t)`, a `Type` known only at run time
@eval _LibGit2 function (::Type{T})(repo::GitRepo, spec::AbstractString) where T<:GitObject
    ensure_initialized()
    obj_ptr_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    @assert repo.ptr != C_NULL
    @check ccall((:git_revparse_single, libgit2), Cint,
                 (Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Cstring), obj_ptr_ptr, repo, spec)
    obj_ptr = obj_ptr_ptr[]
    if T != GitObject && T != GitUnknownObject
        t = Consts.OBJECT(obj_ptr)
        if t != Consts.OBJECT(T)
            if obj_ptr != C_NULL
                ccall((:git_object_free, libgit2), Cvoid, (Ptr{Cvoid},), obj_ptr)
            end
            throw(GitError(Error.Object, Error.ERROR, "Expected object of type $T, received object of type $t"))
        end
    end
    return T(repo, obj_ptr)
end
