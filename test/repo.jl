module RepoTests

using Test, UUIDs
import ..Pkg
using Pkg.Types: PkgError
using ..Utils

# Note: these tests should be run on clean depots
for v in (nothing, "true")
    # On CI when JULIA_PKG_USE_CLI_GIT=true we need to tell the cli git to not prompt for credentials
    # GIT_ASKPASS=true forces the credential provider to return "" https://stackoverflow.com/a/71057440
    # GIT_TERMINAL_PROMPT=0 is also supposed to avoid the prompt but doesn't reliably https://github.com/JuliaLang/Pkg.jl/issues/3774
    withenv("JULIA_PKG_USE_CLI_GIT" => v, "GIT_TERMINAL_PROMPT" => 0, "GIT_ASKPASS" => "true") do
        @testset "downloads with JULIA_PKG_USE_CLI_GIT = $v" begin
            isolate() do
                @testset "via name" begin
                    Pkg.add(TEST_PKG.name; use_git_for_all_downloads = true)
                    @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
                    @eval import $(Symbol(TEST_PKG.name))
                    @test_throws SystemError open(pathof(eval(Symbol(TEST_PKG.name))), "w") do io end  # check read-only
                    Pkg.rm(TEST_PKG.name)
                end
                if (Base.get_bool_env("JULIA_PKG_USE_CLI_GIT", false) == false) && !Sys.iswindows()
                    # TODO: fix. On GH windows runners cli git will prompt for credentials and hang.
                    # On other runners git cli is noisy when an url is given.
                    @testset "via url" begin
                        Pkg.add(url = "https://github.com/JuliaLang/Example.jl", use_git_for_all_downloads = true)
                        @test haskey(Pkg.dependencies(), TEST_PKG.uuid)
                        Pkg.rm(TEST_PKG.name)
                    end
                    @testset "failures" begin
                        doesnotexist = "https://github.com/DoesNotExist/DoesNotExist.jl"
                        @test_throws Pkg.Types.PkgError Pkg.add(url = doesnotexist, use_git_for_all_downloads = true)
                        @test_throws Pkg.Types.PkgError Pkg.Registry.add(url = doesnotexist)
                    end
                end
                @testset "tarball downloads" begin
                    Pkg.add("JSON"; use_only_tarballs_for_downloads = true)
                    @test "JSON" in [pkg.name for (uuid, pkg) in Pkg.dependencies()]
                    Pkg.rm("JSON")
                end
            end
        end
    end
end

tree_hash(root::AbstractString; kwargs...) = bytes2hex(@inferred Pkg.GitTools.tree_hash(root; kwargs...))

@testset "git tree hash computation" begin
    mktempdir() do dir
        # test "well known" empty tree hash
        @test "4b825dc642cb6eb9a060e54bf8d69288fbee4904" == tree_hash(dir)
        # create a text file
        file = joinpath(dir, "hello.txt")
        open(file, write = true) do io
            println(io, "Hello, world.")
        end
        chmod(file, 0o644)
        # reference hash generated with command-line git
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == tree_hash(dir)
        # test with various executable bits set
        chmod(file, 0o645) # other x bit doesn't matter
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == tree_hash(dir)
        chmod(file, 0o654) # group x bit doesn't matter
        @test "0a890bd10328d68f6d85efd2535e3a4c588ee8e6" == tree_hash(dir)
        chmod(file, 0o744) # user x bit matters
        @test "952cfce0fb589c02736482fa75f9f9bb492242f8" == tree_hash(dir)
    end

    # Test for empty directory hashing
    mktempdir() do dir
        @test "4b825dc642cb6eb9a060e54bf8d69288fbee4904" == tree_hash(dir)

        # Directories containing other empty directories are also empty
        mkdir(joinpath(dir, "foo"))
        mkdir(joinpath(dir, "foo", "bar"))
        @test "4b825dc642cb6eb9a060e54bf8d69288fbee4904" == tree_hash(dir)

        # Directories containing symlinks (even if they point to other directories)
        # are NOT empty:
        if !Sys.iswindows()
            symlink("bar", joinpath(dir, "foo", "bar_link"))
            @test "8bc80be82b2ae4bd69f50a1a077a81b8678c9024" == tree_hash(dir)
        end
    end

    # Test for directory with .git hashing
    mktempdir() do dir
        mkdir(joinpath(dir, "Foo"))
        mkdir(joinpath(dir, "FooGit"))
        mkdir(joinpath(dir, "FooGit", ".git"))
        write(joinpath(dir, "Foo", "foo"), "foo")
        chmod(joinpath(dir, "Foo", "foo"), 0o644)
        write(joinpath(dir, "FooGit", "foo"), "foo")
        chmod(joinpath(dir, "FooGit", "foo"), 0o644)
        write(joinpath(dir, "FooGit", ".git", "foo"), "foo")
        chmod(joinpath(dir, "FooGit", ".git", "foo"), 0o644)
        @test tree_hash(joinpath(dir, "Foo")) ==
            tree_hash(joinpath(dir, "FooGit")) ==
            "2f42e2c1c1afd4ef8c66a2aaba5d5e1baddcab33"
    end

    # Test for symlinks that are a prefix of another directory, causing sorting issues
    if !Sys.iswindows()
        mktempdir() do dir
            mkdir(joinpath(dir, "5.28.1"))
            write(joinpath(dir, "5.28.1", "foo"), "")
            chmod(joinpath(dir, "5.28.1", "foo"), 0o644)
            symlink("5.28.1", joinpath(dir, "5.28"))

            @test tree_hash(dir) == "5e50a4254773a7c689bebca79e2954630cab9c04"
        end
    end
end

@testset "relative depot path" begin
    isolate(loaded_depot = false) do
        mktempdir() do tmp
            withenv("JULIA_DEPOT_PATH" => tmp * (Sys.iswindows() ? ";" : ":")) do
                Base.init_depot_path()
                cp(joinpath(@__DIR__, "test_packages", "BasicSandbox"), joinpath(tmp, "BasicSandbox"))
                git_init_and_commit(joinpath(tmp, "BasicSandbox"))
                cd(tmp) do
                    Pkg.add(path = "BasicSandbox")
                end
            end
        end
    end
end

end # module
