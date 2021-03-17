using TOML

function latest_compat(range::VersionRange)
    lower = range.lower
    upper = range.upper
    t_lower = Int.(lower.t[1:lower.n])
    t_upper = Int.(upper.t[1:upper.n])
    # `t_lower` is a tuple of integers
    # `t_upper` is a tuple of integers
    # `t_lower` and `t_upper` do not necessarily have the same length
    if VersionNumber(t_lower) > VersionNumber(t_upper)
        return t_lower
    else
        return t_upper
    end
end

function latest_compat(s::VersionSpec)
    ts = latest_compat.(s.ranges)
    # `ts` is a vector of tuples of integers
    # the tuples in `ts` may have different lengths
    vers = VersionNumber.(ts)
    i = argmax(vers)
    t = ts[i]
    new_compat_entry = join(string.(t), ".")
    return new_compat_entry
end

function latest_compat(compat_entry::AbstractString)
    s = semver_spec(compat_entry)
    return latest_compat(s)
end

function force_latest_compat(compat_old::AbstractDict{<:AbstractString, <:Any})
    compat_new = Dict{String,Any}()
    for (pkg_name, old_compat_entry) in pairs(compat_old)
        compat_new[pkg_name] = latest_compat(old_compat_entry)
    end
    return compat_new
end

function force_latest_compat(filename::AbstractString)
    _filename = abspath(filename)
    project = TOML.parsefile(_filename)
    compat_old = get(project, "compat", Dict{String,Any}())
    if !isempty(compat_old)
        project["compat"] = force_latest_compat(compat_old)
        rm(_filename; force = true)
        open(_filename, "w") do io
            TOML.print(io, project)
        end
    end
    return nothing
end
