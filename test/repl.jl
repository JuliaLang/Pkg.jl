# This file is a part of Julia. License is MIT: https://julialang.org/license

module REPLTests
import ..Pkg # ensure we are using the correct Pkg

using Pkg
using Pkg.Types: manifest_info, EnvCache, Context
import Pkg.Types.PkgError
using UUIDs
using Test
import Markdown
using TOML
import LibGit2
import REPL
const REPLExt = Base.get_extension(Pkg, :REPLExt)

using ..Utils

# Most of the tests in this file check how REPL input lowers to API calls: with
# `Pkg.REPLMode.TEST_MODE[] = true`, `pkg"..."` returns a `(api, args, opts)`
# triple per command instead of running it. The behavior of the API functions
# themselves is covered by the other test files.

exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`

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
    isolate() do
        pkg"]?"
        pkg"] ?"
        pkg"]st"
        pkg"] st"
        pkg"]st -m"
        pkg"] st -m"
        pkg"]"  # noop
    end
end

#
# # Lowering of REPL commands to API calls
#

@testset "activate: REPL" begin
    isolate(loaded_depot = true) do
        Pkg.REPLMode.TEST_MODE[] = true
        # - activate shared env
        api, args, opts = first(Pkg.pkg"activate --shared Foo")
        @test api == Pkg.activate
        @test args == "Foo"
        @test opts == Dict(:shared => true)
        # - activate shared env using special syntax
        api, args, opts = first(Pkg.pkg"activate @Foo")
        @test api == Pkg.activate
        @test args == "Foo"
        @test opts == Dict(:shared => true)
        # - no arg activate
        api, opts = first(Pkg.pkg"activate")
        @test api == Pkg.activate
        @test isempty(opts)
        # - regular activate
        api, args, opts = first(Pkg.pkg"activate FooBar")
        @test api == Pkg.activate
        @test args == "FooBar"
        @test isempty(opts)
        # - activating a temporary project
        api, opts = first(Pkg.pkg"activate --temp")
        @test api == Pkg.activate
        @test opts == Dict(:temp => true)
        # - activating the previous project
        api, opts = first(Pkg.pkg"activate -")
        @test api == Pkg.activate
        @test opts == Dict(:prev => true)
    end
end

@testset "add: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        # Add using UUID syntax
        api, args, opts = first(Pkg.pkg"add 7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # Add using `name=UUID` syntax.
        api, args, opts = first(Pkg.pkg"add Example=7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example", uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # Add using git revision syntax.
        api, args, opts = first(Pkg.pkg"add Example#master")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example", rev = "master")]
        @test isempty(opts)
        # Add using git revision syntax.
        api, args, opt = first(Pkg.pkg"add Example#v0.5.3")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example", rev = "v0.5.3")]
        @test isempty(opts)
        # Add using registered version syntax.
        api, args, opts = first(Pkg.pkg"add Example@0.5.0")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example", version = "0.5.0")]
        @test isempty(opts)
        # Add multiple packages with version specifier
        api, args, opts = first(Pkg.pkg"add Example@0.5.5 Test")
        @test api == Pkg.add
        @test length(args) == 2
        @test args[1].name == "Example"
        @test args[1].version == "0.5.5"
        @test args[2].name == "Test"
        @test isempty(opts)
        # Comma separated packages, with and without whitespace
        for input in ("add Example, Random", "add Example,Random", "add Example Random")
            api, args, opts = first(Pkg.REPLMode.pkgstr(input))
            @test api == Pkg.add
            @test args == [Pkg.PackageSpec(; name = "Example"), Pkg.PackageSpec(; name = "Random")]
            @test isempty(opts)
        end
        # Leading whitespace (issue #4239)
        api, args, opts = first(Pkg.pkg"    add Example, Random")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example"), Pkg.PackageSpec(; name = "Random")]
        # Add as a weakdep.
        api, args, opts = first(Pkg.pkg"add --weak Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:target => :weakdeps)
        # Add as an extra.
        api, args, opts = first(Pkg.pkg"add --extra Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:target => :extras)
        # Add using direct URL syntax.
        api, args, opts = first(Pkg.pkg"add https://github.com/00vareladavid/Unregistered.jl#0.1.0")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; url = "https://github.com/00vareladavid/Unregistered.jl", rev = "0.1.0")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"add https://github.com/JuliaLang/Example.jl#master")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; url = "https://github.com/JuliaLang/Example.jl", rev = "master")]
        @test isempty(opts)

        api, args, opts = first(Pkg.pkg"add a/path/with/@/deal/with/it")
        @test normpath(args[1].path) == normpath("a/path/with/@/deal/with/it")

        # github branch rewriting
        api, args, opts = first(Pkg.pkg"add https://github.com/JuliaLang/Pkg.jl/tree/aa/gitlab")
        arg = args[1]
        @test arg.url == "https://github.com/JuliaLang/Pkg.jl"
        @test arg.rev == "aa/gitlab"

        api, args, opts = first(Pkg.pkg"add https://github.com/JuliaPy/PythonCall.jl/pull/529")
        arg = args[1]
        @test arg.url == "https://github.com/JuliaPy/PythonCall.jl"
        @test arg.rev == "pull/529/head"

        api, args, opts = first(Pkg.pkg"add https://github.com/TimG1964/XLSX.jl#Bug-fixing-post-#289:subdir")
        arg = args[1]
        @test arg.url == "https://github.com/TimG1964/XLSX.jl"
        @test arg.rev == "Bug-fixing-post-#289"
        @test arg.subdir == "subdir"

        # Test GitHub URLs with tree/commit paths
        @testset "GitHub tree/commit URLs" begin
            api, args, opts = first(Pkg.pkg"add https://github.com/user/repo/tree/feature-branch")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://github.com/user/repo"
            @test args[1].rev == "feature-branch"

            api, args, opts = first(Pkg.pkg"add https://github.com/user/repo/commit/abc123def")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://github.com/user/repo"
            @test args[1].rev == "abc123def"
        end

        # Test Git URLs with branch specifiers
        @testset "Git URLs with branch specifiers" begin
            api, args, opts = first(Pkg.pkg"add https://github.com/user/repo.git#main")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://github.com/user/repo.git"
            @test args[1].rev == "main"

            api, args, opts = first(Pkg.pkg"add https://bitbucket.org/user/repo.git#develop")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://bitbucket.org/user/repo.git"
            @test args[1].rev == "develop"

            api, args, opts = first(Pkg.pkg"add git@github.com:user/repo.git#feature")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "git@github.com:user/repo.git"
            @test args[1].rev == "feature"

            api, args, opts = first(Pkg.pkg"add ssh://git@server.com/path/repo.git#branch-name")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "ssh://git@server.com/path/repo.git"
            @test args[1].rev == "branch-name"
        end

        # Test SSH URLs with IP addresses (issue #1822)
        @testset "SSH URLs with IP addresses" begin
            # Test that user@host:path URLs with IP addresses are parsed correctly as complete URLs
            api, args, opts = first(Pkg.pkg"add user@10.20.30.40:PackageName.jl")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "user@10.20.30.40:PackageName.jl"
            @test args[1].subdir === nothing

            api, args, opts = first(Pkg.pkg"add git@192.168.1.100:path/to/repo.jl")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "git@192.168.1.100:path/to/repo.jl"
            @test args[1].subdir === nothing
        end

        # Test Git URLs with subdir specifiers
        @testset "Git URLs with subdir specifiers" begin
            api, args, opts = first(Pkg.pkg"add https://github.com/user/monorepo.git:packages/MyPackage")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://github.com/user/monorepo.git"
            @test args[1].subdir == "packages/MyPackage"

            api, args, opts = first(Pkg.pkg"add ssh://git@server.com/repo.git:subdir/nested")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "ssh://git@server.com/repo.git"
            @test args[1].subdir == "subdir/nested"
        end

        # Test complex URLs (with username in URL + branch/tag/subdir)
        @testset "Complex Git URLs" begin
            api, args, opts = first(Pkg.pkg"add https://username@bitbucket.org/org/repo.git#dev")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://username@bitbucket.org/org/repo.git"
            @test args[1].rev == "dev"

            api, args, opts = first(Pkg.pkg"add https://user:token@gitlab.company.com/group/project.git")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://user:token@gitlab.company.com/group/project.git"

            api, args, opts = first(Pkg.pkg"add https://example.com:8080/git/repo.git:packages/core")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://example.com:8080/git/repo.git"
            @test args[1].subdir == "packages/core"

            # Test URLs with complex authentication and branch names containing #
            api, args, opts = first(Pkg.pkg"add https://user:pass123@gitlab.example.com:8443/group/project.git#feature/fix-#42")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://user:pass123@gitlab.example.com:8443/group/project.git"
            @test args[1].rev == "feature/fix-#42"

            # Test URLs with complex authentication and subdirs
            api, args, opts = first(Pkg.pkg"add https://api_key:secret@company.git.server.com/team/monorepo.git:libs/julia/pkg")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://api_key:secret@company.git.server.com/team/monorepo.git"
            @test args[1].subdir == "libs/julia/pkg"

            # Test URLs with authentication, branch with #, and subdir
            api, args, opts = first(Pkg.pkg"add https://deploy:token123@internal.git.company.com/product/backend.git#hotfix/issue-#789:packages/core")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://deploy:token123@internal.git.company.com/product/backend.git"
            @test args[1].rev == "hotfix/issue-#789"
            @test args[1].subdir == "packages/core"

            # Test SSH URLs with port numbers and subdirs
            api, args, opts = first(Pkg.pkg"add ssh://git@custom.server.com:2222/path/to/repo.git:src/package")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "ssh://git@custom.server.com:2222/path/to/repo.git"
            @test args[1].subdir == "src/package"

            # Test URL with username in URL and multiple # in branch name
            api, args, opts = first(Pkg.pkg"add https://ci_user@build.company.net/team/project.git#release/v2.0-#123-#456")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://ci_user@build.company.net/team/project.git"
            @test args[1].rev == "release/v2.0-#123-#456"

            # Test complex case: auth + port + branch with # + subdir
            api, args, opts = first(Pkg.pkg"add https://robot:abc123@git.enterprise.com:9443/division/platform.git#bugfix/handle-#special-chars:modules/julia-pkg")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://robot:abc123@git.enterprise.com:9443/division/platform.git"
            @test args[1].rev == "bugfix/handle-#special-chars"
            @test args[1].subdir == "modules/julia-pkg"

            # Test local paths with branch specifiers (paths can be repos)
            api, args, opts = first(Pkg.pkg"add ./local/repo#feature-branch")
            @test api == Pkg.add
            @test length(args) == 1
            @test normpath(args[1].path) == normpath("local/repo")  # normpath removes "./"
            @test args[1].rev == "feature-branch"

            # Test local paths with subdir specifiers
            api, args, opts = first(Pkg.pkg"add ./monorepo:packages/subpkg")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].path == "monorepo"  # normpath removes "./"
            @test args[1].subdir == "packages/subpkg"

            # Test local paths with both branch and subdir
            api, args, opts = first(Pkg.pkg"add ./project#develop:src/package")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].path == "project"  # normpath removes "./"
            @test args[1].rev == "develop"
            @test args[1].subdir == "src/package"

            # Test local paths with branch containing # characters
            api, args, opts = first(Pkg.pkg"add ../workspace/repo#bugfix/issue-#123")
            @test api == Pkg.add
            @test length(args) == 1
            @test normpath(args[1].path) == normpath("../workspace/repo")
            @test args[1].rev == "bugfix/issue-#123"

            # Test complex local path case: relative path + branch with # + subdir
            if !Sys.iswindows()
                api, args, opts = first(Pkg.pkg"add ~/projects/myrepo#feature/fix-#456:libs/core")
                @test api == Pkg.add
                @test length(args) == 1
                @test startswith(args[1].path, "/")  # ~ gets expanded to absolute path
                @test endswith(normpath(args[1].path), normpath("/projects/myrepo"))
                @test args[1].rev == "feature/fix-#456"
                @test args[1].subdir == "libs/core"
            end

            # Test quoted URL with separate revision specifier (regression test)
            api, args, opts = first(Pkg.pkg"add \"https://username@bitbucket.org/orgname/reponame.git\"#dev")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://username@bitbucket.org/orgname/reponame.git"
            @test args[1].rev == "dev"

            # Test quoted URL with separate version specifier
            api, args, opts = first(Pkg.pkg"add \"https://company.git.server.com/project.git\"@v2.1.0")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://company.git.server.com/project.git"
            @test args[1].version == "v2.1.0"

            # Test quoted URL with separate subdir specifier
            api, args, opts = first(Pkg.pkg"add \"https://gitlab.example.com/monorepo.git\":packages/core")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://gitlab.example.com/monorepo.git"
            @test args[1].subdir == "packages/core"
        end

        # Test that regular URLs without .git still work
        @testset "Non-.git URLs (unchanged behavior)" begin
            api, args, opts = first(Pkg.pkg"add https://github.com/user/repo")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].url == "https://github.com/user/repo"
            @test args[1].rev === nothing
            @test args[1].subdir === nothing
        end

        @testset "Windows path handling" begin
            # Test that Windows drive letters are not treated as subdir separators
            api, args, opts = first(Pkg.pkg"add C:\\Users\\test\\project")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].path == normpath("C:\\\\Users\\\\test\\\\project")
            @test args[1].subdir === nothing

            # Test with forward slashes too
            api, args, opts = first(Pkg.pkg"add C:/Users/test/project")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].path == normpath("C:/Users/test/project")
            @test args[1].subdir === nothing

            # Test that actual subdir syntax still works with Windows paths
            api, args, opts = first(Pkg.pkg"add C:\\Users\\test\\project:subdir")
            @test api == Pkg.add
            @test length(args) == 1
            @test args[1].path == normpath("C:\\\\Users\\\\test\\\\project")
            @test args[1].subdir == "subdir"
        end

        # Add using preserve option
        api, args, opts = first(Pkg.pkg"add --preserve=none Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_NONE)
        api, args, opts = first(Pkg.pkg"add --preserve=semver Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_SEMVER)
        api, args, opts = first(Pkg.pkg"add --preserve=tiered Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_TIERED)
        api, args, opts = first(Pkg.pkg"add --preserve=all Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_ALL)
        api, args, opts = first(Pkg.pkg"add --preserve=direct Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_DIRECT)
    end
    # check casesensitive resolution of paths
    isolate() do;
        cd_tempdir() do dir
            Pkg.REPLMode.TEST_MODE[] = true
            mkdir("example")
            api, args, opts = first(Pkg.pkg"add Example")
            @test api == Pkg.add
            @test args == [Pkg.PackageSpec(; name = "Example")]
            @test isempty(opts)
            api, args, opts = first(Pkg.pkg"add example")
            @test api == Pkg.add
            @test args == [Pkg.PackageSpec(; name = "example")]
            @test isempty(opts)
            api, args, opts = first(Pkg.pkg"add ./example")
            @test api == Pkg.add
            @test args == [Pkg.PackageSpec(; path = "example")]
            @test isempty(opts)
            cd("example")
            api, args, opts = first(Pkg.pkg"add .")
            @test api == Pkg.add
            @test args == [Pkg.PackageSpec(; path = ".")]
            @test isempty(opts)
        end
    end
    isolate() do;
        cd_tempdir() do dir
            # adding a nonexistent directory
            @test_throws PkgError(
                "Path `$(abspath("some/really/random/Dir"))` does not exist."
            ) Pkg.pkg"add some/really/random/Dir"
            # warn if not explicit about adding directory
            mkdir("Example")
            @test_logs (:info, r"Use `./Example` to add or develop the local directory at `.*`.") match_mode = :any Pkg.pkg"add Example"
        end
    end
    # quoted local paths
    isolate() do;
        cd_tempdir() do dir
            Pkg.REPLMode.TEST_MODE[] = true
            # directory names with spaces and other significant characters
            for (parent, name) in (("space dir", "WeirdName77"), ("some@d;ir#", "WeirdName77"))
                mkpath(joinpath(parent, name))
                api, args, opts = first(Pkg.REPLMode.pkgstr("add \"$parent/$name\""))
                @test api == Pkg.add
                @test args == [Pkg.PackageSpec(; path = normpath("$parent/$name"))]
                @test isempty(opts)
            end
            dir1, name1 = "two space dir", "name1"
            dir2, name2 = "two'quote'dir", "name2"
            mkpath(joinpath(dir1, name1))
            mkpath(joinpath(dir2, name2))
            api, args, opts = first(Pkg.REPLMode.pkgstr("add '$dir1/$name1' \"$dir2/$name2\""))
            @test api == Pkg.add
            @test args == [Pkg.PackageSpec(; path = normpath("$dir1/$name1")), Pkg.PackageSpec(; path = normpath("$dir2/$name2"))]
            @test isempty(opts)
        end
    end
end

@testset "develop: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        # registered name
        api, args, opts = first(Pkg.pkg"develop Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        # registered uuid
        api, args, opts = first(Pkg.pkg"develop 7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # name=uuid
        api, args, opts = first(Pkg.pkg"develop Example=7876af07-990d-54b4-ab0e-23690620f79a")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; name = "Example", uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))]
        @test isempty(opts)
        # multiple packages, comma or space separated
        for input in ("develop Example,JSON", "develop Example JSON", "dev Example, JSON")
            api, args, opts = first(Pkg.REPLMode.pkgstr(input))
            @test api == Pkg.develop
            @test args == [Pkg.PackageSpec(; name = "Example"), Pkg.PackageSpec(; name = "JSON")]
            @test isempty(opts)
        end
        # local flag
        api, args, opts = first(Pkg.pkg"develop --local Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:shared => false)
        # shared flag
        api, args, opts = first(Pkg.pkg"develop --shared Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:shared => true)
        # URL
        api, args, opts = first(Pkg.pkg"develop https://github.com/JuliaLang/Example.jl")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; url = "https://github.com/JuliaLang/Example.jl")]
        @test isempty(opts)
        # develop using preserve option
        api, args, opts = first(Pkg.pkg"dev --preserve=none Example")
        @test api == Pkg.develop
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:preserve => Pkg.PRESERVE_NONE)
    end
end

@testset "instantiate: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"instantiate")
        @test api == Pkg.instantiate
        @test isempty(opts)
        api, opts = first(Pkg.pkg"instantiate --verbose")
        @test api == Pkg.instantiate
        @test opts == Dict(:verbose => true)
        api, opts = first(Pkg.pkg"instantiate -v")
        @test api == Pkg.instantiate
        @test opts == Dict(:verbose => true)
    end
end

@testset "why: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"why Foo")
        @test api == Pkg.why
        @test first(opts).name == "Foo"
        @test_throws PkgError Pkg.pkg"why Foo Bar"
    end
end

@testset "update: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"up")
        @test api == Pkg.update
        @test isempty(args)
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"update Example")
        @test api == Pkg.update
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"up --fixed")
        @test api == Pkg.update
        @test isempty(args)
        @test opts == Dict(:level => Pkg.UPLEVEL_FIXED)
        api, args, opts = first(Pkg.pkg"up --patch")
        @test opts == Dict(:level => Pkg.UPLEVEL_PATCH)
        api, args, opts = first(Pkg.pkg"up --minor")
        @test opts == Dict(:level => Pkg.UPLEVEL_MINOR)
        api, args, opts = first(Pkg.pkg"up --major")
        @test opts == Dict(:level => Pkg.UPLEVEL_MAJOR)
        api, args, opts = first(Pkg.pkg"up --manifest Example")
        @test opts == Dict(:mode => Pkg.PKGMODE_MANIFEST)
    end
end

@testset "pin: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"pin Example")
        @test api == Pkg.pin
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"pin Example@0.5.0")
        @test api == Pkg.pin
        @test args == [Pkg.PackageSpec(; name = "Example", version = "0.5.0")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"pin --all")
        @test api == Pkg.pin
        @test isempty(args)
        @test opts == Dict(:all_pkgs => true)
    end
end

@testset "free: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"free Example")
        @test api == Pkg.free
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"free --all")
        @test api == Pkg.free
        @test isempty(args)
        @test opts == Dict(:all_pkgs => true)
    end
end

@testset "rm: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"rm Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"rm --project Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:mode => Pkg.PKGMODE_PROJECT)
        api, args, opts = first(Pkg.pkg"rm --manifest Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:mode => Pkg.PKGMODE_MANIFEST)
        api, args, opts = first(Pkg.pkg"rm --all")
        @test api == Pkg.rm
        @test isempty(args)
        @test opts == Dict(:all_pkgs => true)
        # multiple packages, quoted names, and the `remove` alias
        for input in ("rm Example Random", "rm Example,Random", "remove \"Example\" 'Random'", "remove 'Example' Random")
            api, args, opts = first(Pkg.REPLMode.pkgstr(input))
            @test api == Pkg.rm
            @test args == [Pkg.PackageSpec(; name = "Example"), Pkg.PackageSpec(; name = "Random")]
            @test isempty(opts)
        end
    end
end

@testset "test: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"test")
        @test api == Pkg.test
        @test isempty(args)
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"test Example")
        @test api == Pkg.test
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"test --coverage Example")
        @test api == Pkg.test
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:coverage => true)
        @test_throws PkgError Pkg.pkg"test --project Example"
    end
end

@testset "build: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, args, opts = first(Pkg.pkg"build")
        @test api == Pkg.build
        @test isempty(args)
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"build Example")
        @test api == Pkg.build
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"build --verbose")
        @test api == Pkg.build
        @test isempty(args)
        @test opts == Dict(:verbose => true)
        api, args, opts = first(Pkg.pkg"build -v Foo Bar")
        @test api == Pkg.build
        @test args == [Pkg.PackageSpec(; name = "Foo"), Pkg.PackageSpec(; name = "Bar")]
        @test opts == Dict(:verbose => true)
    end
end

@testset "gc: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, opts = first(Pkg.pkg"gc")
        @test api == Pkg.gc
        @test isempty(opts)
        api, opts = first(Pkg.pkg"gc --all")
        @test api == Pkg.gc
        # N.B.: `--all` is now a no-op, but is retained for now for compatibility.
    end
end

@testset "precompile: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true

        api, opts = first(Pkg.pkg"precompile")
        @test api == Pkg.precompile
        @test isempty(opts)

        api, arg, opts = first(Pkg.pkg"precompile Foo")
        @test api == Pkg.precompile
        @test arg == ["Foo"]
        @test isempty(opts)

        api, arg, opts = first(Pkg.pkg"precompile Foo Bar")
        @test api == Pkg.precompile
        @test arg == ["Foo", "Bar"]
        @test isempty(opts)

        api, arg, opts = first(Pkg.pkg"precompile Foo, Bar")
        @test api == Pkg.precompile
        @test arg == ["Foo", "Bar"]
        @test isempty(opts)
    end
end

@testset "generate: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        api, arg, opts = first(Pkg.pkg"generate Foo")
        @test api == Pkg.API.generate
        @test arg == "Foo"
        @test isempty(opts)
        mktempdir() do dir
            api, arg, opts = first(Pkg.REPLMode.pkgstr("generate $(joinpath(dir, "Foo"))"))
            @test arg == joinpath(dir, "Foo")
            # issue #1435
            if !Sys.iswindows()
                withenv("HOME" => dir) do
                    api, arg, opts = first(Pkg.REPLMode.pkgstr("generate ~/Bar"))
                    @test arg == joinpath(dir, "Bar")
                end
            end
        end
    end
end

@testset "status: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        for input in ("status", "st")
            api, args, opts = first(Pkg.REPLMode.pkgstr(input))
            @test api == Pkg.status
            @test isempty(args)
            @test isempty(opts)
        end
        api, args, opts = first(Pkg.pkg"status -m")
        @test api == Pkg.status
        @test isempty(args)
        @test opts == Dict(:mode => Pkg.PKGMODE_MANIFEST)
        api, args, opts = first(Pkg.pkg"status --project")
        @test opts == Dict(:mode => Pkg.PKGMODE_PROJECT)
        api, args, opts = first(Pkg.pkg"status Example")
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test isempty(opts)
        api, args, opts = first(Pkg.pkg"status Example=7876af07-990d-54b4-ab0e-23690620f79a")
        @test args == [Pkg.PackageSpec(; name = "Example", uuid = exuuid)]
        api, args, opts = first(Pkg.pkg"status 7876af07-990d-54b4-ab0e-23690620f79a")
        @test args == [Pkg.PackageSpec(; uuid = exuuid)]
        for input in ("status Example Random", "status Example, Random")
            api, args, opts = first(Pkg.REPLMode.pkgstr(input))
            @test args == [Pkg.PackageSpec(; name = "Example"), Pkg.PackageSpec(; name = "Random")]
        end
        api, args, opts = first(Pkg.pkg"status -m Example")
        @test args == [Pkg.PackageSpec(; name = "Example")]
        @test opts == Dict(:mode => Pkg.PKGMODE_MANIFEST)
        api, args, opts = first(Pkg.pkg"status --outdated")
        @test opts == Dict(:outdated => true)
        api, args, opts = first(Pkg.pkg"status --compat")
        @test opts == Dict(:compat => true)
        for input in ("status --diff", "status -d")
            api, args, opts = first(Pkg.REPLMode.pkgstr(input))
            @test opts == Dict(:diff => true)
        end
    end
end

@testset "compound input: REPL" begin
    isolate() do
        Pkg.REPLMode.TEST_MODE[] = true
        # `package` is the (implicit) command prefix for the package commands
        api, args, opts = first(Pkg.REPLMode.pkg"package add Example")
        @test api == Pkg.add
        @test args == [Pkg.PackageSpec(; name = "Example")]
        api, args, opts = first(Pkg.REPLMode.pkg"package rm Example")
        @test api == Pkg.rm
        @test args == [Pkg.PackageSpec(; name = "Example")]
        # `;` separated commands
        cmds = Pkg.pkg"build; precompile"
        @test length(cmds) == 2
        @test cmds[1][1] == Pkg.build
        @test cmds[2][1] == Pkg.precompile
        # multiline input
        cmds = Pkg.pkg"""
            test SubModule
            test SubModule2
            test BigProject
            test
        """
        @test length(cmds) == 4
        @test all(cmd -> cmd[1] == Pkg.test, cmds)
        @test [cmd[2] for cmd in cmds] == [
            [Pkg.PackageSpec(; name = "SubModule")],
            [Pkg.PackageSpec(; name = "SubModule2")],
            [Pkg.PackageSpec(; name = "BigProject")],
            [],
        ]
    end
end

@testset "REPL error handling" begin
    isolate() do
        # PackageSpec tokens
        @test_throws PkgError Pkg.pkg"add FooBar Example#foobar#foobar"
        @test_throws PkgError Pkg.pkg"up Example#foobar@0.0.0"
        @test_throws PkgError Pkg.pkg"pin Example@0.0.0@0.0.1"
        @test_throws PkgError Pkg.pkg"up #foobar"
        @test_throws PkgError Pkg.pkg"add @0.0.1"
        @test_throws PkgError Pkg.pkg"add JSON Example#foobar#foobar LazyJSON"
        # Argument count
        @test_throws PkgError Pkg.pkg"activate one two"
        @test_throws PkgError Pkg.pkg"activate one two three"
        # invalid options
        @test_throws PkgError Pkg.pkg"rm --minor Example"
        @test_throws PkgError Pkg.pkg"pin --project Example"
        # conflicting options
        @test_throws PkgError Pkg.pkg"up --major --minor"
        @test_throws PkgError Pkg.pkg"rm --project --manifest"
    end
end

#
# # Executing REPL commands
#

@testset "dev error paths" begin
    temp_pkg_dir() do project_path
        with_pkg_env(project_path; change_dir = true) do;
            pkg"generate HelloWorld"
            LibGit2.close((LibGit2.init(".")))
            cd("HelloWorld")

            @test_throws PkgError pkg"dev Example#blergh"

            @test_throws PkgError pkg"add ÖÖÖ"

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
end

# Smoke test that lowered commands are accepted by the API functions
@testset "executing lowered commands" begin
    temp_pkg_dir() do project_path
        cd(project_path) do;
            tmp_pkg_path = mktempdir()

            pkg"activate ."
            pkg"add Example@0.5.3"
            @test isinstalled(TEST_PKG)
            @test Pkg.dependencies()[TEST_PKG.uuid].version == v"0.5.3"
            pkg"rm Example"
            pkg"add Example, Random"
            pkg"rm Example Random"
            pkg"add https://github.com/JuliaLang/Example.jl#master"

            # Test upgrade --fixed doesn't change the tracking (https://github.com/JuliaLang/Pkg.jl/issues/434)
            entry = Pkg.Types.manifest_info(EnvCache().manifest, TEST_PKG.uuid)
            @test entry.repo.rev == "master"
            pkg"up --fixed"
            entry = Pkg.Types.manifest_info(EnvCache().manifest, TEST_PKG.uuid)
            @test entry.repo.rev == "master"

            pkg2 = "UnregisteredWithProject"
            pkg2_uuid = UUID("58262bb0-2073-11e8-3727-4fe182c12249")
            p2 = git_init_package(tmp_pkg_path, joinpath(@__DIR__, "test_packages/$pkg2"))
            Pkg.REPLMode.pkgstr("add $p2")
            Pkg.REPLMode.pkgstr("pin $pkg2")
            @test Pkg.dependencies()[pkg2_uuid].version == v"0.1.0"
            Pkg.REPLMode.pkgstr("free $pkg2")
            @test_throws PkgError Pkg.REPLMode.pkgstr("free $pkg2")

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
                Pkg.REPLMode.pkgstr("add $p2#$c")
                @test Pkg.dependencies()[pkg2_uuid].git_revision == string(c)
            end
        end # cd
    end # temp_pkg_dir
end

# issue #904: Pkg.status within a git repo
@testset "status within a git repo (#904)" begin
    temp_pkg_dir() do path
        pkg2 = "UnregisteredWithProject"
        p2 = git_init_package(path, joinpath(@__DIR__, "test_packages/$pkg2"))
        Pkg.activate(p2)
        Pkg.status() # should not throw
        Pkg.REPLMode.pkgstr("status") # should not throw
    end
end

@testset "develop, build and relative paths" begin
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
end

# activate
@testset "activate paths" begin
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
end

# path should not be relative when devdir() happens to be in project
# unless user used dev --local.
@testset "dev path relative to project" begin
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
end

test_complete(s) = REPLExt.completions(s, lastindex(s))
apply_completion(str) = begin
    c, r, s = test_complete(str)
    str[1:prevind(str, first(r))] * first(c)
end

# Autocompletions
@testset "tab completion while offline" begin
    temp_pkg_dir(; linked_reg = false) do project_path # starts without registries
        cd(project_path) do
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

@testset "tab completion" begin
    temp_pkg_dir() do project_path
        cd(project_path) do
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
            @test Sys.iswindows() ? ("testdir\\" in c) : ("testdir/" in c)
            @test apply_completion("add tes") == (Sys.iswindows() ? "add testdir\\" : "add testdir/")
            @test apply_completion("add ./tes") == (Sys.iswindows() ? "add ./testdir\\" : "add ./testdir/")
            c, r = test_complete("dev ./")
            @test (Sys.iswindows() ? ("testdir\\" in c) : ("testdir/" in c))

            # complete subdirs
            c, r = test_complete("add testdir/f")
            @test Sys.iswindows() ? ("foo\\" in c) : ("foo/" in c)
            @test apply_completion("add testdir/f") == (Sys.iswindows() ? "add testdir/foo\\" : "add testdir/foo/")
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
        end
    end
end

@testset "BigProject" begin
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
end

@testset "parse package url win" begin
    pkg_id = Pkg.REPLMode.PackageIdentifier("https://github.com/abc/ABC.jl")
    pkg_spec = Pkg.REPLMode.parse_package_identifier(pkg_id; add_or_develop = true)
    @test typeof(pkg_spec) == Pkg.Types.PackageSpec
end

@testset "unit test for REPLMode.promptf" begin
    function set_name(projfile_path, newname)
        project = TOML.parsefile(projfile_path)
        project["name"] = newname
        open(projfile_path, "w") do io
            TOML.print(io, project)
        end
    end

    # `promptf` caches its result; invalidate before each call so the test
    # exercises a fresh computation.
    fresh_prompt() = (REPLExt.invalidate_prompt!(); REPLExt.promptf())

    with_temp_env("SomeEnv") do
        @test fresh_prompt() == "(SomeEnv) pkg> "
    end

    with_temp_env("this_is_a_test_for_truncating_long_folder_names_in_the_prompt") do
        @test fresh_prompt() == "(this_is_a_test_for_truncati...) pkg> "
    end

    env_name = "Test2"
    with_temp_env(env_name) do env_path
        projfile_path = joinpath(env_path, "Project.toml")
        @test fresh_prompt() == "($env_name) pkg> "

        newname = "NewName"
        set_name(projfile_path, newname)
        @test fresh_prompt() == "($newname) pkg> "
        cd(env_path) do
            @test fresh_prompt() == "($newname) pkg> "
        end
        @test fresh_prompt() == "($newname) pkg> "

        newname = "NewNameII"
        set_name(projfile_path, newname)
        cd(env_path) do
            @test fresh_prompt() == "($newname) pkg> "
        end
        @test fresh_prompt() == "($newname) pkg> "
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
        # `promptf` is covered in-process; without `--code-coverage=none` the
        # subprocess would have to compile Pkg from scratch when run with coverage
        prompt = readchomp(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) --startup-file=no --code-coverage=none -e "using Pkg, REPL; Pkg.activate(io=devnull); REPLExt = Base.get_extension(Pkg, :REPLExt); print(REPLExt.promptf())"`)
        @test prompt == "(@v$(VERSION.major).$(VERSION.minor)) pkg> "
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

@testset "REPL command doc generation" begin
    # test that the way doc building extracts
    # docstrings for Pkg REPL commands work
    d = Dict(Pkg.REPLMode.canonical_names())
    @test d["add"].help isa Markdown.MD
    @test d["registry add"].help isa Markdown.MD
end

end # module
