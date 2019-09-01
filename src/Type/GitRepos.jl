module GitRepos

export GitRepo

# The url field can also be a local path, rename?
Base.@kwdef mutable struct GitRepo
    url::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing
end

Base.:(==)(r1::GitRepo, r2::GitRepo) =
    r1.url == r2.url && r1.rev == r2.rev

end #module
