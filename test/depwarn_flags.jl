# Test that gen_subprocess_flags appends --depwarn=yes by default and respects explicit --depwarn
using Test
using Pkg

@testset "gen_subprocess_flags --depwarn behavior" begin
    # Empty julia_args should cause --depwarn=yes to be appended
    flags_empty = Pkg.Operations.gen_subprocess_flags(pwd(); coverage=false, julia_args=``)
    @test occursin("--depwarn=yes", string(flags_empty))

    # Explicit --depwarn should be respected
    flags_explicit = Pkg.Operations.gen_subprocess_flags(pwd(); coverage=false, julia_args=`--depwarn=no`)
    @test occursin("--depwarn=no", string(flags_explicit))
end
