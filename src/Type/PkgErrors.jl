module PkgErrors

export PkgError, pkgerror

###
### Pkg Error
###
struct PkgError <: Exception
    msg::String
end
pkgerror(msg::String...) = throw(PkgError(join(msg)))
Base.showerror(io::IO, err::PkgError) = print(io, err.msg)

end #module
