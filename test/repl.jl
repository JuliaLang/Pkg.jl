# This file is a part of Julia. License is MIT: https://julialang.org/license

module REPLTests
import ..Pkg # ensure we are using the correct Pkg

using Pkg
using Pkg.Types: manifest_info, EnvCache, Context
import Pkg.Types.PkgError
using UUIDs
using Test
using TOML
import LibGit2

using ..Utils

@testset "help" begin
    pkg"?"
    pkg"?  "
    pkg"?add"
    pkg"? add"
    pkg"?    add"
    pkg"help add"
    @test_throws PkgError pkg"helpadd"
end

temp_pkg_dir() do project_path
    with_pkg_env(project_path; change_dir=true) do;
        pkg"generate HelloWorld"
        LibGit2.close((LibGit2.init(".")))
        cd("HelloWorld")

        @test_throws PkgError pkg"dev Example#blergh"

        @test_throws PkgError pkg"generate 2019Julia"
        pkg"generate Foo"
        pkg"dev ./Foo"
        mv(joinpath("Foo", "src", "Foo.jl"), joinpath("Foo", "src", "Foo2.jl"))
        @test_throws PkgError pkg"dev ./Foo"
        ###
        mv(joinpath("Foo", "src", "Foo2.jl"), joinpath("Foo", "src", "Foo.jl"))
        write(joinpath("Foo", "Project.toml"), """
            name = "Foo"
        """
        )
        @test_throws PkgError pkg"dev ./Foo"
        write(joinpath("Foo", "Project.toml"), """
            uuid = "b7b78b08-812d-11e8-33cd-11188e330cbe"
        """
        )
        @test_throws PkgError pkg"dev ./Foo"
    end
end

temp_pkg_dir(;rm=false) do project_path; cd(project_path) do;
    tmp_pkg_path = mktempdir()

    pkg"activate ."
    pkg"add Example@0.5"
    @test isinstalled(TEST_PKG)
    v = Pkg.dependencies()[TEST_PKG.uuid].version
    pkg"rm Example"
    pkg"add Example, Random"
    pkg"rm Example Random"
    pkg"add Example,Random"
    pkg"rm Example,Random"
    pkg"add Example#master"
    pkg"rm Example"
    pkg"add https://github.com/JuliaLang/Example.jl#master"

    ## TODO: figure out how to test these in CI
    # pkg"rm Example"
    # pkg"add git@github.com:JuliaLang/Example.jl.git"
    # pkg"rm Example"
    # pkg"add \"git@github.com:JuliaLang/Example.jl.git\"#master"
    # pkg"rm Example"

    # Test upgrade --fixed doesn't change the tracking (https://github.com/JuliaLang/Pkg.jl/issues/434)
    entry = Pkg.Types.manifest_info(EnvCache().manifest, TEST_PKG.uuid)
    @test entry.repo.rev == "master"
    pkg"up --fixed"
    entry = Pkg.Types.manifest_info(EnvCache().manifest, TEST_PKG.uuid)
    @test entry.repo.rev == "master"

    pkg"test Example"
    @test isinstalled(TEST_PKG)
    @test Pkg.dependencies()[TEST_PKG.uuid].version > v

    pkg2 = "UnregisteredWithProject"
    pkg2_uuid = UUID("58262bb0-2073-11e8-3727-4fe182c12249")
    p2 = git_init_package(tmp_pkg_path, joinpath(@__DIR__, "test_packages/$pkg2"))
    Pkg.REPLMode.pkgstr("add $p2")
    Pkg.REPLMode.pkgstr("pin $pkg2")
    # FIXME: this confuses the precompile logic to know what is going on with the user
    # FIXME: why isn't this testing the Pkg after importing, rather than after freeing it
    #@eval import Example
    #@eval import $(Symbol(pkg2))
    @test Pkg.dependencies()[pkg2_uuid].version == v"0.1.0"
    Pkg.REPLMode.pkgstr("free $pkg2")
    @test_throws PkgError Pkg.REPLMode.pkgstr("free $pkg2")
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
        @test Pkg.dependencies()[pkg2_uuid].version == v"0.2.0"
        Pkg.REPLMode.pkgstr("rm $pkg2")

        c = LibGit2.commit(repo, "empty commit"; author = TEST_SIG, committer=TEST_SIG)
        c_hash = LibGit2.GitHash(c)
        Pkg.REPLMode.pkgstr("add $p2#$c")
    end

    mktempdir() do tmp_dev_dir
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
                mktempdir() do depot_dir
                    pushfirst!(DEPOT_PATH, depot_dir)
                    pkg"instantiate"
                    @test Pkg.dependencies()[pkg2_uuid].version == v"0.2.0"
                end
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot)
            end
        end # cd_tempdir
    end # withenv
    end # mktempdir
end # cd
end # temp_pkg_dir

# issue #904: Pkg.status within a git repo
temp_pkg_dir() do path
    pkg2 = "UnregisteredWithProject"
    p2 = git_init_package(path, joinpath(@__DIR__, "test_packages/$pkg2"))
    Pkg.activate(p2)
    Pkg.status() # should not throw
    Pkg.REPLMode.pkgstr("status") # should not throw
end

temp_pkg_dir() do project_path; cd(project_path) do
    mktempdir() do tmp
        mktempdir() do depot_dir
            old_depot = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                pushfirst!(DEPOT_PATH, depot_dir)
                withenv("JULIA_PKG_DEVDIR" => tmp) do
                    # Test an unregistered package
                    p1_path = joinpath(@__DIR__, "test_packages", "UnregisteredWithProject")
                    p1_new_path = joinpath(tmp, "UnregisteredWithProject")
                    cp(p1_path, p1_new_path)
                    Pkg.REPLMode.pkgstr("develop $(p1_new_path)")
                    Pkg.REPLMode.pkgstr("build; precompile")
                    @test realpath(Base.find_package("UnregisteredWithProject")) == realpath(joinpath(p1_new_path, "src", "UnregisteredWithProject.jl"))
                    @test Pkg.dependencies()[UUID("58262bb0-2073-11e8-3727-4fe182c12249")].version == v"0.1.0"
                    Pkg.test("UnregisteredWithProject")
                end
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot)
            end
        end # withenv
    end # mktempdir
    # nested
    mktempdir() do other_dir
        mktempdir() do tmp;
            cd(tmp)
            pkg"generate HelloWorld"
            cd("HelloWorld") do
                with_current_env() do
                    uuid1 = Pkg.generate("SubModule1")["SubModule1"]
                    uuid2 = Pkg.generate("SubModule2")["SubModule2"]
                    pkg"develop ./SubModule1"
                    mkdir("tests")
                    cd("tests")
                    pkg"develop ../SubModule2"
                    @test Pkg.dependencies()[uuid1].version == v"0.1.0"
                    @test Pkg.dependencies()[uuid2].version == v"0.1.0"
                    # make sure paths to SubModule1 and SubModule2 are relative
                    manifest = Pkg.Types.Context().env.manifest
                    @test manifest[uuid1].path == "SubModule1"
                    @test manifest[uuid2].path == "SubModule2"
                end
            end
            cp("HelloWorld", joinpath(other_dir, "HelloWorld"))
            cd(joinpath(other_dir, "HelloWorld"))
            with_current_env() do
                # Check that these didn't generate absolute paths in the Manifest by copying
                # to another directory
                @test Base.find_package("SubModule1") == joinpath(pwd(), "SubModule1", "src", "SubModule1.jl")
                @test Base.find_package("SubModule2") == joinpath(pwd(), "SubModule2", "src", "SubModule2.jl")
            end
        end
    end
end # cd
end # temp_pkg_dir

# activate
temp_pkg_dir() do project_path
    cd_tempdir() do tmp
        path = pwd()
        pkg"activate ."
        @test Base.active_project() == joinpath(path, "Project.toml")
        # tests illegal names for shared environments
        @test_throws Pkg.Types.PkgError pkg"activate --shared ."
        @test_throws Pkg.Types.PkgError pkg"activate --shared ./Foo"
        @test_throws Pkg.Types.PkgError pkg"activate --shared Foo/Bar"
        @test_throws Pkg.Types.PkgError pkg"activate --shared ../Bar"
        # check that those didn't change te enviroment
        @test Base.active_project() == joinpath(path, "Project.toml")
        mkdir("Foo")
        cd(mkdir("modules")) do
            pkg"generate Foo"
        end
        pkg"develop modules/Foo"
        pkg"activate Foo" # activate path Foo over deps Foo
        @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
        pkg"activate ."
        #=@test_logs (:info, r"activating new environment at ")))=# pkg"activate --shared Foo" # activate shared Foo
        @test Base.active_project() == joinpath(Pkg.envdir(), "Foo", "Project.toml")
        pkg"activate ."
        rm("Foo"; force=true, recursive=true)
        pkg"activate Foo" # activate path from developed Foo
        @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
        pkg"activate ."
        #=@test_logs (:info, r"activating new environment at ")=# pkg"activate ./Foo" # activate empty directory Foo (sidestep the developed Foo)
        @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
        pkg"activate ."
        #=@test_logs (:info, r"activating new environment at ")=# pkg"activate Bar" # activate empty directory Bar
        @test Base.active_project() == joinpath(path, "Bar", "Project.toml")
        pkg"activate ."
        pkg"add Example" # non-deved deps should not be activated
        #=@test_logs (:info, r"activating new environment at ")=# pkg"activate Example"
        @test Base.active_project() == joinpath(path, "Example", "Project.toml")
        pkg"activate ."
        cd(mkdir("tests"))
        pkg"activate Foo" # activate developed Foo from another directory
        @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
        tmpdepot = mktempdir(tmp)
        tmpdir = mkpath(joinpath(tmpdepot, "environments", "Foo"))
        push!(Base.DEPOT_PATH, tmpdepot)
        pkg"activate --shared Foo" # activate existing shared Foo
        @test Base.active_project() == joinpath(tmpdir, "Project.toml")
        pop!(Base.DEPOT_PATH)
        pkg"activate" # activate home project
        @test Base.ACTIVE_PROJECT[] === nothing
        # expansion of ~
        if !Sys.iswindows()
            pkg"activate ~/Foo_lzTkPF6N"
            @test Base.active_project() == joinpath(homedir(), "Foo_lzTkPF6N", "Project.toml")
        end
    end
end

# path should not be relative when devdir() happens to be in project
# unless user used dev --local.
temp_pkg_dir() do depot
    cd_tempdir() do tmp
        uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # Example
        pkg"activate ."
        withenv("JULIA_PKG_DEVDIR" => joinpath(pwd(), "dev")) do
            pkg"dev Example"
            @test manifest_info(EnvCache().manifest, uuid).path == joinpath(pwd(), "dev", "Example")
            pkg"dev --shared Example"
            @test manifest_info(EnvCache().manifest, uuid).path == joinpath(pwd(), "dev", "Example")
            pkg"dev --local Example"
            @test manifest_info(EnvCache().manifest, uuid).path == joinpath("dev", "Example")
        end
    end
end

test_complete(s) = Pkg.REPLMode.completions(s, lastindex(s))
apply_completion(str) = begin
    c, r, s = test_complete(str)
    str[1:prevind(str, first(r))]*first(c)
end

# Autocompletions
temp_pkg_dir() do project_path; cd(project_path) do
    @testset "tab completion while offline" begin
        # No registry and no network connection
        Pkg.offline()
        pkg"activate ."
        c, r = test_complete("add Exam")
        @test isempty(c)
        Pkg.offline(false)
        # Existing registry but no network connection
        pkg"registry add General" # instantiate the `General` registry to complete remote package names
        Pkg.offline(true)
        c, r = test_complete("add Exam")
        @test "Example" in c
        Pkg.offline(false)
    end
end end

temp_pkg_dir() do project_path; cd(project_path) do
    @testset "tab completion" begin
        pkg"registry add General" # instantiate the `General` registry to complete remote package names
        pkg"activate ."
        c, r = test_complete("add Exam")
        @test "Example" in c
        c, r = test_complete("rm Exam")
        @test isempty(c)

        Pkg.REPLMode.pkgstr("develop $(joinpath(@__DIR__, "test_packages", "PackageWithDependency"))")

        c, r = test_complete("rm PackageWithDep")
        @test "PackageWithDependency" in c
        c, r = test_complete("rm -p PackageWithDep")
        @test "PackageWithDependency" in c
        c, r = test_complete("rm --project PackageWithDep")
        @test "PackageWithDependency" in c
        c, r = test_complete("rm Exam")
        @test isempty(c)
        c, r = test_complete("rm -p Exam")
        @test isempty(c)
        c, r = test_complete("rm --project Exam")
        @test isempty(c)

        c, r = test_complete("rm -m PackageWithDep")
        @test "PackageWithDependency" in c
        c, r = test_complete("rm --manifest PackageWithDep")
        @test "PackageWithDependency" in c
        c, r = test_complete("rm -m Exam")
        @test "Example" in c
        c, r = test_complete("rm --manifest Exam")
        @test "Example" in c

        c, r = test_complete("rm PackageWithDep")
        @test "PackageWithDependency" in c
        c, r = test_complete("rm Exam")
        @test isempty(c)
        c, r = test_complete("rm -m Exam")
        c, r = test_complete("rm -m Exam")
        @test "Example" in c

        pkg"add Example"
        c, r = test_complete("rm Exam")
        @test "Example" in c
        c, r = test_complete("up --man")
        @test "--manifest" in c
        c, r = test_complete("rem")
        @test "remove" in c
        @test apply_completion("rm E") == "rm Example"
        @test apply_completion("add Exampl") == "add Example"

        # help mode
        @test apply_completion("?ad") == "?add"
        @test apply_completion("?act") == "?activate"
        @test apply_completion("? ad") == "? add"
        @test apply_completion("? act") == "? activate"

        # stdlibs
        c, r = test_complete("add Stat")
        @test "Statistics" in c
        c, r = test_complete("add Lib")
        @test "LibGit2" in c
        c, r = test_complete("add REPL")
        @test "REPL" in c

        # upper bounded
        c, r = test_complete("add Chu")
        @test !("Chunks" in c)

        # local paths
        mkpath("testdir/foo/bar")
        c, r = test_complete("add ")
        @test Sys.iswindows() ? ("testdir\\\\" in c) : ("testdir/" in c)
        @test apply_completion("add tes") == (Sys.iswindows() ? "add testdir\\\\" : "add testdir/")
        @test apply_completion("add ./tes") == (Sys.iswindows() ? "add ./testdir\\\\" : "add ./testdir/")
        c, r = test_complete("dev ./")
        @test (Sys.iswindows() ? ("testdir\\\\" in c) : ("testdir/" in c))

        # complete subdirs
        c, r = test_complete("add testdir/f")
        @test Sys.iswindows() ? ("foo\\\\" in c) : ("foo/" in c)
        @test apply_completion("add testdir/f") == (Sys.iswindows() ? "add testdir/foo\\\\" : "add testdir/foo/")
        # dont complete files
        touch("README.md")
        c, r = test_complete("add RE")
        @test !("README.md" in c)

        # Expand homedir and
        if !Sys.iswindows()
            dirname = "JuliaPkgTest744a757c-d313-11e9-1cac-118368d5977a"
            tildepath = "~/$dirname"
            try
                mkdir(expanduser(tildepath))
                c, r = test_complete("dev ~/JuliaPkgTest744a75")
                @test joinpath(homedir(), dirname, "") in c
            finally
                rm(expanduser(tildepath); force = true)
            end
            c, r = test_complete("dev ~")
            @test joinpath(homedir(), "") in c

            # nested directories
            nested_dirs = "foo/bar/baz"
            tildepath = "~/$nested_dirs"
            try
                mkpath(expanduser(tildepath))
                c, r = test_complete("dev ~/foo/bar/b")
                @test joinpath(homedir(), nested_dirs, "") in c
            finally
                rm(expanduser(tildepath); force = true)
            end
        end

        # activate
        pkg"activate --shared FooBar"
        pkg"add Example"
        pkg"activate ."
        c, r = test_complete("activate --shared ")
        @test "FooBar" in c

        # invalid options
        c, r = test_complete("rm -rf ")
        @test isempty(c)

        # parse errors should not throw
        _ = test_complete("add \"Foo")
        # invalid option should not throw
        _ = test_complete("add -z Foo")
        _ = test_complete("add --dontexist Foo")
    end # testset
end end

temp_pkg_dir() do project_path; cd(project_path) do
    mktempdir() do tmp
        cp(joinpath(@__DIR__, "test_packages", "BigProject"), joinpath(tmp, "BigProject"))
        cd(joinpath(tmp, "BigProject"))
        with_current_env() do
            # the command below also tests multiline input
            pkg"""
                dev ./RecursiveDep2
                dev ./RecursiveDep
                dev ./SubModule
                dev ./SubModule2
                add Random
                add Example
                add JSON
                build
            """
            @eval using BigProject
            pkg"build BigProject"
            @test_throws PkgError pkg"add BigProject"
            # the command below also tests multiline input
            Pkg.REPLMode.pkgstr("""
                test SubModule
                test SubModule2
                test BigProject
                test
                """)
            json_uuid = Pkg.project().dependencies["JSON"]
            current_json = Pkg.dependencies()[json_uuid].version
            old_project = read("Project.toml", String)
            open("Project.toml"; append=true) do io
                print(io, """

                [compat]
                JSON = "0.18.0"
                """
                )
            end
            pkg"up"
            @test Pkg.dependencies()[json_uuid].version.minor == 18
            write("Project.toml", old_project)
            pkg"up"
            @test Pkg.dependencies()[json_uuid].version == current_json
        end
    end
end; end

temp_pkg_dir() do project_path
    cd(project_path) do
        @testset "add/remove using quoted local path" begin
            # utils
            setup_package(parent_dir, pkg_name) = begin
                mkdir(parent_dir)
                cd(parent_dir) do
                    withenv("USER" => "Test User") do
                        Pkg.generate(pkg_name)
                    end
                    cd(pkg_name) do
                        git_init_and_commit(joinpath(project_path, parent_dir, pkg_name))
                    end #cd pkg_name
                end # cd parent_dir
            end

            # extract uuid from a Project.toml file
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

            # testing local dir with space in name
            dir_name = "space dir"
            pkg_name = "WeirdName77"
            setup_package(dir_name, pkg_name)
            uuid = extract_uuid("$dir_name/$pkg_name/Project.toml")
            Pkg.REPLMode.pkgstr("add \"$dir_name/$pkg_name\"")
            @test isinstalled((name=pkg_name, uuid = UUID(uuid)))
            Pkg.REPLMode.pkgstr("remove \"$pkg_name\"")
            @test !isinstalled((name=pkg_name, uuid = UUID(uuid)))

            # testing dir name with significant characters
            dir_name = "some@d;ir#"
            pkg_name = "WeirdName77"
            setup_package(dir_name, pkg_name)
            uuid = extract_uuid("$dir_name/$pkg_name/Project.toml")
            Pkg.REPLMode.pkgstr("add \"$dir_name/$pkg_name\"")
            @test isinstalled((name=pkg_name, uuid = UUID(uuid)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name'")
            @test !isinstalled((name=pkg_name, uuid = UUID(uuid)))

            # more complicated input
            ## pkg1
            dir1 = "two space dir"
            pkg_name1 = "name1"
            setup_package(dir1, pkg_name1)
            uuid1 = extract_uuid("$dir1/$pkg_name1/Project.toml")

            ## pkg2
            dir2 = "two'quote'dir"
            pkg_name2 = "name2"
            setup_package(dir2, pkg_name2)
            uuid2 = extract_uuid("$dir2/$pkg_name2/Project.toml")

            Pkg.REPLMode.pkgstr("add '$dir1/$pkg_name1' \"$dir2/$pkg_name2\"")
            @test isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test isinstalled((name=pkg_name2, uuid = UUID(uuid2)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name1' $pkg_name2")
            @test !isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test !isinstalled((name=pkg_name2, uuid = UUID(uuid2)))

            Pkg.REPLMode.pkgstr("add '$dir1/$pkg_name1' \"$dir2/$pkg_name2\"")
            @test isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test isinstalled((name=pkg_name2, uuid = UUID(uuid2)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name1' \"$pkg_name2\"")
            @test !isinstalled((name=pkg_name1, uuid = UUID(uuid1)))
            @test !isinstalled((name=pkg_name2, uuid = UUID(uuid2)))
        end
    end
end

@testset "parse package url win" begin
    @test typeof(Pkg.REPLMode.parse_package_identifier("https://github.com/abc/ABC.jl";
                                                       add_or_develop=true)) == Pkg.Types.PackageSpec
end

@testset "parse git url (issue #1935) " begin
    urls = ["https://github.com/abc/ABC.jl.git", "https://abc.github.io/ABC.jl"]
    for url in urls
        @test Pkg.REPLMode.package_lex([Pkg.REPLMode.QString((url), false)]) == [url]
    end
end

@testset "unit test for REPLMode.promptf" begin
    function set_name(projfile_path, newname)
        sleep(1.1)
        project = TOML.parsefile(projfile_path)
        project["name"] = newname
        open(projfile_path, "w") do io
            TOML.print(io, project)
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
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        cd(env_path) do
            @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        end
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "

        newname = "NewNameII"
        set_name(projfile_path, newname)
        cd(env_path) do
            @test Pkg.REPLMode.promptf() == "($newname) pkg> "
        end
        @test Pkg.REPLMode.promptf() == "($newname) pkg> "
    end
end

@testset "test" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        Pkg.add("Example")
        @test_throws PkgError Pkg.REPLMode.pkgstr("test --project Example")
        Pkg.REPLMode.pkgstr("test --coverage Example")
        Pkg.REPLMode.pkgstr("test Example")
    end
    end
    end
end

@testset "activate" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do;
        mkdir("Foo")
        pkg"activate"
        default = Base.active_project()
        pkg"activate Foo"
        @test Base.active_project() == joinpath(pwd(), "Foo", "Project.toml")
        pkg"activate"
        @test Base.active_project() == default
    end end end
end

@testset "status" begin
    temp_pkg_dir() do project_path
        pkg"""
        add Example Random
        status
        status -m
        status Example
        status Example=7876af07-990d-54b4-ab0e-23690620f79a
        status 7876af07-990d-54b4-ab0e-23690620f79a
        status Example Random
        status -m Example
        status --outdated
        status --compat
        """
        # --diff option
        @test_logs (:warn, r"diff option only available") pkg"status --diff"
        @test_logs (:warn, r"diff option only available") pkg"status -d"
        git_init_and_commit(project_path)
        @test_logs () pkg"status --diff"
        @test_logs () pkg"status -d"

        # comma-separated packages get parsed
        pkg"status Example, Random"
    end
end

@testset "subcommands" begin
    temp_pkg_dir() do project_path; cd_tempdir() do tmpdir; with_temp_env() do
        Pkg.REPLMode.pkg"package add Example"
        @test isinstalled(TEST_PKG)
        Pkg.REPLMode.pkg"package rm Example"
        @test !isinstalled(TEST_PKG)
    end end end
end

@testset "REPL API `up`" begin
    # errors
    temp_pkg_dir() do project_path; with_temp_env() do;
        @test_throws PkgError Pkg.REPLMode.pkgstr("up --major --minor")
    end end
end

@testset "Inference" begin
    @inferred Pkg.REPLMode.OptionSpecs(Pkg.REPLMode.OptionDeclaration[])
    @inferred Pkg.REPLMode.CommandSpecs(Pkg.REPLMode.CommandDeclaration[])
    @inferred Pkg.REPLMode.CompoundSpecs(Pair{String,Vector{Pkg.REPLMode.CommandDeclaration}}[])
end

# To be used to reply to a prompt
function withreply(f, ans)
    p = Pipe()
    try
        redirect_stdin(p) do
            @async println(p, ans)
            f()
        end
    finally
        close(p)
    end
end

@testset "REPL missing package install hook" begin
    isolate(loaded_depot=true) do
        @test Pkg.REPLMode.try_prompt_pkg_add(Symbol[:notapackage]) == false

        # don't offer to install the dummy "julia" entry that's in General
        @test Pkg.REPLMode.try_prompt_pkg_add(Symbol[:julia]) == false

        withreply("n") do
            @test Pkg.REPLMode.try_prompt_pkg_add(Symbol[:Example]) == false
        end
        withreply("y") do
            @test Pkg.REPLMode.try_prompt_pkg_add(Symbol[:Example]) == true
        end
    end
end

end # module
