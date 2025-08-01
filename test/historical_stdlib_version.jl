module HistoricalStdlibVersionsTests
using ..Pkg
using Pkg.Types: is_stdlib
using Pkg: ResolverError
using Pkg.Artifacts: artifact_meta, artifact_path
using Base.BinaryPlatforms: HostPlatform, Platform, platforms_match
using Test
using TOML

ENV["HISTORICAL_STDLIB_VERSIONS_AUTO_REGISTER"] = "false"
using HistoricalStdlibVersions

include("utils.jl")
using .Utils

@testset "is_stdlib() across versions" begin
    HistoricalStdlibVersions.register!()

    networkoptions_uuid = Base.UUID("ca575930-c2e3-43a9-ace4-1e988b2c1908")
    pkg_uuid = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
    mbedtls_jll_uuid = Base.UUID("c8ffd9c3-330d-5841-b78e-0817d7145fa1")

    # Test NetworkOptions across multiple versions (It became an stdlib in v1.6+, and was registered)
    @test is_stdlib(networkoptions_uuid)
    @test is_stdlib(networkoptions_uuid, v"1.6")
    @test !is_stdlib(networkoptions_uuid, v"1.5")
    @test !is_stdlib(networkoptions_uuid, v"1.0.0")
    @test !is_stdlib(networkoptions_uuid, v"0.7")
    @test !is_stdlib(networkoptions_uuid, nothing)

    # Pkg is an unregistered stdlib and has always been an stdlib
    @test is_stdlib(pkg_uuid)
    @test is_stdlib(pkg_uuid, v"1.0")
    @test is_stdlib(pkg_uuid, v"1.6")
    @test is_stdlib(pkg_uuid, v"999.999.999")
    @test is_stdlib(pkg_uuid, v"0.7")
    @test is_stdlib(pkg_uuid, nothing)

    # MbedTLS_jll stopped being a stdlib in 1.12
    @test !is_stdlib(mbedtls_jll_uuid)
    @test !is_stdlib(mbedtls_jll_uuid, v"1.12")
    @test is_stdlib(mbedtls_jll_uuid, v"1.11")
    @test is_stdlib(mbedtls_jll_uuid, v"1.10")

    HistoricalStdlibVersions.unregister!()
    # Test that we can probe for stdlibs for the current version with no STDLIBS_BY_VERSION,
    # but that we throw a PkgError if we ask for a particular julia version.
    @test is_stdlib(networkoptions_uuid)
    @test_throws Pkg.Types.PkgError is_stdlib(networkoptions_uuid, v"1.6")
end


@testset "Pkg.add() with julia_version" begin
    HistoricalStdlibVersions.register!()

    # A package with artifacts that went from normal package -> stdlib
    gmp_jll_uuid = "781609d7-10c4-51f6-84f2-b8444358ff6d"
    # A package that has always only ever been an stdlib
    linalg_uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
    # A package that went from normal package - >stdlib
    networkoptions_uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"

    function get_manifest_block(name)
        manifest_path = joinpath(dirname(Base.active_project()), "Manifest.toml")
        @test isfile(manifest_path)
        deps = Base.get_deps(TOML.parsefile(manifest_path))
        @test haskey(deps, name)
        return only(deps[name])
    end

    isolate(loaded_depot = true) do
        # Next, test that if we ask for `v1.5` it DOES have a version, and that GMP_jll installs v6.1.X
        Pkg.add(["NetworkOptions", "GMP_jll"]; julia_version = v"1.5")
        no_block = get_manifest_block("NetworkOptions")
        @test haskey(no_block, "uuid")
        @test no_block["uuid"] == networkoptions_uuid
        @test haskey(no_block, "version")

        gmp_block = get_manifest_block("GMP_jll")
        @test haskey(gmp_block, "uuid")
        @test gmp_block["uuid"] == gmp_jll_uuid
        @test haskey(gmp_block, "version")
        @test startswith(gmp_block["version"], "6.1.2")

        # Test that the artifact of GMP_jll contains the right library
        @test haskey(gmp_block, "git-tree-sha1")
        gmp_jll_dir = Pkg.Operations.find_installed("GMP_jll", Base.UUID(gmp_jll_uuid), Base.SHA1(gmp_block["git-tree-sha1"]))
        @test isdir(gmp_jll_dir)
        artifacts_toml = joinpath(gmp_jll_dir, "Artifacts.toml")
        @test isfile(artifacts_toml)
        meta = artifact_meta("GMP", artifacts_toml)

        # `meta` can be `nothing` on some of our newer platforms; we _know_ this should
        # not be the case on the following platforms, so we check these explicitly to
        # ensure that we haven't accidentally broken something, and then we gate some
        # following tests on whether or not `meta` is `nothing`:
        for arch in ("x86_64", "i686"), os in ("linux", "mac", "windows")
            if platforms_match(HostPlatform(), Platform(arch, os))
                @test meta !== nothing
            end
        end

        # These tests require a matching platform artifact for this old version of GMP_jll,
        # which is not the case on some of our newer platforms.
        if meta !== nothing
            gmp_artifact_path = artifact_path(Base.SHA1(meta["git-tree-sha1"]))
            @test isdir(gmp_artifact_path)

            # On linux, we can check the filename to ensure it's grabbing the correct library
            if Sys.islinux()
                libgmp_filename = joinpath(gmp_artifact_path, "lib", "libgmp.so.10.3.2")
                @test isfile(libgmp_filename)
            end
        end
    end

    # Next, test that if we ask for `v1.6`, GMP_jll gets `v6.2.0`, and for `v1.7`, it gets `v6.2.1`
    function do_gmp_test(julia_version, gmp_version)
        isolate(loaded_depot = true) do
            Pkg.add("GMP_jll"; julia_version)
            gmp_block = get_manifest_block("GMP_jll")
            @test haskey(gmp_block, "uuid")
            @test gmp_block["uuid"] == gmp_jll_uuid
            @test haskey(gmp_block, "version")
            @test startswith(gmp_block["version"], string(gmp_version))
        end
    end
    do_gmp_test(v"1.6", v"6.2.0")
    do_gmp_test(v"1.7", v"6.2.1")

    isolate(loaded_depot = true) do
        # Next, test that if we ask for `nothing`, NetworkOptions has a `version` but `LinearAlgebra` does not.
        Pkg.add(["LinearAlgebra", "NetworkOptions"]; julia_version = nothing)
        no_block = get_manifest_block("NetworkOptions")
        @test haskey(no_block, "uuid")
        @test no_block["uuid"] == networkoptions_uuid
        @test haskey(no_block, "version")
        linalg_block = get_manifest_block("LinearAlgebra")
        @test haskey(linalg_block, "uuid")
        @test linalg_block["uuid"] == linalg_uuid
        @test !haskey(linalg_block, "version")
    end

    isolate(loaded_depot = true) do
        # Next, test that stdlibs do not get dependencies from the registry
        # NOTE: this test depends on the fact that in Julia v1.6+ we added
        # "fake" JLLs that do not depend on Pkg while the "normal" p7zip_jll does.
        # A future p7zip_jll in the registry may not depend on Pkg, so be sure
        # to verify your assumptions when updating this test.
        Pkg.add("p7zip_jll")
        p7zip_jll_uuid = Base.UUID("3f19e933-33d8-53b3-aaab-bd5110c3b7a0")
        @test !("Pkg" in keys(Pkg.dependencies()[p7zip_jll_uuid].dependencies))
    end

    HistoricalStdlibVersions.unregister!()
end

@testset "Resolving for another version of Julia" begin
    HistoricalStdlibVersions.register!()
    temp_pkg_dir() do dir
        function find_by_name(versions, name)
            idx = findfirst(p -> p.name == name, versions)
            if idx === nothing
                return nothing
            end
            return versions[idx]
        end

        # First, we're going to resolve for specific versions of Julia, ensuring we get the right dep versions:
        Pkg.Registry.download_default_registries(Pkg.stdout_f())
        ctx = Pkg.Types.Context(; julia_version = v"1.5")
        versions, deps = Pkg.Operations._resolve(
            ctx.io, ctx.env, ctx.registries, [
                Pkg.Types.PackageSpec(name = "MPFR_jll", uuid = Base.UUID("3a97d323-0669-5f0c-9066-3539efd106a3")),
            ], Pkg.Types.PRESERVE_TIERED, ctx.julia_version, ctx.resolver
        )
        gmp = find_by_name(versions, "GMP_jll")
        @test gmp !== nothing
        @test gmp.version.major == 6 && gmp.version.minor == 1
        ctx = Pkg.Types.Context(; julia_version = v"1.6")
        versions, deps = Pkg.Operations._resolve(
            ctx.io, ctx.env, ctx.registries, [
                Pkg.Types.PackageSpec(name = "MPFR_jll", uuid = Base.UUID("3a97d323-0669-5f0c-9066-3539efd106a3")),
            ], Pkg.Types.PRESERVE_TIERED, ctx.julia_version, ctx.resolver
        )
        gmp = find_by_name(versions, "GMP_jll")
        @test gmp !== nothing
        @test gmp.version.major == 6 && gmp.version.minor == 2

        # We'll also test resolving an "impossible" manifest; one that requires two package versions that
        # are not both loadable by the same Julia:
        ctx = Pkg.Types.Context(; julia_version = nothing)
        versions, deps = Pkg.Operations._resolve(
            ctx.io, ctx.env, ctx.registries, [
                # This version of GMP only works on Julia v1.6
                Pkg.Types.PackageSpec(name = "GMP_jll", uuid = Base.UUID("781609d7-10c4-51f6-84f2-b8444358ff6d"), version = v"6.2.0"),
                # This version of MPFR only works on Julia v1.5
                Pkg.Types.PackageSpec(name = "MPFR_jll", uuid = Base.UUID("3a97d323-0669-5f0c-9066-3539efd106a3"), version = v"4.0.2"),
            ], Pkg.Types.PRESERVE_TIERED, ctx.julia_version, ctx.resolver
        )
        gmp = find_by_name(versions, "GMP_jll")
        @test gmp !== nothing
        @test gmp.version.major == 6 && gmp.version.minor == 2
        mpfr = find_by_name(versions, "MPFR_jll")
        @test mpfr !== nothing
        @test mpfr.version.major == 4 && mpfr.version.minor == 0
    end
    HistoricalStdlibVersions.unregister!()
end

HelloWorldC_jll_UUID = Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")
GMP_jll_UUID = Base.UUID("781609d7-10c4-51f6-84f2-b8444358ff6d")
OpenBLAS_jll_UUID = Base.UUID("4536629a-c528-5b80-bd46-f80d51c5b363")
libcxxwrap_julia_jll_UUID = Base.UUID("3eaa8342-bff7-56a5-9981-c04077f7cee7")
libblastrampoline_jll_UUID = Base.UUID("8e850b90-86db-534c-a0d3-1478176c7d93")

isolate(loaded_depot = true) do
    @testset "Elliot and Mosè's mini Pkg test suite" begin # https://github.com/JuliaPackaging/JLLPrefixes.jl/issues/6
        HistoricalStdlibVersions.register!()
        @testset "Standard add" begin
            Pkg.activate(temp = true)
            # Standard add (non-stdlib, flexible version)
            Pkg.add(; name = "HelloWorldC_jll")
            @test haskey(Pkg.dependencies(), HelloWorldC_jll_UUID)

            Pkg.activate(temp = true)
            # Standard add (non-stdlib, url and rev)
            Pkg.add(; name = "HelloWorldC_jll", url = "https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl", rev = "0b4959a49385d4bb00efd281447dc19348ebac08")
            @test Pkg.dependencies()[Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")].git_revision === "0b4959a49385d4bb00efd281447dc19348ebac08"

            Pkg.activate(temp = true)
            # Standard add (non-stdlib, specified version)
            Pkg.add(; name = "HelloWorldC_jll", version = v"1.0.10+1")
            @test Pkg.dependencies()[Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")].version === v"1.0.10+1"

            Pkg.activate(temp = true)
            # Standard add (non-stdlib, versionspec)
            Pkg.add(; name = "HelloWorldC_jll", version = Pkg.Types.VersionSpec("1.0.10"))
            @test Pkg.dependencies()[Base.UUID("dca1746e-5efc-54fc-8249-22745bc95a49")].version === v"1.0.10+1"
        end

        @testset "Julia-version-dependent add" begin
            Pkg.activate(temp = true)
            # Julia-version-dependent add (non-stdlib, flexible version)
            Pkg.add(; name = "libcxxwrap_julia_jll", julia_version = v"1.7")
            @test Pkg.dependencies()[libcxxwrap_julia_jll_UUID].version >= v"0.14.0+0"

            Pkg.activate(temp = true)
            # Julia-version-dependent add (non-stdlib, specified version)
            Pkg.add(; name = "libcxxwrap_julia_jll", version = v"0.9.4+0", julia_version = v"1.7")
            @test Pkg.dependencies()[libcxxwrap_julia_jll_UUID].version === v"0.9.4+0"

            Pkg.activate(temp = true)
            Pkg.add(; name = "libcxxwrap_julia_jll", version = v"0.8.8+1", julia_version = v"1.9")
            # FIXME? Pkg.dependencies() complains here that mbedtls_jll isn't installed so can't be used here.
            # Perhaps Pkg.dependencies() should just return state and not error if source isn't installed?
            @test_skip Pkg.dependencies()[libcxxwrap_julia_jll_UUID].version === v"0.9.4+0"
            for pkgspec in Pkg.Operations.load_all_deps_loadable(Pkg.Types.Context().env)
                if pkgspec.uuid == libcxxwrap_julia_jll_UUID
                    @test pkgspec.version === v"0.8.8+1"
                end
            end
        end

        @testset "Old Pkg add regression" begin
            Pkg.activate(temp = true)
            Pkg.add(; name = "Pkg", julia_version = v"1.11")
        end

        @testset "Stdlib add" begin
            Pkg.activate(temp = true)
            # Stdlib add (current julia version)
            Pkg.add(; name = "GMP_jll")
            @test Pkg.dependencies()[GMP_jll_UUID].version >= v"6.3.0+2" # v1.13.0-DEV

            Pkg.activate(temp = true)
            # Make sure the source of GMP_jll is installed
            Pkg.add([PackageSpec("GMP_jll")]; julia_version = v"1.6")
            src = Pkg.Operations.find_installed(
                "GMP_jll",
                Base.UUID("781609d7-10c4-51f6-84f2-b8444358ff6d"),
                Base.SHA1("40388878122d491a2e55b0e730196098595d8a90")
            )
            @test src isa String
            # issue https://github.com/JuliaLang/Pkg.jl/issues/2930
            @test_broken isdir(src)
            @test_broken isfile(joinpath(src, "Artifacts.toml"))

            Pkg.activate(temp = true)
            # Stdlib add (other julia version)
            Pkg.add(; name = "GMP_jll", julia_version = v"1.7")
            @test Pkg.dependencies()[GMP_jll_UUID].version === v"6.2.1+1"

            # Stdlib add (other julia version, with specific version bound)
            # Note, this doesn't work properly, it adds but doesn't install any artifacts.
            # Technically speaking, this is probably okay from Pkg's perspective, since
            # we're asking Pkg to resolve according to what Julia v1.7 would do.... and
            # Julia v1.7 would not install anything because it's a stdlib!  However, we
            # would sometimes like to resolve the latest version of GMP_jll for Julia v1.7
            # then install that.  If we have to manually work around that and look up what
            # GMP_jll for Julia v1.7 is, then ask for that version explicitly, that's ok.

            Pkg.activate(temp = true)
            Pkg.add(; name = "GMP_jll", julia_version = v"1.7")

            # This is expected to fail, that version can't live with `julia_version = v"1.7"`
            @test_throws ResolverError Pkg.add(; name = "GMP_jll", version = v"6.2.0+5", julia_version = v"1.7")

            Pkg.activate(temp = true)
            # Stdlib add (julia_version == nothing)
            # Note: this is currently known to be broken, we get the wrong GMP_jll!
            Pkg.add(; name = "GMP_jll", version = v"6.2.1+1", julia_version = nothing)
            @test_broken Pkg.dependencies()[GMP_jll_UUID].version === v"6.2.1+1"
        end

        @testset "julia_version = nothing" begin
            @testset "stdlib add" begin
                Pkg.activate(temp = true)
                # Stdlib add (impossible constraints due to julia version compat, so
                # must pass `julia_version=nothing`). In this case, we always fully
                # specify versions, but if we don't, it's okay to just give us whatever
                # the resolver prefers
                Pkg.add(
                    [
                        PackageSpec(; name = "OpenBLAS_jll", version = v"0.3.13"),
                        PackageSpec(; name = "libblastrampoline_jll", version = v"5.1.1"),
                    ]; julia_version = nothing
                )
                @test v"0.3.14" > Pkg.dependencies()[OpenBLAS_jll_UUID].version >= v"0.3.13"
                @test v"5.1.2" > Pkg.dependencies()[libblastrampoline_jll_UUID].version >= v"5.1.1"
            end
            @testset "non-stdlib JLL add" begin
                platform = Platform("x86_64", "linux"; libc = "musl")
                # specific version vs. compat spec
                @testset for version in (v"3.24.3+0", "3.24.3")
                    dependencies = [PackageSpec(; name = "CMake_jll", version = version)]
                    @testset "with context (using private Pkg.add method)" begin
                        Pkg.activate(temp = true)
                        ctx = Pkg.Types.Context(; julia_version = nothing)
                        mydeps = deepcopy(dependencies)
                        foreach(Pkg.API.handle_package_input!, mydeps)
                        Pkg.add(ctx, mydeps; platform)
                    end
                    @testset "with julia_version" begin
                        Pkg.activate(temp = true)
                        Pkg.add(deepcopy(dependencies); platform, julia_version = nothing)
                    end
                end
            end
        end
        HistoricalStdlibVersions.unregister!()
    end
end

end # module
