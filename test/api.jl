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
    end
end

@testset "Pkg.develop" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir;
        entry = nothing
        # explicit relative path
        with_temp_env() do env_path
            cd(env_path) do
                foo_uuid = Pkg.generate("Foo")
                Pkg.develop(PackageSpec(;path="Foo"))
                manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
                entry = manifest[foo_uuid]
            end
            @test entry.path == "Foo"
            @test entry.name == "Foo"
            @test isdir(joinpath(env_path, entry.path))
        end
        # explicit absolute path
        with_temp_env() do env_path
            cd_tempdir() do temp_dir
                foo_uuid = Pkg.generate("Foo")
                absolute_path = abspath(joinpath(temp_dir, "Foo"))
                Pkg.develop(PackageSpec(;path=absolute_path))
                manifest = Pkg.Types.read_manifest(joinpath(env_path, "Manifest.toml"))
                entry = manifest[foo_uuid]
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

end # module APITests
