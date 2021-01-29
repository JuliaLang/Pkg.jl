using Test
using Pkg

@testset "inference" begin
    f() = Pkg.Types.STDLIBS_BY_VERSION
    @inferred f()
    f() = Pkg.Types.UNREGISTERED_STDLIBS
    @inferred f()
end
