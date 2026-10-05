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

struct DepsProvider{P, D<:PkgData}
    packages :: Vector{P}
    # a function or callable, called once per package and asserted to give a
    # `D`. Not a type parameter, so that what takes a provider is compiled once
    # per data type and not again for every provider, such as each release an
    # upstream probe tries
    provider :: Any
end

function DepsProvider(
    provider,
    packages :: SetOrVec{P},
) where {P}
    # check arguments
    hasmethod(provider, Tuple{P}) ||
        throw(ArgumentError("provider need provider(::P) method"))
    isempty(packages) &&
        throw(ArgumentError("must provide at least one package"))

    # construct provider
    packages = sort!(P[p for p in packages])
    D = typeof(provider(first(packages)))
    DepsProvider{P,D}(packages, provider)
end

pkg_data(deps::DepsProvider{P,D}, pkg::P) where {P,D<:PkgData} =
    deps.provider(pkg)::D
