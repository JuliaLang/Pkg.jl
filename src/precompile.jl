using LibGit2: LibGit2
using Tar: Tar
using Downloads

let
function _run_precompilation_script_setup()
    tmp = mktempdir()
    cd(tmp)
    empty!(DEPOT_PATH)
    pushfirst!(DEPOT_PATH, tmp)
    pushfirst!(LOAD_PATH, "@")
    write("Project.toml", 
        """
        name = "Hello"
        uuid = "33cfe95a-1eb2-52ea-b672-e2afdf69b78f"
        """
    ) 
    mkdir("src")
    write("src/Hello.jl", 
        """
        module Hello
        end
        """
    )
    Pkg.activate(".")
    Pkg.generate("TestPkg")
    uuid = TOML.parsefile(joinpath("TestPkg", "Project.toml"))["uuid"]
    mv("TestPkg", "TestPkg.jl")
    tree_hash = cd("TestPkg.jl") do
        sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time()), 0)
        repo = LibGit2.init(".")
        LibGit2.add!(repo, "")
        commit = LibGit2.commit(repo, "initial commit"; author=sig, committer=sig)
        th = LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(repo, commit)) |> LibGit2.GitHash |> string
        close(repo)
        th
    end
    # Prevent cloning the General registry by adding a fake one
    mkpath("registries/Registry/T/TestPkg")
    write("registries/Registry/Registry.toml", """
        name = "Registry"
        uuid = "37c07fec-e54c-4851-934c-2e3885e4053e"
        repo = "https://github.com/JuliaRegistries/Registry.git"
        [packages]
        $uuid = { name = "TestPkg", path = "T/TestPkg" }
        """)
    write("registries/Registry/T/TestPkg/Compat.toml", """
          ["0"]
          julia = "1"
          """)
    write("registries/Registry/T/TestPkg/Deps.toml", """
          ["0"]
          Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
          """)
    write("registries/Registry/T/TestPkg/Versions.toml", """
          ["0.1.0"]
          git-tree-sha1 = "$tree_hash"
          """)
    write("registries/Registry/T/TestPkg/Package.toml", """
        name = "TestPkg"
        uuid = "$uuid"
        repo = "$(escape_string(tmp))/TestPkg.jl"
        """)
    Tar.create("registries/Registry", "registries/Registry.tar")
    cmd = `$(Pkg.PlatformEngines.exe7z()) a "registries/Registry.tar.gz" -tgzip "registries/Registry.tar"`
    run(pipeline(cmd, stdout = stdout_f(), stderr = stderr_f()))
    write("registries/Registry.toml", """
          git-tree-sha1 = "11b5fad51c4f98cfe0c145ceab0b8fb63fed6f81"
          uuid = "37c07fec-e54c-4851-934c-2e3885e4053e"
          path = "Registry.tar.gz"
    """)
    Base.rm("registries/Registry"; recursive=true)
    return tmp
end

# SnoopPrecompile is useful but not available in Base
# using SnoopPrecompile
function pkg_precompile()
    Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
    # Default 30 sec grace period means we hang 30 seconds before precompiling finishes
    Downloads.DOWNLOADER[] = Downloads.Downloader(; grace=1.0)
    # @precompile_setup begin
        tmp = _run_precompilation_script_setup()
        # @precompile_all_calls begin
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do 
                Pkg.add("TestPkg")
                Pkg.develop(Pkg.PackageSpec(path="TestPkg.jl"))
                Pkg.add(Pkg.PackageSpec(path="TestPkg.jl/"))
                Pkg.REPLMode.try_prompt_pkg_add(Symbol[:notapackage])
                Pkg.update(; update_registry=false)
                Pkg.status()
            end
            Pkg.precompile()    
            Base.rm(tmp; recursive=true)

            Base.precompile(Tuple{typeof(Pkg.REPLMode.promptf)})
            Base.precompile(Tuple{typeof(Pkg.REPLMode.repl_init), REPL.LineEditREPL})
            Base.precompile(Tuple{typeof(Pkg.API.status)})
            Base.precompile(Tuple{typeof(Pkg.Types.read_project_compat), Base.Dict{String, Any}, Pkg.Types.Project}) 
            Base.precompile(Tuple{typeof(Pkg.Versions.semver_interval), Base.RegexMatch}) 
        # end
    # end
end

pkg_precompile()
end
