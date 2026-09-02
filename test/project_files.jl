module ProjectFilesTests

using Test, UUIDs
import ..Pkg
using Pkg.Types: PkgError
using ..Utils

@testset "generate" begin
    # Test generate . (issue #2821)
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            mkdir("MyNewPkg")
            cd("MyNewPkg") do
                Pkg.generate(".")
                @test isfile("Project.toml")
                @test isfile("src/MyNewPkg.jl")
                @test Pkg.Types.read_project("Project.toml").name == "MyNewPkg"
            end

            mkdir("NonEmpty")
            write("NonEmpty/existing.txt", "content")
            cd("NonEmpty") do
                @test_throws Pkg.Types.PkgError Pkg.generate(".")
            end
        end
    end
end

@testset "project files" begin
    # reading corrupted project files
    isolate(loaded_depot = true) do
        dir = joinpath(@__DIR__, "project", "bad")
        for bad_project in joinpath.(dir, readdir(dir))
            @test_throws PkgError Pkg.Types.read_project(bad_project)
        end
    end
    # reading corrupted manifest files
    isolate(loaded_depot = true) do
        dir = joinpath(@__DIR__, "manifest", "bad")
        for bad_manifest in joinpath.(dir, readdir(dir))
            @test_throws PkgError Pkg.Types.read_manifest(bad_manifest)
        end
    end
    # pruning manifest
    dir = joinpath(@__DIR__, "manifest", "unpruned")
    isolate(loaded_depot = true) do
        mktempdir() do tmp
            cp(dir, joinpath(tmp, "unpruned"))
            Pkg.activate(joinpath(tmp, "unpruned"))
            Pkg.resolve()
            @test !occursin("Crayons", read(joinpath(tmp, "unpruned", "Manifest.toml"), String))
        end
    end
    # manifest read/write
    isolate() do # TODO rewrite using IOBuffer
        manifestdir = joinpath(@__DIR__, "manifest", "good")
        temp = joinpath(mktempdir(), "x.toml")
        for testfile in joinpath.(manifestdir, readdir(manifestdir))
            a = Pkg.Types.read_manifest(testfile)
            Pkg.Types.write_manifest(a, temp)
            b = Pkg.Types.read_manifest(temp)
            for (uuid, x) in a
                y = b[uuid]
                for property in propertynames(x)
                    # `other` caches the *whole* input dictionary. its ok to mutate the fields of
                    # the input dictionary if that field will eventually be overwritten on `write_manifest`
                    property == :other && continue
                    @test getproperty(x, property) == getproperty(y, property)
                end
            end
        end
        rm(dirname(temp); recursive = true, force = true)
    end
    # project read/write
    isolate() do
        projectdir = joinpath(@__DIR__, "project", "good")
        temp = joinpath(mktempdir(), "x.toml")
        for testfile in joinpath.(projectdir, readdir(projectdir))
            a = Pkg.Types.read_project(testfile)
            Pkg.Types.write_project(a, temp)
            b = Pkg.Types.read_project(temp)
            for property in propertynames(a)
                @testset let property = property
                    @test getproperty(a, property) == getproperty(b, property)
                end
            end
            @test a == b
        end
        rm(dirname(temp); recursive = true, force = true)
    end
    # canonicalized relative paths in manifest
    isolate() do
        mktempdir() do tmp
            cd(tmp) do
                write(
                    "Manifest.toml",
                    """
                    [[Foo]]
                    path = "bar/Foo"
                    uuid = "824dc81a-29a7-11e9-3958-fba342a32644"
                    version = "0.1.0"
                    """
                )
                manifest = Pkg.Types.read_manifest("Manifest.toml")
                package = manifest[Base.UUID("824dc81a-29a7-11e9-3958-fba342a32644")]
                @test package.path == (Sys.iswindows() ? "bar\\Foo" : "bar/Foo")
                Pkg.Types.write_manifest(manifest, "Manifest.toml")
                @test occursin("path = \"bar/Foo\"", read("Manifest.toml", String))
            end
        end
    end
    # create manifest file similar to project file
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            touch(joinpath(dir, "Project.toml"))
            Pkg.activate(".")
            Pkg.add("Example")
            @test isfile(joinpath(dir, "Manifest.toml"))
            @test !isfile(joinpath(dir, "JuliaManifest.toml"))
        end
        cd_tempdir() do dir
            touch(joinpath(dir, "JuliaProject.toml"))
            Pkg.activate(".")
            Pkg.add("Example")
            @test !isfile(joinpath(dir, "Manifest.toml"))
            @test isfile(joinpath(dir, "JuliaManifest.toml"))
        end
    end
end

temp_pkg_dir() do project_path
    @testset "test entryfile entries" begin
        mktempdir() do dir
            path = copy_test_package(dir, "ProjectPath")
            cd(path) do
                with_current_env() do
                    Pkg.resolve()
                    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using ProjectPath'`))
                    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project -e 'using ProjectPathDep'`))
                end
            end
        end
    end
end

temp_pkg_dir() do project_path
    @testset "valid project file names" begin
        extract_uuid(toml_path) = begin
            uuid = ""
            for line in eachline(toml_path)
                m = match(r"uuid = \"(.+)\"", line)
                if m !== nothing
                    uuid = m.captures[1]
                    break
                end
            end
            return uuid
        end

        cd(project_path) do
            target_dir = mktempdir()
            uuid = nothing
            mktempdir() do tmp
                cd(tmp) do
                    pkg_name = "FooBar"
                    # create a project and grab its uuid
                    Pkg.generate(pkg_name)
                    uuid = extract_uuid(joinpath(pkg_name, "Project.toml"))
                    # activate project env
                    Pkg.activate(abspath(pkg_name))
                    # add an example project to populate manifest file
                    Pkg.add("Example")
                    # change away from default names
                    ## note: this is written awkwardly because a `mv` here causes failures on AppVeyor
                    cp(joinpath(pkg_name, "src"), joinpath(target_dir, "src"))
                    cp(joinpath(pkg_name, "Project.toml"), joinpath(target_dir, "JuliaProject.toml"))
                    cp(joinpath(pkg_name, "Manifest.toml"), joinpath(target_dir, "JuliaManifest.toml"))
                end
            end
            Pkg.activate()
            # make sure things still work
            Pkg.REPLMode.pkgstr("dev $target_dir")
            @test isinstalled((name = "FooBar", uuid = UUID(uuid)))
            Pkg.rm("FooBar")
            @test !isinstalled((name = "FooBar", uuid = UUID(uuid)))
        end # cd project_path
    end # @testset
end
#issue #876
@testset "targets should survive add/rm" begin
    temp_pkg_dir() do project_path
        cd_tempdir() do tmpdir
            cp(joinpath(@__DIR__, "project", "good", "pkg.toml"), "Project.toml")
            mkdir("src")
            touch("src/Pkg.jl")
            targets = deepcopy(Pkg.Types.read_project("Project.toml").targets)
            Pkg.activate(".")
            Pkg.add("Example")
            Pkg.rm("Example")
            @test targets == Pkg.Types.read_project("Project.toml").targets
        end
    end
end

end # module
