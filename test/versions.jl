module VersionsTests

import ..Pkg # ensure we are using the correct Pkg
import ..Utils
using Test

function roundtrip_semver_spec_string(str_1::AbstractString)
    spec_1 = Pkg.Versions.semver_spec(str_1)
    str_2 = Pkg.Versions.semver_spec_string(spec_1)
    spec_2 = Pkg.Versions.semver_spec(str_2)
    str_3 = Pkg.Versions.semver_spec_string(spec_2)
    spec_3 = Pkg.Versions.semver_spec(str_3)
    result = (spec_1 == spec_2) && (spec_1 == spec_3) && (spec_2 == spec_3)
    if !result
        @error("Roundtrip failed", str_1, str_2, str_3, spec_1, spec_2, spec_3)
    end
    return result
end

@testset "CompatEntryUtilities.jl" begin
    @testset "semver_spec_string" begin
        @testset begin
            let
                lower = Pkg.Versions.VersionBound()
                upper = Pkg.Versions.VersionBound(1)
                r = Pkg.Versions.VersionRange(lower, upper)
                spec = Pkg.Versions.VersionSpec([r])
                msg = "This version range cannot be represented using SemVer notation"
                @test_throws ArgumentError(msg) Pkg.Versions.semver_spec_string(spec)
            end
        end

        @testset begin
            bases = ["0.0.3", "0.2.3", "1.2.3", "0.0", "0.2", "1.2", "0", "1"]
            specifiers = ["", "^", "~", "= ", ">= ", "≥ "]
            for specifier in specifiers
                for base in bases
                    @test roundtrip_semver_spec_string("$(specifier)$(base)")
                end
                @test roundtrip_semver_spec_string(join(string.(Ref(specifier), bases), ", "))
            end
        end

        @testset begin
            bases = ["0.0.3", "0.2.3", "1.2.3", "0.2", "1.2", "1"]
            specifiers = ["< "]
            for specifier in specifiers
                for base in bases
                    @test roundtrip_semver_spec_string("$(specifier)$(base)")
                end
                @test roundtrip_semver_spec_string(join(string.(Ref(specifier), bases), ", "))
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
                @test roundtrip_semver_spec_string(str)
            end
        end
    end
end


end # module
