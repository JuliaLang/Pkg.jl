# Type Parameters:
#  P = package type; eg String, UUID
#  V = version type; eg VersionNumber, Int
#  S = version set type; eg VersionSpec, Set{VersionNumber}

const SetOrVec{T} = Union{AbstractSet{T}, AbstractVector{T}}

struct PkgData{
        P, V, S,
        Vers <: AbstractVector{V},
        Deps <: AbstractDict{V,<:SetOrVec{P}},
        Comp <: AbstractDict{V,<:AbstractDict{P,S}},
    }
    versions :: Vers
    depends  :: Deps
    compat   :: Comp
    # spell out default inner constructor just to suppress
    # the provision of the default outer constructor
    function PkgData{P,V,S,Vers,Deps,Comp}(
        versions :: Vers,
        depends  :: Deps,
        compat   :: Comp,
    ) where {P,V,S,Vers,Deps,Comp}
        new{P,V,S,Vers,Deps,Comp}(versions, depends, compat)
    end
end

function PkgData(
    versions :: AbstractVector{V},
    depends  :: AbstractDict{V,<:SetOrVec{P}},
    compat   :: AbstractDict{V,<:AbstractDict{P,S}},
) where {P,V,S}
    Vers = typeof(versions)
    Deps = typeof(depends)
    Comp = typeof(compat)
    PkgData{P,V,S,Vers,Deps,Comp}(versions, depends, compat)
end

struct DepsProvider{P, D<:PkgData, R} # function or callable
    packages :: Vector{P}
    provider :: R
end

function DepsProvider(
    provider :: R,
    packages :: SetOrVec{P},
) where {P,R}
    # check arguments
    hasmethod(provider, Tuple{P}) ||
        throw(ArgumentError("provider need provider(::P) method"))
    isempty(packages) &&
        throw(ArgumentError("must provide at least one package"))

    # construct provider
    packages = sort!(P[p for p in packages])
    D = typeof(provider(first(packages)))
    DepsProvider{P,D,R}(packages, provider)
end

pkg_data(deps::DepsProvider{P,D}, pkg::P) where {P,D<:PkgData} =
    deps.provider(pkg)::D
