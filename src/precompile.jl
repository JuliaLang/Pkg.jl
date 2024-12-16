using LibGit2: LibGit2
using Tar: Tar
using Downloads

# used by REPLExt too
function _run_precompilation_script_setup()
    tmp = mktempdir()
    cd(tmp) do
        empty!(DEPOT_PATH)
        pushfirst!(DEPOT_PATH, tmp)
        pushfirst!(LOAD_PATH, "@")
        write(
            "Project.toml",
            """
            name = "Hello"
            uuid = "33cfe95a-1eb2-52ea-b672-e2afdf69b78f"
            """,
        )
        mkdir("src")
        write(
            "src/Hello.jl",
            """
            module Hello
            end
            """,
        )
        Pkg.activate(".")
        Pkg.generate("TestPkg")
        uuid = TOML.parsefile(joinpath("TestPkg", "Project.toml"))["uuid"]
        mv("TestPkg", "TestPkg.jl")
        tree_hash = cd("TestPkg.jl") do
            sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time()), 0)
            repo = LibGit2.init(".")
            LibGit2.add!(repo, "")
            commit =
                LibGit2.commit(repo, "initial commit"; author = sig, committer = sig)
            th =
                LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(repo, commit)) |>
                LibGit2.GitHash |>
                string
            close(repo)
            th
        end
        # Prevent cloning the General registry by adding a fake one
        mkpath("registries/Registry/T/TestPkg")
        write(
            "registries/Registry/Registry.toml",
            """
            name = "Registry"
            uuid = "37c07fec-e54c-4851-934c-2e3885e4053e"
            repo = "https://github.com/JuliaRegistries/Registry.git"
            [packages]
            $uuid = { name = "TestPkg", path = "T/TestPkg" }
            """,
        )
        write(
            "registries/Registry/T/TestPkg/Compat.toml",
            """
            ["0"]
            julia = "1"
            """,
        )
        write(
            "registries/Registry/T/TestPkg/Deps.toml",
            """
            ["0"]
            Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
            """,
        )
        write(
            "registries/Registry/T/TestPkg/Versions.toml",
            """
            ["0.1.0"]
            git-tree-sha1 = "$tree_hash"
            """,
        )
        write(
            "registries/Registry/T/TestPkg/Package.toml",
            """
            name = "TestPkg"
            uuid = "$uuid"
            repo = "$(escape_string(tmp))/TestPkg.jl"
            """,
        )
        Tar.create("registries/Registry", "registries/Registry.tar")
        cmd = `$(Pkg.PlatformEngines.exe7z()) a "registries/Registry.tar.gz" -tgzip "registries/Registry.tar"`
        run(pipeline(cmd, stdout = stdout_f(), stderr = stderr_f()))
        write(
            "registries/Registry.toml",
            """
            git-tree-sha1 = "11b5fad51c4f98cfe0c145ceab0b8fb63fed6f81"
            uuid = "37c07fec-e54c-4851-934c-2e3885e4053e"
            path = "Registry.tar.gz"
            """,
        )
        Base.rm("registries/Registry"; recursive = true)
    end
    return tmp
end

let
    function pkg_precompile()
        original_depot_path = copy(DEPOT_PATH)
        original_load_path = copy(LOAD_PATH)

        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
        # Default 30 sec grace period means we hang 30 seconds before precompiling finishes
        DEFAULT_IO[] = unstableio(devnull)
        Downloads.DOWNLOADER[] = Downloads.Downloader(; grace = 1.0)

        # We need to override JULIA_PKG_UNPACK_REGISTRY to fix https://github.com/JuliaLang/Pkg.jl/issues/3663
        withenv("JULIA_PKG_SERVER" => nothing, "JULIA_PKG_UNPACK_REGISTRY" => nothing) do
            tmp = _run_precompilation_script_setup()
            cd(tmp) do
                withenv("JULIA_PKG_PRECOMPILE_AUTO" => 0) do
                    Pkg.add("TestPkg")
                    Pkg.develop(Pkg.PackageSpec(path = "TestPkg.jl"))
                    Pkg.add(Pkg.PackageSpec(path = "TestPkg.jl/"))
                    Pkg.update(; update_registry = false)
                    Pkg.status()
                    Pkg.Registry.update()
                    pkgs_path = pkgdir(Pkg, "test", "test_packages")
                    # Precompile a diverse set of test packages
                    # Check all test packages occasionally if anything has been missed
                    # test_packages = readdir(pkgs_path)
                    test_packages = (
                        "ActiveProjectInTestSubgraph",
                        "BasicSandbox",
                        "DependsOnExample",
                        "PackageWithDependency",
                        "SameNameDifferentUUID",
                        "SimplePackage",
                        "BasicCompat",
                        "PackageWithDependency",
                        "SameNameDifferentUUID",
                        "SimplePackage",
                        joinpath("ExtensionExamples", "HasExtensions.jl"),
                    )
                    for test_package in test_packages
                        Pkg.activate(joinpath(pkgs_path, test_package))
                    end
                    Pkg.activate(; temp = true)
                    Pkg.activate()
                    Pkg.activate("TestPkg.jl")
                end
                Pkg.precompile()
            end
            try
                Base.rm(tmp; recursive = true)
            catch
            end

            Base.precompile(Tuple{typeof(Pkg.API.status)})
            Base.precompile(Tuple{typeof(Pkg.Types.read_project_compat),Base.Dict{String,Any},Pkg.Types.Project,},)
            Base.precompile(Tuple{typeof(Pkg.Versions.semver_interval),Base.RegexMatch})

            Base.precompile(Tuple{typeof(Pkg.REPLMode.do_cmds), Array{Pkg.REPLMode.Command, 1}, Base.TTY})

            Base.precompile(Tuple{typeof(Pkg.Types.read_project_workspace), Base.Dict{String, Any}, Pkg.Types.Project})
            Base.precompile(Tuple{Type{Pkg.REPLMode.QString}, String, Bool})
            Base.precompile(Tuple{typeof(Pkg.REPLMode.parse_package), Array{Pkg.REPLMode.QString, 1}, Base.Dict{Symbol, Any}})
            Base.precompile(Tuple{Type{Pkg.REPLMode.Command}, Pkg.REPLMode.CommandSpec, Base.Dict{Symbol, Any}, Array{Pkg.Types.PackageSpec, 1}})
        end
        copy!(DEPOT_PATH, original_depot_path)
        copy!(LOAD_PATH, original_load_path)
        return nothing
    end

    # Copied from REPL (originally PrecompileTools.jl)
    function check_edges(node)
        parentmi = node.mi_info.mi
        for child in node.children
            childmi = child.mi_info.mi
            if !(isdefined(childmi, :backedges) && parentmi ∈ childmi.backedges)
                Base.precompile(childmi.specTypes)
            end
            check_edges(child)
        end
    end

    if Base.generating_output() && Base.JLOptions().use_pkgimages != 0
        Core.Compiler.Timings.reset_timings()
        Core.Compiler.__set_measure_typeinf(true)
        try
            pkg_precompile()
        finally
            Core.Compiler.__set_measure_typeinf(false)
            Core.Compiler.Timings.close_current_timer()
        end
        roots = Core.Compiler.Timings._timings[1].children
        for child in roots
            Base.precompile(child.mi_info.mi.specTypes)
            check_edges(child)
        end
    end
end
