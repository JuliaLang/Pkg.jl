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
import REPL
const REPLExt = Base.get_extension(Pkg, :REPLExt)

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

@testset "accidental" begin
    pkg"]?"
    pkg"] ?"
    pkg"]st"
    pkg"] st"
    pkg"]st -m"
    pkg"] st -m"
    pkg"]"  # noop
end

temp_pkg_dir() do project_path
    with_pkg_env(project_path; change_dir = true) do;
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
        write(
            joinpath("Foo", "Project.toml"), """
                name = "Foo"
            """
        )
        @test_throws PkgError pkg"dev ./Foo"
        write(
            joinpath("Foo", "Project.toml"), """
                uuid = "b7b78b08-812d-11e8-33cd-11188e330cbe"
            """
        )
        @test_throws PkgError pkg"dev ./Foo"
    end
end

temp_pkg_dir(; rm = false) do project_path
    cd(project_path) do;
        tmp_pkg_path = mktempdir()

        pkg"activate ."
        pkg"add Example@0.5.3"
        @test isinstalled(TEST_PKG)
        v = Pkg.dependencies()[TEST_PKG.uuid].version
        @test v == v"0.5.3"
        pkg"rm Example"
        pkg"add Example, Random"
        pkg"rm Example Random"
        pkg"add Example,Random"
        pkg"rm Example,Random"
        # Test leading whitespace handling (issue #4239)
        pkg"    add Example, Random"
        pkg"rm Example Random"
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

        write(
            joinpath(p2, "Project.toml"), """
            name = "UnregisteredWithProject"
            uuid = "58262bb0-2073-11e8-3727-4fe182c12249"
            version = "0.2.0"
            """
        )
        LibGit2.with(LibGit2.GitRepo, p2) do repo
            LibGit2.add!(repo, "*")
            LibGit2.commit(repo, "bump version"; author = TEST_SIG, committer = TEST_SIG)
            pkg"update"
            @test Pkg.dependencies()[pkg2_uuid].version == v"0.2.0"
            Pkg.REPLMode.pkgstr("rm $pkg2")

            c = LibGit2.commit(repo, "empty commit"; author = TEST_SIG, committer = TEST_SIG)
            c_hash = LibGit2.GitHash(c)
            Pkg.REPLMode.pkgstr("add $p2#$c")
        end

        mktempdir() do tmp_dev_dir
            withenv("JULIA_PKG_DEVDIR" => tmp_dev_dir) do
                pkg"develop Example"
                pkg"develop Example,PackageCompiler"
                pkg"develop Example PackageCompiler"

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
                            Base.append_bundled_depot_path!(DEPOT_PATH)
                            pkg"instantiate"
                            @test Pkg.dependencies()[pkg2_uuid].version == v"0.2.0"
                        end
                    finally
                        empty!(DEPOT_PATH)
                        append!(DEPOT_PATH, old_depot)
                        Base.append_bundled_depot_path!(DEPOT_PATH)
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

temp_pkg_dir() do project_path
    cd(project_path) do
        mktempdir() do tmp
            mktempdir() do depot_dir
                old_depot = copy(DEPOT_PATH)
                try
                    empty!(DEPOT_PATH)
                    pushfirst!(DEPOT_PATH, depot_dir)
                    Base.append_bundled_depot_path!(DEPOT_PATH)
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
                    Base.append_bundled_depot_path!(DEPOT_PATH)
                end
            end # withenv
        end # mktempdir
        # nested
        mktempdir() do other_dir
            mktempdir() do tmp
                cd(tmp) do
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
        # check that those didn't change the environment
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
        rm("Foo"; force = true, recursive = true)
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
        pkg"activate" # activate LOAD_PATH project
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

test_complete(s) = REPLExt.completions(s, lastindex(s))
apply_completion(str) = begin
    c, r, s = test_complete(str)
    str[1:prevind(str, first(r))] * first(c)
end

# Autocompletions
temp_pkg_dir() do project_path
    cd(project_path) do
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
    end
end

temp_pkg_dir() do project_path
    cd(project_path) do
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
            c, r = test_complete("free PackageWithDep")
            @test "PackageWithDependency" in c # given this was devved

            c, r = test_complete("rm -m PackageWithDep")
            @test "PackageWithDependency" in c
            c, r = test_complete("rm --manifest PackageWithDep")
            @test "PackageWithDependency" in c
            c, r = test_complete("rm -m Exam")
            @test "Example" in c
            c, r = test_complete("rm --manifest Exam")
            @test "Example" in c
            c, r = test_complete("why PackageWithDep")
            @test "PackageWithDependency" in c

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
            c, r = test_complete("free Exa")
            @test isempty(c) # given this was added i.e. not fixed
            pkg"pin Example"
            c, r = test_complete("free Exa")
            @test "Example" in c
            pkg"free Example"

            # Test for issue #59829 - completion with only trailing space should work
            # When typing "rm <TAB>" with Example installed, should complete to "rm Example"
            c, r = test_complete("rm ")
            @test "Example" in c
            @test apply_completion("rm ") == "rm Example"

            # Test deduplication of already-specified packages (issue #4098)
            # After typing "rm Example ", typing "E" should not suggest Example again
            c, r = test_complete("rm Example E")
            @test !("Example" in c) # Example already specified, should not suggest again

            # Test with package@version syntax - should still deduplicate
            c, r = test_complete("rm Example@0.5 Exam")
            @test !("Example" in c) # Example already specified with version

            # Test with multiple packages already specified
            c, r = test_complete("rm Example PackageWithDependency E")
            @test !("Example" in c) # Both already specified
            @test !("PackageWithDependency" in c)

            # Test deduplication works for add as well
            c, r = test_complete("add Example E")
            @test !("Example" in c) # Example already specified for add command

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

            # Test the fix for issue #58690 - completion should return proper types
            # This ensures Pkg completions return Vector{String}, Region, Bool format
            c, r = test_complete("add Example")
            @test c isa Vector{String}
            @test r isa UnitRange{Int}  # This gets converted to Region in the completion provider

            # Test completion at end of a complete word doesn't crash
            c, r = test_complete("add Example")
            @test !isempty(c)  # Should have completions

            # Test the completion provider LineEdit interface directly (for coverage of the fix)
            # This is the actual code path that was failing in issue #58690
            provider = REPLExt.PkgCompletionProvider()

            # Create a mock state that has the required interface
            mock_state = (
                input_buffer = let buf = IOBuffer()
                    write(buf, "add Example"); seek(buf, sizeof("add Example")); buf
                end,
            )

            # Define the required interface methods for our mock
            @eval REPL.beforecursor(state::NamedTuple) = String(state.input_buffer.data[1:(state.input_buffer.ptr - 1)])
            @eval REPL.LineEdit.input_string(state::NamedTuple) = String(state.input_buffer.data[1:state.input_buffer.size])

            # This calls the modified LineEdit.complete_line method
            completions, region, should_complete = @invokelatest REPL.LineEdit.complete_line(provider, mock_state)
            @test completions isa Vector{REPL.LineEdit.NamedCompletion}
            @test region isa Pair{Int, Int}  # This is the key fix - Region not String
            @test should_complete isa Bool

            # Test the empty range edge case for coverage
            mock_state_empty = (
                input_buffer = let buf = IOBuffer()
                    write(buf, ""); seek(buf, 0); buf
                end,
            )
            completions_empty, region_empty, should_complete_empty = @invokelatest REPL.LineEdit.complete_line(provider, mock_state_empty)
            @test region_empty isa Pair{Int, Int}

            # Test for issue #4121 - completion after semicolon should not crash
            # When typing "a;" and hitting tab, partial can be nothing causing startswith crash
            c, r = test_complete("a;")
            @test c isa Vector{String}  # Should not crash, return empty or valid completions
            @test r isa UnitRange{Int}
        end # testset
    end
end

temp_pkg_dir() do project_path
    cd(project_path) do
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
                Pkg.REPLMode.pkgstr(
                    """
                    test SubModule
                    test SubModule2
                    test BigProject
                    test
                    """
                )
                json_uuid = Pkg.project().dependencies["JSON"]
                current_json = Pkg.dependencies()[json_uuid].version
                old_project = read("Project.toml", String)
                Pkg.compat("JSON", "0.18.0")
                pkg"up"
                @test Pkg.dependencies()[json_uuid].version.minor == 18
                write("Project.toml", old_project)
                pkg"up"
                @test Pkg.dependencies()[json_uuid].version == current_json
            end
        end
    end
end

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
            @test isinstalled((name = pkg_name, uuid = UUID(uuid)))
            Pkg.REPLMode.pkgstr("remove \"$pkg_name\"")
            @test !isinstalled((name = pkg_name, uuid = UUID(uuid)))

            # testing dir name with significant characters
            dir_name = "some@d;ir#"
            pkg_name = "WeirdName77"
            setup_package(dir_name, pkg_name)
            uuid = extract_uuid("$dir_name/$pkg_name/Project.toml")
            Pkg.REPLMode.pkgstr("add \"$dir_name/$pkg_name\"")
            @test isinstalled((name = pkg_name, uuid = UUID(uuid)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name'")
            @test !isinstalled((name = pkg_name, uuid = UUID(uuid)))

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
            @test isinstalled((name = pkg_name1, uuid = UUID(uuid1)))
            @test isinstalled((name = pkg_name2, uuid = UUID(uuid2)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name1' $pkg_name2")
            @test !isinstalled((name = pkg_name1, uuid = UUID(uuid1)))
            @test !isinstalled((name = pkg_name2, uuid = UUID(uuid2)))

            Pkg.REPLMode.pkgstr("add '$dir1/$pkg_name1' \"$dir2/$pkg_name2\"")
            @test isinstalled((name = pkg_name1, uuid = UUID(uuid1)))
            @test isinstalled((name = pkg_name2, uuid = UUID(uuid2)))
            Pkg.REPLMode.pkgstr("remove '$pkg_name1' \"$pkg_name2\"")
            @test !isinstalled((name = pkg_name1, uuid = UUID(uuid1)))
            @test !isinstalled((name = pkg_name2, uuid = UUID(uuid2)))
        end
    end
end

@testset "parse package url win" begin
    pkg_id = Pkg.REPLMode.PackageIdentifier("https://github.com/abc/ABC.jl")
    pkg_spec = Pkg.REPLMode.parse_package_identifier(pkg_id; add_or_develop = true)
    @test typeof(pkg_spec) == Pkg.Types.PackageSpec
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
        @test REPLExt.promptf() == "(SomeEnv) pkg> "
    end

    with_temp_env("this_is_a_test_for_truncating_long_folder_names_in_the_prompt") do
        @test REPLExt.promptf() == "(this_is_a_test_for_truncati...) pkg> "
    end

    env_name = "Test2"
    with_temp_env(env_name) do env_path
        projfile_path = joinpath(env_path, "Project.toml")
        @test REPLExt.promptf() == "($env_name) pkg> "

        newname = "NewName"
        set_name(projfile_path, newname)
        @test REPLExt.promptf() == "($newname) pkg> "
        cd(env_path) do
            @test REPLExt.promptf() == "($newname) pkg> "
        end
        @test REPLExt.promptf() == "($newname) pkg> "

        newname = "NewNameII"
        set_name(projfile_path, newname)
        cd(env_path) do
            @test REPLExt.promptf() == "($newname) pkg> "
        end
        @test REPLExt.promptf() == "($newname) pkg> "
    end
end

@testset "test" begin
    temp_pkg_dir() do project_path
        cd_tempdir() do tmpdir
            with_temp_env() do;
                Pkg.add("Example")
                @test_throws PkgError Pkg.REPLMode.pkgstr("test --project Example")
                Pkg.REPLMode.pkgstr("test --coverage Example")
                Pkg.REPLMode.pkgstr("test Example")
            end
        end
    end
end

@testset "activate" begin
    temp_pkg_dir() do project_path
        cd_tempdir() do tmpdir
            with_temp_env() do;
                mkdir("Foo")
                pkg"activate"
                default = Base.active_project()
                pkg"activate Foo"
                @test Base.active_project() == joinpath(pwd(), "Foo", "Project.toml")
                pkg"activate"
                @test Base.active_project() == default
            end
        end
    end
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
    temp_pkg_dir() do project_path
        cd_tempdir() do tmpdir
            with_temp_env() do
                Pkg.REPLMode.pkg"package add Example"
                @test isinstalled(TEST_PKG)
                Pkg.REPLMode.pkg"package rm Example"
                @test !isinstalled(TEST_PKG)
            end
        end
    end
end

@testset "REPL API `up`" begin
    # errors
    temp_pkg_dir() do project_path
        with_temp_env() do;
            @test_throws PkgError Pkg.REPLMode.pkgstr("up --major --minor")
        end
    end
end

@testset "Inference" begin
    @inferred Pkg.REPLMode.OptionSpecs(Pkg.REPLMode.OptionDeclaration[])
    @inferred Pkg.REPLMode.CommandSpecs(Pkg.REPLMode.CommandDeclaration[])
    @inferred Pkg.REPLMode.CompoundSpecs(Pair{String, Vector{Pkg.REPLMode.CommandDeclaration}}[])
end

# To be used to reply to a prompt
function withreply(f, ans)
    p = Pipe()
    return try
        redirect_stdin(p) do
            @async println(p, ans)
            f()
        end
    finally
        close(p)
    end
end

@testset "REPL missing package install hook" begin
    isolate(loaded_depot = true) do
        @test REPLExt.try_prompt_pkg_add(Symbol[:notapackage]) == false

        # don't offer to install the dummy "julia" entry that's in General
        @test REPLExt.try_prompt_pkg_add(Symbol[:julia]) == false

        withreply("n") do
            @test REPLExt.try_prompt_pkg_add(Symbol[:Example]) == false
        end
        withreply("y") do
            @test REPLExt.try_prompt_pkg_add(Symbol[:Example]) == true
        end
    end
end

@testset "JuliaLang/julia #55850" begin
    isolate(loaded_depot = true) do
        tmp = Base.DEPOT_PATH[1]
        copy_this_pkg_cache(tmp)
        tmp_sym_link = joinpath(tmp, "sym")
        symlink(tmp, tmp_sym_link; dir_target = true)
        depot_path = tmp_sym_link * (Sys.iswindows() ? ";" : ":")
        # include the symlink in the depot path and include the regular default depot so we don't precompile this Pkg again
        withenv("JULIA_DEPOT_PATH" => join(Base.DEPOT_PATH, Sys.iswindows() ? ";" : ":"), "JULIA_LOAD_PATH" => nothing) do
            prompt = readchomp(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) --startup-file=no -e "using Pkg, REPL; Pkg.activate(io=devnull); REPLExt = Base.get_extension(Pkg, :REPLExt); print(REPLExt.promptf())"`)
            @test prompt == "(@v$(VERSION.major).$(VERSION.minor)) pkg> "
        end
    end
end

@testset "in_repl_mode" begin
    # Test that in_repl_mode() returns false by default (API mode)
    @test Pkg.in_repl_mode() == false

    # Test that in_repl_mode() returns true when running REPL commands
    # This is tested indirectly by running a simple REPL command
    temp_pkg_dir() do project_path
        cd(project_path) do
            # The pkg"" macro should set IN_REPL_MODE => true during execution
            # We can't directly test the scoped value here, but we can test
            # that REPL commands work correctly
            pkg"status"
            # The fact that this doesn't error confirms REPL mode is working
            @test true
        end
    end

    # Test manual scoped value setting (for completeness)
    Base.ScopedValues.@with Pkg.IN_REPL_MODE => true begin
        @test Pkg.in_repl_mode() == true
    end

    # Verify we're back to false after the scoped block
    @test Pkg.in_repl_mode() == false
end

@testset "compat REPL mode" begin
    temp_pkg_dir() do project_path
        with_pkg_env(project_path; change_dir = true) do

            pkg"add Example JSON"

            test_ctx = Pkg.Types.Context()
            test_ctx.io = IOBuffer()

            @test Pkg.Operations.get_compat_str(test_ctx.env.project, "Example") === nothing
            @test Pkg.Operations.get_compat_str(test_ctx.env.project, "JSON") === nothing

            input_io = Base.BufferStream()
            # Send input to stdin before starting the _compat function
            # This simulates the user typing in the REPL
            write(input_io, "\e[B") # Down arrow once to select Example
            write(input_io, "\r") # Enter to confirm selection
            # now editing Example compat
            write(input_io, "0.4") # Set compat to 0.4
            write(input_io, "\r") # Enter to confirm input
            close(input_io)

            Pkg.API._compat(test_ctx; input_io)

            str = String(take!(test_ctx.io))
            @test occursin("Example = \"0.4\"", str)
            @test occursin("checking for compliance with the new compat rules..", str)
            @test occursin("Error empty intersection between", str) # Latest Example is at least 0.5.5

            # Test for issue #3828: Backspace on empty buffer should not cause BoundsError
            test_ctx = Pkg.Types.Context()
            test_ctx.io = IOBuffer()

            input_io = Base.BufferStream()
            write(input_io, "\r") # Select julia (first entry)
            # Now editing julia compat entry which starts empty
            write(input_io, "\x7f") # Backspace on empty buffer
            write(input_io, "\x7f") # Another backspace
            write(input_io, " ") # Space should not cause error
            write(input_io, "\r") # Confirm empty input
            close(input_io)

            # Should not throw BoundsError
            Pkg.API._compat(test_ctx; input_io)
        end
    end
end

end # module
