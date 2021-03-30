# This file is a part of Julia. License is MIT: https://julialang.org/license

module VersionsTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

function roundtrip_to_semver_spec(str_1::AbstractString)
    spec_1 = Pkg.Versions.semver_spec(str_1)
    str_2 = Pkg.Versions.to_semver_spec(spec_1)
    spec_2 = Pkg.Versions.semver_spec(str_2)
    str_3 = Pkg.Versions.to_semver_spec(spec_2)
    spec_3 = Pkg.Versions.semver_spec(str_3)
    result = (spec_1 == spec_2) && (spec_1 == spec_3) && (spec_2 == spec_3)
    if !result
        @info("", spec_1, spec_2, spec_3, str_1, str_2, str_3)
    end
    return result
end

@testset "Pkg.Versions.to_semver_spec" begin
    @testset begin
        bases = ["0.0.3", "0.2.3", "1.2.3", "0.0", "0.2", "1.2", "0", "1"]
        specifiers = ["", "^", "~", "= ", ">= ", "≥ "]
        for specifier in specifiers
            for base in bases
                @test roundtrip_to_semver_spec("$(specifier)$(base)")
            end
            @test roundtrip_to_semver_spec(join(string.(Ref(specifier), bases), ", "))
        end
    end

    @testset begin
        bases = ["0.0.3", "0.2.3", "1.2.3", "0.2", "1.2", "1"]
        specifiers = ["< "]
        for specifier in specifiers
            for base in bases
                @test roundtrip_to_semver_spec("$(specifier)$(base)")
            end
            @test roundtrip_to_semver_spec(join(string.(Ref(specifier), bases), ", "))
        end
    end

    @testset begin
        strs = [
            # ranges
            "1.2.3 - 4.5.6",
            "0.2.3 - 4.5.6",
            "1.2 - 4.5.6",
            "1 - 4.5.6",
            "0.2 - 4.5.6",
            "0.2 - 0.5.6",
            "1.2.3 - 4.5",
            "1.2.3 - 4",
            "1.2 - 4.5",
            "1.2 - 4",
            "1 - 4.5",
            "1 - 4",
            "0.2.3 - 4.5",
            "0.2.3 - 4",
            "0.2 - 4.5",
            "0.2 - 4",
            "0.2 - 0.5",
            "0.2 - 0",

            # multiple ranges
            "1 - 2.3, 4.5.6 - 7.8.9",

            # other stuff
            "1 - 0",
            "2 - 1",
            ">= 0",
        ]

        for str in strs
            @test roundtrip_to_semver_spec(str)
        end
    end
end

end # module
