# This file is a part of Julia. License is MIT: https://julialang.org/license

module APITests

using Pkg, Test
import Pkg.Types.PkgError

include("utils.jl")

@testset "API should accept `AbstractString` arguments" begin
    temp_pkg_dir() do project_path
        with_temp_env() do
            Pkg.add(strip("  Example  "))
            Pkg.rm(strip("  Example "))
        end
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
        Pkg.add(["Example", "Random"])
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
    end
end

@testset "Pkg.develop" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir;
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
            Pkg.add(Pkg.PackageSpec(name = "Example", rev="c37b675")) # same commit as release v0.5.1
            @test Pkg.Types.Context().env.manifest[exuuid].repo.rev == "c37b675"
            Pkg.free("Example") # should not throw, see issue #1142
            @test Pkg.Types.Context().env.manifest[exuuid].repo.rev == nothing
            @test Pkg.Types.Context().env.manifest[exuuid].version > v"0.5"
        end
        # Can not free an unregistered package
        with_temp_env() do;
            Pkg.develop(Pkg.PackageSpec(;url="https://github.com/00vareladavid/Unregistered.jl"))
            @test_throws PkgError Pkg.free("Unregistered")
        end
    end
end

@testset "Pkg.free" begin
    # `pin` should not override previous `pin`
    temp_pkg_dir() do project_path; with_temp_env() do env_path
        Pkg.add(Pkg.PackageSpec(;name="Example"))
        Pkg.pin(Pkg.PackageSpec(;name="Example", version="0.3.0"))
        @test_throws PkgError Pkg.pin(Pkg.PackageSpec(;name="Example", version="0.4.0"))
    end end
end


end # module APITests
