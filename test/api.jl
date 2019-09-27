# This file is a part of Julia. License is MIT: https://julialang.org/license

module APITests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, Test
import Pkg.Types.PkgError, Pkg.Resolve.ResolverError
using UUIDs

using ..Utils

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
