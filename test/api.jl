# This file is a part of Julia. License is MIT: https://julialang.org/license

module APITests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, Test
import Pkg.Types.PkgError, Pkg.Types.ResolverError
using UUIDs

using ..Utils

@testset "API should accept `AbstractString` arguments" begin
    temp_pkg_dir() do project_path
        with_temp_env() do
            Pkg.add(strip("  Example  "))
            Pkg.rm(strip("  Example "))
        end
    end
end

@testset "Pkg.rm" begin
    # rm should remove compat entries
    temp_pkg_dir() do tmp
        copy_test_package(tmp, "BasicCompat")
        Pkg.activate(joinpath(tmp, "BasicCompat"))
        @test haskey(Pkg.Types.Context().env.project.compat, "Example")
        Pkg.rm("Example")
        @test !haskey(Pkg.Types.Context().env.project.compat, "Example")
    end
end

@testset "Pkg.activate" begin
    temp_pkg_dir() do project_path
        cd_tempdir() do tmp
            path = pwd()
            Pkg.activate(".")
            mkdir("Foo")
            cd(mkdir("modules")) do
                Pkg.generate("Foo")
            end
            Pkg.develop(Pkg.PackageSpec(path="modules/Foo")) # to avoid issue #542
            Pkg.activate("Foo") # activate path Foo over deps Foo
            @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
            Pkg.activate(".")
            rm("Foo"; force=true, recursive=true)
            Pkg.activate("Foo") # activate path from developed Foo
            @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
            Pkg.activate(".")
            Pkg.activate("./Foo") # activate empty directory Foo (sidestep the developed Foo)
            @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
            Pkg.activate(".")
            Pkg.activate("Bar") # activate empty directory Bar
            @test Base.active_project() == joinpath(path, "Bar", "Project.toml")
            Pkg.activate(".")
            Pkg.add("Example") # non-deved deps should not be activated
            Pkg.activate("Example")
            @test Base.active_project() == joinpath(path, "Example", "Project.toml")
            Pkg.activate(".")
            cd(mkdir("tests"))
            Pkg.activate("Foo") # activate developed Foo from another directory
            @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
            Pkg.activate() # activate home project
            @test Base.ACTIVE_PROJECT[] === nothing
        end
    end
end

@testset "Pkg.status" begin
    temp_pkg_dir() do project_path
        Pkg.add(PackageSpec(name="Example", version="0.5.1"))
        Pkg.add("Random")
        Pkg.status()
        Pkg.status("Example")
        Pkg.status(["Example", "Random"])
        Pkg.status(PackageSpec("Example"))
        Pkg.status(PackageSpec(uuid = "7876af07-990d-54b4-ab0e-23690620f79a"))
        Pkg.status(PackageSpec.(["Example", "Random"]))
        Pkg.status(; mode=PKGMODE_MANIFEST)
        Pkg.status("Example"; mode=PKGMODE_MANIFEST)
        @test_deprecated Pkg.status(PKGMODE_MANIFEST)
        # issue #1183: Test exist in manifest but not in project
        Pkg.status("Test"; mode=PKGMODE_MANIFEST)
        @test_throws PkgError Pkg.status("Test"; mode=Pkg.Types.PKGMODE_COMBINED)
        @test_throws PkgError Pkg.status("Test"; mode=PKGMODE_PROJECT)
        # diff option
        @test_logs (:warn, r"diff option only available") Pkg.status(diff=true)
        git_init_and_commit(project_path)
        @test_logs () Pkg.status(diff=true)
    end
end

@testset "Pkg.develop" begin
    # develop tries to resolve from the manifest
    temp_pkg_dir() do project_path; with_temp_env() do env_path;
        Pkg.add(Pkg.PackageSpec(url="https://github.com/00vareladavid/Unregistered.jl"))
        Pkg.develop("Unregistered")
    end end
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir;
        exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID of Example.jl
        entry = nothing
        # explicit relative path
        with_temp_env() do env_path
            cd(env_path) do
                uuids = Pkg.generate("Foo")
                Pkg.develop(PackageSpec(;path="Foo"))
                manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
                entry = manifest[uuids["Foo"]]
            end
            @test entry.path == "Foo"
            @test entry.name == "Foo"
            @test isdir(joinpath(env_path, entry.path))
        end
        # explicit absolute path
        with_temp_env() do env_path
            cd_tempdir() do temp_dir
                uuids = Pkg.generate("Foo")
                absolute_path = abspath(joinpath(temp_dir, "Foo"))
                Pkg.develop(PackageSpec(;path=absolute_path))
                manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
                entry = manifest[uuids["Foo"]]
                @test entry.name == "Foo"
                @test entry.path == absolute_path
                @test isdir(entry.path)
            end
        end
        # name
        with_temp_env() do env_path
            Pkg.develop("Example")
            manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
            for (uuid, entry) in manifest
                if entry.name == "Example"
                    @test entry.path == joinpath(Pkg.depots1(), "dev", "Example")
                    @test isdir(entry.path)
                end
            end
        end
        # name + uuid
        with_temp_env() do env_path
            Pkg.develop(PackageSpec(name = "Example", uuid = exuuid))
            @test Pkg.Types.Context().env.manifest[exuuid].version > v"0.5"
        end
        # uuid
        with_temp_env() do env_path
            Pkg.develop(PackageSpec(uuid = exuuid))
            @test Pkg.Types.Context().env.manifest[exuuid].version > v"0.5"
        end
        # name + local
        with_temp_env() do env_path
            Pkg.develop("Example"; shared=false)
            manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
            for (uuid, entry) in manifest
                if entry.name == "Example"
                    @test entry.path == joinpath("dev", "Example")
                    @test isdir(joinpath(env_path, entry.path))
                end
            end
        end
        # url
        with_temp_env() do env_path
            url = "https://github.com/JuliaLang/Example.jl"
            Pkg.develop(PackageSpec(;url=url))
            manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
            for (uuid, entry) in manifest
                if entry.name == "Example"
                    @test entry.path == joinpath(Pkg.depots1(), "dev", "Example")
                    @test isdir(entry.path)
                end
            end
        end
        # unregistered url
        with_temp_env() do env_path
            url = "https://github.com/00vareladavid/Unregistered.jl"
            Pkg.develop(PackageSpec(;url=url))
            manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
            for (uuid, entry) in manifest
                if entry.name == "Unregistered"
                    @test uuid == UUID("dcb67f36-efa0-11e8-0cef-2fc465ed98ae")
                    @test entry.path == joinpath(Pkg.depots1(), "dev", "Unregistered")
                    @test isdir(entry.path)
                end
            end
        end
        # with rev
        with_temp_env() do env_path
            @test_throws PkgError Pkg.develop(PackageSpec(;name="Example",rev="Foobar"))
        end
    end end
end

@testset "Pkg.add" begin
    exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID of Example.jl
    # Add by version should override add by repo
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.Types.Context().env.manifest[exuuid].version == v"0.3.0"
        @test Pkg.Types.Context().env.manifest[exuuid].repo == Pkg.Types.GitRepo()
    end end
    # Add by version should override add by repo, even for indirect dependencies
    temp_pkg_dir() do project_path; mktempdir() do tempdir; with_temp_env() do
        path = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "DependsOnExample"))
        Pkg.add(Pkg.PackageSpec(;path=path))
        Pkg.add(Pkg.PackageSpec(;name="Example", rev="master"))
        Pkg.rm("Example")
        # Now `Example` should be tracking a repo and it is in the dep graph
        # But `Example` is *not* a direct dependency
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test Pkg.Types.Context().env.manifest[exuuid].version == v"0.3.0"
        @test Pkg.Types.Context().env.manifest[exuuid].repo == Pkg.Types.GitRepo()
    end end end
    # Add by URL should not override pin
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        Pkg.pin(Pkg.PackageSpec(;name="Example"))
        a = deepcopy(Pkg.Types.EnvCache().manifest)
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        b = Pkg.Types.EnvCache().manifest
        for (uuid, x) in a
            y = b[uuid]
            for property in propertynames(x)
                @test getproperty(x, property) == getproperty(y, property)
            end
        end
    end end
    # Add by URL should not overwrite files
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        t1, t2 = nothing, nothing
        for (uuid, entry) in Pkg.Types.EnvCache().manifest
            entry.name == "Example" || continue
            t1 = mtime(Pkg.Operations.find_installed(entry.name, uuid, entry.tree_hash))
        end
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/JuliaLang/Example.jl"))
        for (uuid, entry) in Pkg.Types.EnvCache().manifest
            entry.name == "Example" || continue
            t2 = mtime(Pkg.Operations.find_installed(entry.name, uuid, entry.tree_hash))
        end
        @test t1 == t2
    end end
    # Resolve tiers
    temp_pkg_dir() do tmp
        # All
        copy_test_package(tmp, "ShouldPreserveAll"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveAll"))
        parsers_uuid = UUID("69de0a69-1ddd-5017-9359-2bf0b02dc9f0")
        original_parsers_version = Pkg.dependencies()[parsers_uuid].version
        Pkg.add(Pkg.PackageSpec(;name="Example", version="0.5.0"))
        @test Pkg.dependencies()[parsers_uuid].version == original_parsers_version
        # Direct
        copy_test_package(tmp, "ShouldPreserveDirect"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveDirect"))
        ordered_collections = UUID("bac558e1-5e72-5ebc-8fee-abe8a469f55d")
        Pkg.add(Pkg.PackageSpec(;uuid=ordered_collections, version="1.0.1"))
        lazy_json = UUID("fc18253b-5e1b-504c-a4a2-9ece4944c004")
        data_structures = UUID("864edb3b-99cc-5e75-8d2d-829cb0a9cfe8")
        @test Pkg.dependencies()[lazy_json].version == v"0.1.0" # stayed the same
        @test Pkg.dependencies()[data_structures].version == v"0.16.1" # forced to change
        @test Pkg.dependencies()[ordered_collections].version == v"1.0.1" # sanity check
        # SEMVER
        copy_test_package(tmp, "ShouldPreserveSemver"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveSemver"))
        light_graphs = UUID("093fc24a-ae57-5d10-9952-331d41423f4d")
        meta_graphs = UUID("626554b9-1ddb-594c-aa3c-2596fe9399a5")
        light_graphs_version = Pkg.dependencies()[light_graphs].version
        Pkg.add(Pkg.PackageSpec(;uuid=meta_graphs, version="0.6.4"))
        @test Pkg.dependencies()[meta_graphs].version == v"0.6.4" # sanity check
        # did not break semver
        @test Pkg.dependencies()[light_graphs].version in Pkg.Types.semver_spec("$(light_graphs_version)")
        # did change version
        @test Pkg.dependencies()[light_graphs].version != light_graphs_version
        # NONE
        copy_test_package(tmp, "ShouldPreserveNone"; use_pkg=false)
        Pkg.activate(joinpath(tmp, "ShouldPreserveNone"))
        array_interface = UUID("4fba245c-0d91-5ea0-9b3e-6abc04ee57a9")
        diff_eq_diff_tools = UUID("01453d9d-ee7c-5054-8395-0335cb756afa")
        Pkg.add(Pkg.PackageSpec(;uuid=diff_eq_diff_tools, version="1.0.0"))
        @test Pkg.dependencies()[diff_eq_diff_tools].version == v"1.0.0" # sanity check
        @test Pkg.dependencies()[array_interface].version in Pkg.Types.semver_spec("1") # had to make breaking change
    end
end

@testset "Pkg.free" begin
    temp_pkg_dir() do project_path
        # Assumes that `TOML` is a registered package name
        # Can not free an un-`dev`ed un-`pin`ed package
        with_temp_env() do; mktempdir() do tempdir;
            p = git_init_package(tempdir, joinpath(@__DIR__, "test_packages", "TOML"))
            Pkg.add(Pkg.PackageSpec(;path=p))
            @test_throws PkgError Pkg.free("TOML")
        end end
        # Can free a registered package that is tracking a repo
        with_temp_env() do
            exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID of Example.jl
            Pkg.add(Pkg.PackageSpec(name = "Example", rev="495a9f2166177b4")) # same commit as release v0.5.3
            @test Pkg.Types.Context().env.manifest[exuuid].repo.rev == "495a9f2166177b4"
            Pkg.free("Example") # should not throw, see issue #1142
            @test Pkg.Types.Context().env.manifest[exuuid].repo.rev === nothing
            @test Pkg.Types.Context().env.manifest[exuuid].version > v"0.5"
        end
        # Can not free an unregistered package
        with_temp_env() do;
            Pkg.develop(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
            @test_throws PkgError Pkg.free("Unregistered")
        end
    end
end

@testset "Pkg.pin" begin
    # `pin` should detect unregistered packages
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
        @test_throws PkgError Pkg.pin(Pkg.PackageSpec(;name="Unregistered", version="0.1.0"))
    end end
    # when dealing with packages tracking a repo of a regsitered package, `pin` should do an implicit free
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;name="Example",rev="master"))
        Pkg.pin(Pkg.PackageSpec(;name="Example",version="0.1.0"))
    end end
    # pin should check for a valid version number
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;name="Example",rev="master"))
        @test_throws ResolverError Pkg.pin(Pkg.PackageSpec(;name="Example",version="100.0.0"))
    end end
end

@testset "Pkg.test" begin
    temp_pkg_dir() do tmp
        copy_test_package(tmp, "TestArguments")
        Pkg.activate(joinpath(tmp, "TestArguments"))
        # test the old code path (no test/Project.toml)
        Pkg.test("TestArguments"; test_args=`a b`, julia_args=`--quiet --check-bounds=no`)
        Pkg.test("TestArguments"; test_args=["a", "b"], julia_args=["--quiet", "--check-bounds=no"])
        # test new code path
        touch(joinpath(tmp, "TestArguments", "test", "Project.toml"))
        Pkg.test("TestArguments"; test_args=`a b`, julia_args=`--quiet --check-bounds=no`)
        Pkg.test("TestArguments"; test_args=["a", "b"], julia_args=["--quiet", "--check-bounds=no"])
    end
end

end # module APITests
