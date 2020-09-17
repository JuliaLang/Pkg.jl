using Base.BinaryPlatforms

# Our platform augmentation simply inspects the environment
function augment_platform!(p::Platform)
    # If the `flooblecrank` tag is already set, don't auto-detect!
    if haskey(p, "flooblecrank")
        return p
    end

    # If the tag is not set, autodetect through magic (in this case, checking environment variables)
    flooblecrank_status = get(ENV, "FLOOBLECRANK", "disengaged")
    if flooblecrank_status == "engaged"
        p["flooblecrank"] = "engaged"
    else
        p["flooblecrank"] = "disengaged"
    end
    return p
end
