using Base.BinaryPlatforms

# Our platform augmentation simply inspects the environment
function augment_platform!(p::Platform)
    # If the `flooblecrank` tag is already set, don't auto-detect!
    if haskey(p, "flooblecrank")
        return p
    end

    # If the tag is not set, autodetect through magic (in this case, checking preferences)
    ap_uuid = Base.UUID("4d5b37cf-bcfd-af76-759b-4d98ee7f9293")
    flooblecrank_status = get(Base.get_preferences(ap_uuid), "flooblecrank", "disengaged")
    if flooblecrank_status == "engaged"
        p["flooblecrank"] = "engaged"
    else
        p["flooblecrank"] = "disengaged"
    end
    return p
end
