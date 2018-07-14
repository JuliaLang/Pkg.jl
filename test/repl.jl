module REPLTests

using Pkg
import Pkg.Types.CommandError
using UUIDs
using Test
import LibGit2

include("utils.jl")

const TEST_SIG = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time()), 0)
const TEST_PKG = (name = "Example", uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))

function git_init_package(tmp, path)
    base = basename(path)
    pkgpath = joinpath(tmp, base)
    cp(path, pkgpath)
    LibGit2.with(LibGit2.init(pkgpath)) do repo
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "initial commit"; author=TEST_SIG, committer=TEST_SIG)
    end
    return pkgpath
end

@testset "generate args" begin
    @test_throws CommandError pkg"generate"
end

tempdir_util() do project_path
    cd(project_path) do
        withenv("USER" => "Test User") do
            pkg"generate HelloWorld"
            LibGit2.close((LibGit2.init(".")))
            cd("HelloWorld")
            with_current_env() do
                pkg"st"
                @eval using HelloWorld
                Base.invokelatest(HelloWorld.greet)
                @test isfile("Project.toml")
                Pkg.REPLMode.pkgstr("develop $(joinpath(@__DIR__, "test_packages", "PackageWithBuildSpecificTestDeps"))")
                Pkg.test("PackageWithBuildSpecificTestDeps")
            end
        end

        pkg"dev Example"
        devdir = joinpath(DEPOT_PATH[1], "dev", "Example")
        @test isdir(devdir)
        rm(devdir; recursive=true)
        @test !isdir(devdir)
        pkg"dev Example#DO_NOT_REMOVE"
        @test isdir(devdir)
        LibGit2.with(LibGit2.GitRepo(devdir)) do repo
            @test LibGit2.branch(repo) == "DO_NOT_REMOVE"
        end

        withenv("USER" => "Test User") do
            pkg"generate Foo"
        end
        pkg"dev Foo"
        mv(joinpath("Foo", "src", "Foo.jl"), joinpath("Foo", "src", "Foo2.jl"))
        @test_throws CommandError pkg"dev Foo"
        mv(joinpath("Foo", "src", "Foo2.jl"), joinpath("Foo", "src", "Foo.jl"))
        write(joinpath("Foo", "Project.toml"), """
            name = "Foo"
        """
        )
        @test_throws CommandError pkg"dev Foo"
        write(joinpath("Foo", "Project.toml"), """
            uuid = "b7b78b08-812d-11e8-33cd-11188e330cbe"
        """
        )
        @test_throws CommandError pkg"dev Foo"
    end
end

@testset "tokens" begin
    tokens = Pkg.REPLMode.tokenize("add git@github.com:JuliaLang/Example.jl.git")
    @test tokens[1][2] ==              "git@github.com:JuliaLang/Example.jl.git"
    tokens = Pkg.REPLMode.tokenize("add git@github.com:JuliaLang/Example.jl.git#master")
    @test tokens[1][2] ==              "git@github.com:JuliaLang/Example.jl.git"
    @test tokens[1][3].rev == "master"
    tokens = Pkg.REPLMode.tokenize("add git@github.com:JuliaLang/Example.jl.git#c37b675")
    @test tokens[1][2] ==              "git@github.com:JuliaLang/Example.jl.git"
    @test tokens[1][3].rev == "c37b675"
    tokens = Pkg.REPLMode.tokenize("add git@github.com:JuliaLang/Example.jl.git@v0.5.0")
    @test tokens[1][2] ==              "git@github.com:JuliaLang/Example.jl.git"
    @test repr(tokens[1][3]) == "VersionRange(\"0.5.0\")"
    tokens = Pkg.REPLMode.tokenize("add git@github.com:JuliaLang/Example.jl.git@0.5.0")
    @test tokens[1][2] ==              "git@github.com:JuliaLang/Example.jl.git"
    @test repr(tokens[1][3]) == "VersionRange(\"0.5.0\")"
    tokens = Pkg.REPLMode.tokenize("add git@gitlab-fsl.jsc.näsan.guvv:drats/URGA2010.jl.git@0.5.0")
    @test tokens[1][2] ==              "git@gitlab-fsl.jsc.näsan.guvv:drats/URGA2010.jl.git"
    @test repr(tokens[1][3]) == "VersionRange(\"0.5.0\")"
end

temp_pkg_dir() do project_path; cd(project_path) do; tempdir_util() do tmp_pkg_path
    pkg"activate ."
    pkg"add Example"
    @test isinstalled(TEST_PKG)
    v = Pkg.installed()[TEST_PKG.name]
    pkg"rm Example"
    pkg"add Example#master"

    # Test upgrade --fixed doesn't change the tracking (https://github.com/JuliaLang/Pkg.jl/issues/434)
    info = Pkg.Types.manifest_info(Pkg.Types.EnvCache(), TEST_PKG.uuid)
    @test info["repo-rev"] == "master"
    pkg"up --fixed"
    info = Pkg.Types.manifest_info(Pkg.Types.EnvCache(), TEST_PKG.uuid)
    @test info["repo-rev"] == "master"


    pkg"test Example"
    @test isinstalled(TEST_PKG)
    @test Pkg.installed()[TEST_PKG.name] > v
    pkg = "UnregisteredWithoutProject"
    p = git_init_package(tmp_pkg_path, joinpath(@__DIR__, "test_packages/$pkg"))
    Pkg.REPLMode.pkgstr("add $p; precompile")
    @eval import $(Symbol(pkg))
    @test Pkg.installed()[pkg] == v"0.0"
    Pkg.test("UnregisteredWithoutProject")

    pkg2 = "UnregisteredWithProject"
    p2 = git_init_package(tmp_pkg_path, joinpath(@__DIR__, "test_packages/$pkg2"))
    Pkg.REPLMode.pkgstr("add $p2")
    Pkg.REPLMode.pkgstr("pin $pkg2")
    @eval import $(Symbol(pkg2))
    @test Pkg.installed()[pkg2] == v"0.1.0"
    Pkg.REPLMode.pkgstr("free $pkg2")
    @test_throws CommandError Pkg.REPLMode.pkgstr("free $pkg2")
    Pkg.test("UnregisteredWithProject")

    write(joinpath(p2, "Project.toml"), """
        name = "UnregisteredWithProject"
        uuid = "58262bb0-2073-11e8-3727-4fe182c12249"
        version = "0.2.0"
        """
    )
    LibGit2.with(LibGit2.GitRepo, p2) do repo
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "bump version"; author = TEST_SIG, committer=TEST_SIG)
        pkg"update"
        @test Pkg.installed()[pkg2] == v"0.2.0"
        Pkg.REPLMode.pkgstr("rm $pkg2")

        c = LibGit2.commit(repo, "empty commit"; author = TEST_SIG, committer=TEST_SIG)
        c_hash = LibGit2.GitHash(c)
        Pkg.REPLMode.pkgstr("add $p2#$c")
    end

    tempdir_util() do tmp_dev_dir
    withenv("JULIA_PKG_DEVDIR" => tmp_dev_dir) do
        pkg"develop Example"

        # Copy the manifest + project and see that we can resolve it in a new environment
        # and get all the packages installed
        proj = read("Project.toml", String)
        manifest = read("Manifest.toml", String)
        cd_tempdir() do tmp
            old_depot = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                write("Project.toml", proj)
                write("Manifest.toml", manifest)
                tempdir_util() do depot_dir
                    pushfirst!(DEPOT_PATH, depot_dir)
                    pkg"instantiate"
                    @test Pkg.installed()[pkg2] == v"0.2.0"
                end
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot)
            end
        end # cd_tempdir
    end # withenv
    end # mktempdir
end # mktempdir
end # cd
end # temp_pkg_dir


temp_pkg_dir() do project_path; cd(project_path) do
    tempdir_util() do tmp
        tempdir_util() do depot_dir
            old_depot = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depot_dir)
                withenv("JULIA_PKG_DEVDIR" => tmp) do
                    # Test an unregistered package
                    p1_path = joinpath(@__DIR__, "test_packages", "UnregisteredWithProject")
                    p2_path = joinpath(@__DIR__, "test_packages", "UnregisteredWithoutProject")
                    p1_new_path = joinpath(tmp, "UnregisteredWithProject")
                    p2_new_path = joinpath(tmp, "UnregisteredWithoutProject")
                    cp(p1_path, p1_new_path)
                    cp(p2_path, p2_new_path)
                    Pkg.REPLMode.pkgstr("develop $(p1_new_path)")
                    Pkg.REPLMode.pkgstr("develop $(p2_new_path)")
                    Pkg.REPLMode.pkgstr("build; precompile")
                    @test Base.find_package("UnregisteredWithProject") == joinpath(p1_new_path, "src", "UnregisteredWithProject.jl")
                    @test Base.find_package("UnregisteredWithoutProject") == joinpath(p2_new_path, "src", "UnregisteredWithoutProject.jl")
                    @test Pkg.installed()["UnregisteredWithProject"] == v"0.1.0"
                    @test Pkg.installed()["UnregisteredWithoutProject"] == v"0.0.0"
                    Pkg.test("UnregisteredWithoutProject")
                    Pkg.test("UnregisteredWithProject")

                    pkg"develop Example#c37b675"
                    @test Base.find_package("Example") ==  joinpath(tmp, "Example", "src", "Example.jl")
                    Pkg.test("Example")
                end
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot)
            end
        end # withenv
    end # mktempdir
    # nested
    tempdir_util() do other_dir
        tempdir_util() do tmp;
            cd(tmp)
            withenv("USER" => "Test User") do
                pkg"generate HelloWorld"
                cd("HelloWorld") do
                    with_current_env() do
                        pkg"generate SubModule1"
                        pkg"generate SubModule2"
                        pkg"develop SubModule1"
                        mkdir("tests")
                        cd("tests")
                        pkg"develop ../SubModule2"
                        @test Pkg.installed()["SubModule1"] == v"0.1.0"
                        @test Pkg.installed()["SubModule2"] == v"0.1.0"
                    end
                end
                cp("HelloWorld", joinpath(other_dir, "HelloWorld"))
                cd(joinpath(other_dir, "HelloWorld"))
                with_current_env() do
                    # Check that these didnt generate absolute paths in the Manifest by copying
                    # to another directory
                    @test Base.find_package("SubModule1") == joinpath(pwd(), "SubModule1", "src", "SubModule1.jl")
                    @test Base.find_package("SubModule2") == joinpath(pwd(), "SubModule2", "src", "SubModule2.jl")
                end
            end
        end
    end
end # cd
end # temp_pkg_dir


test_complete(s) = Pkg.REPLMode.completions(s,lastindex(s))
apply_completion(str) = begin
    c, r, s = test_complete(str)
    @test s == true
    str[1:prevind(str, first(r))]*first(c)
end

# Autocompletions
temp_pkg_dir() do project_path; cd(project_path) do
    Pkg.Types.registries()
    pkg"activate ."
    c, r = test_complete("add Exam")
    @test "Example" in c
    c, r = test_complete("rm Exam")
    @test isempty(c)
    Pkg.REPLMode.pkgstr("develop $(joinpath(@__DIR__, "test_packages", "RequireDependency"))")

    c, r = test_complete("rm RequireDep")
    @test "RequireDependency" in c
    c, r = test_complete("rm -p RequireDep")
    @test "RequireDependency" in c
    c, r = test_complete("rm --project RequireDep")
    @test "RequireDependency" in c
    c, r = test_complete("rm Exam")
    @test isempty(c)
    c, r = test_complete("rm -p Exam")
    @test isempty(c)
    c, r = test_complete("rm --project Exam")
    @test isempty(c)

    c, r = test_complete("rm -m RequireDep")
    @test "RequireDependency" in c
    c, r = test_complete("rm --manifest RequireDep")
    @test "RequireDependency" in c
    c, r = test_complete("rm -m Exam")
    @test "Example" in c
    c, r = test_complete("rm --manifest Exam")
    @test "Example" in c

    c, r = test_complete("rm RequireDep")
    @test "RequireDependency" in c
    c, r = test_complete("rm Exam")
    @test isempty(c)
    c, r = test_complete("rm -m Exam")
    c, r = test_complete("rm -m Exam")
    @test "Example" in c

    pkg"add Example"
    c, r = test_complete("rm Exam")
    @test "Example" in c
    c, r = test_complete("add --man")
    @test "--manifest" in c
    c, r = test_complete("rem")
    @test "remove" in c
    @test apply_completion("rm E") == "rm Example"
    @test apply_completion("add Exampl") == "add Example"

    c, r = test_complete("preview r")
    @test "remove" in c
    c, r = test_complete("help r")
    @test "remove" in c
    @test !("rm" in c)
end end

temp_pkg_dir() do project_path; cd(project_path) do
    tempdir_util() do tmp
        cp(joinpath(@__DIR__, "test_packages", "BigProject"), joinpath(tmp, "BigProject"))
        cd(joinpath(tmp, "BigProject"))
        with_current_env() do
            # the command below also tests multiline input
            pkg"""
                dev RecursiveDep2
                dev RecursiveDep
                dev SubModule
                dev SubModule2
                add Random
                add Example
                add JSON
                build
            """
            @eval using BigProject
            pkg"build BigProject"
            @test_throws CommandError pkg"add BigProject"
            # the command below also tests multiline input
            Pkg.REPLMode.pkgstr("""
                test SubModule
                test SubModule2
                test BigProject
                test
                """)
            current_json = Pkg.API.installed()["JSON"]
            old_project = read("Project.toml", String)
            open("Project.toml"; append=true) do io
                print(io, """

                [compat]
                JSON = "0.16.0"
                """
                )
            end
            pkg"up"
            @test Pkg.API.installed()["JSON"].minor == 16
            write("Project.toml", old_project)
            pkg"up"
            @test Pkg.API.installed()["JSON"] == current_json
        end
    end
end; end

@testset "add/remove using quoted local path" begin
    setup_package(dirname, pkg_name) = begin
        pkg_path = joinpath(dirname, pkg_name)
        mkdir(dirname)
        Pkg.generate(pkg_path)
        repo = LibGit2.init(pkg_path)
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "initial commit"; author=TEST_SIG, committer=TEST_SIG)
        return ((name=pkg_name, uuid=UUID(get_uuid(pkg_path))), pkg_path)
    end

    temp_pkg_dir() do project_path; cd(project_path) do
        # testing local dir with space in name
        dir_name = "space dir"
        pkg_name = "WeirdName77"
        with_temp_env() do
            (package, pkg_path) = setup_package(dir_name, pkg_name)
            Pkg.REPLMode.pkgstr("add \"$pkg_path\"")
            @test isinstalled(package)
            Pkg.REPLMode.pkgstr("remove \"$pkg_name\"")
            @test !isinstalled(package)
        end

        # testing dir name with significant characters
        dir_name = "some@d;ir#"
        pkg_name = "WeirdName77"
        with_temp_env() do
            (package, pkg_path) = setup_package(dir_name, pkg_name)
            Pkg.REPLMode.pkgstr("add \"$pkg_path\"")
            @test isinstalled(package)
            Pkg.REPLMode.pkgstr("remove '$pkg_name'")
            @test !isinstalled(package)
        end

        dir_name = "two space dir"
        pkg_name = "name1"
        dir2 = "two'quote'dir"
        pkg_name2 = "name2"
        with_temp_env() do
            (package1, pkg_path1) = setup_package(dir_name, pkg_name)
            (package2, pkg_path2) = setup_package(dir2, pkg_name2)

            Pkg.REPLMode.pkgstr("add '$pkg_path1' \"$pkg_path2\"")
            @test isinstalled(package1)
            @test isinstalled(package2)
            Pkg.REPLMode.pkgstr("remove '$pkg_name' $pkg_name2")
            @test !isinstalled(package1)
            @test !isinstalled(package2)

            Pkg.REPLMode.pkgstr("add \"$pkg_path1\" \"$pkg_path2\"")
            @test isinstalled(package1)
            @test isinstalled(package2)
            Pkg.REPLMode.pkgstr("remove '$pkg_name' \"$pkg_name2\"")
            @test !isinstalled(package1)
            @test !isinstalled(package2)
        end
    end #cd
    end #temp_pkg_dir
end #testset

@testset "unit test `parse_package`" begin
    name = "FooBar"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    url = "https://github.com/JuliaLang/Example.jl"
    path = "./Foobar"
    # valid input
    pkg = Pkg.REPLMode.parse_package(name)
    @test pkg.name == name
    pkg = Pkg.REPLMode.parse_package(uuid)
    @test pkg.uuid == UUID(uuid)
    pkg = Pkg.REPLMode.parse_package("$name=$uuid")
    @test (pkg.name == name) && (pkg.uuid == UUID(uuid))
    pkg = Pkg.REPLMode.parse_package(url; add_or_develop=true)
    @test (pkg.repo.url == url)
    pkg = Pkg.REPLMode.parse_package(path; add_or_develop=true)
    @test (pkg.repo.url == path)
    # errors
    @test_throws CommandError Pkg.REPLMode.parse_package(url)
    @test_throws CommandError Pkg.REPLMode.parse_package(path)
end

@testset "unit test for REPLMode.promptf" begin
    function set_name(projfile_path, newname)
        sleep(1.1)
        project = Pkg.TOML.parsefile(projfile_path)
        project["name"] = newname
        open(projfile_path, "w") do io
            Pkg.TOML.print(io, project)
        end
    end

    with_temp_env("SomeEnv") do
        @test Pkg.REPLMode.promptf() == "(SomeEnv) pkg> "
    end

    env_name = "Test2"
    with_temp_env(env_name) do env_path
        projfile_path = joinpath(env_path, "Project.toml")
        @test Pkg.REPLMode.promptf() == "($env_name) pkg> "

        newname = "NewName"
        set_name(projfile_path, newname)
        @test Pkg.REPLMode.promptf() == "($env_name) pkg> "
        cd(env_path) do
            @test Pkg.REPLMode.promptf() == "($env_name) pkg> "
        end
        @test Pkg.REPLMode.promptf() == "($env_name) pkg> "

        newname = "NewNameII"
        set_name(projfile_path, newname)
        cd(env_path) do
            @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        end
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "
    end
end

@testset "`do_generate!` error paths" begin
    with_temp_env() do
        @test_throws CommandError Pkg.REPLMode.pkgstr("generate @0.0.0")
        @test_throws CommandError Pkg.REPLMode.pkgstr("generate Example Example2")
        @test_throws CommandError Pkg.REPLMode.pkgstr("generate")
    end
end

end # module
