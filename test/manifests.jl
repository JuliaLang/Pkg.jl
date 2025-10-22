module ManifestTests

using Test, UUIDs, Dates, TOML
import ..Pkg, LibGit2
using ..Utils

# used with the reference manifests in `test/manifest/formats`
# ensures the manifests are valid and restored after test
function reference_manifest_isolated_test(f, dir::String; v1::Bool = false)
    source_env_dir = joinpath(@__DIR__, "manifest", "formats", dir)

    # Create a temporary directory for the test files
    temp_base_dir = mktempdir()
    return try
        # Copy entire directory structure to preserve paths that tests expect
        env_dir = joinpath(temp_base_dir, dir)
        cp(source_env_dir, env_dir)

        env_manifest = joinpath(env_dir, "Manifest.toml")

        isfile(env_manifest) || error("Reference manifest is missing")
        if Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == !v1
            error("Reference manifest file at $(env_manifest) is invalid")
        end
        isolate(loaded_depot = true) do
            f(env_dir, env_manifest)
        end
    finally
        # Clean up temporary directory
        rm(temp_base_dir, recursive = true)
    end
end

##

@testset "Manifest.toml formats" begin
    @testset "Default manifest format is v2.1" begin
        isolate(loaded_depot = true) do
            io = IOBuffer()
            Pkg.activate(; io = io, temp = true)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*", output)
            Pkg.add("Profile")
            env_manifest = Pkg.Types.Context().env.manifest_file
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.1.0"
        end
    end

    @testset "Empty manifest file is automatically upgraded to v2" begin
        isolate(loaded_depot = true) do
            io = IOBuffer()
            d = mktempdir()
            manifest = joinpath(d, "Manifest.toml")
            touch(manifest)
            Pkg.activate(d; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*", output)
            env_manifest = Pkg.Types.Context().env.manifest_file
            @test samefile(env_manifest, manifest)
            # an empty manifest is still technically considered to be v1 manifest
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.0.0"

            Pkg.add("Profile"; io = io)
            env_manifest = Pkg.Types.Context().env.manifest_file
            @test samefile(env_manifest, manifest)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.1.0"

            # check that having a Project with deps, and an empty manifest file doesn't error
            rm(manifest)
            touch(manifest)
            Pkg.activate(d; io = io)
            Pkg.add("Example"; io = io)
        end
    end

    @testset "v1.0: activate, change, maintain manifest format" begin
        reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))
        end
    end

    @testset "v2.0: activate, change, maintain manifest format" begin
        reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v2.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            m = Pkg.Types.read_manifest(env_manifest)
            @test m.other["some_other_field"] == "other"
            @test m.other["some_other_data"] == [1, 2, 3, 4]

            mktemp() do path, io
                Pkg.Types.write_manifest(io, m)
                m2 = Pkg.Types.read_manifest(env_manifest)
                @test m.deps == m2.deps
                @test m.julia_version == m2.julia_version
                @test m.manifest_format == m2.manifest_format
                @test m.other == m2.other
            end
        end
        reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
            m = Pkg.Types.read_manifest(env_manifest)
            m.julia_version = v"1.5.0"
            msg = r"The active manifest file has dependencies that were resolved with a different julia version"
            @test_logs (:warn, msg) Pkg.Types.check_manifest_julia_version_compat(m, env_manifest)
            @test_throws Pkg.Types.PkgError Pkg.Types.check_manifest_julia_version_compat(m, env_manifest, julia_version_strict = true)

            m.julia_version = nothing
            msg = r"The active manifest file is missing a julia version entry"
            @test_logs (:warn, msg) Pkg.Types.check_manifest_julia_version_compat(m, env_manifest)
            @test_throws Pkg.Types.PkgError Pkg.Types.check_manifest_julia_version_compat(m, env_manifest, julia_version_strict = true)
        end
    end

    @testset "v2.1: activate, change, maintain manifest format with registries" begin
        reference_manifest_isolated_test("v2.1") do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v2.1`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false

            m = Pkg.Types.read_manifest(env_manifest)
            @test m.manifest_format == v"2.1.0"
            @test m.other["some_other_field"] == "other"
            @test m.other["some_other_data"] == [1, 2, 3, 4]

            # Check that registries are present
            @test !isempty(m.registries)
            @test haskey(m.registries, "General")
            @test m.registries["General"].uuid == UUID("23338594-aafe-5451-b93e-139f81909106")
            @test m.registries["General"].url == "https://github.com/JuliaRegistries/General.git"

            # Check that Example has registry field
            example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
            @test haskey(m, example_uuid)
            @test !isempty(m[example_uuid].registries)
            @test "General" in m[example_uuid].registries

            # Write and read back to verify round-trip
            mktemp() do path, io
                Pkg.Types.write_manifest(io, m)
                close(io)
                m2 = Pkg.Types.read_manifest(path)
                @test m.deps == m2.deps
                @test m.julia_version == m2.julia_version
                @test m.manifest_format == m2.manifest_format
                @test m.other == m2.other
                @test m.registries == m2.registries
            end

            Pkg.add("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            # Manifest format should remain 2.1
            @test Pkg.Types.read_manifest(env_manifest).manifest_format >= v"2.1.0"

            Pkg.rm("Profile")
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
        end
    end

    @testset "v3.0: unknown format, warn" begin
        # the reference file here is not actually v3.0. It just represents an unknown manifest format
        reference_manifest_isolated_test("v3.0_unknown") do env_dir, env_manifest
            io = IOBuffer()
            @test_logs (:warn,) Pkg.activate(env_dir; io = io)
        end
    end

    @testset "Pkg.upgrade_manifest()" begin
        reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.upgrade_manifest()
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.1.0"
        end
    end
    @testset "Pkg.upgrade_manifest(manifest_path)" begin
        reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
            io = IOBuffer()
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest))

            Pkg.upgrade_manifest(env_manifest)
            @test Base.is_v1_format_manifest(Base.parsed_toml(env_manifest)) == false
            Pkg.activate(env_dir; io = io)
            output = String(take!(io))
            @test occursin(r"Activating.*project at.*`.*v1.0`", output)
            @test Pkg.Types.Context().env.manifest.manifest_format == v"2.1.0"
        end
    end
end

@testset "Manifest metadata" begin
    @testset "julia_version" begin
        @testset "dropbuild" begin
            @test Pkg.Operations.dropbuild(v"1.2.3-DEV.2134") == v"1.2.3-DEV"
            @test Pkg.Operations.dropbuild(v"1.2.3-DEV") == v"1.2.3-DEV"
            @test Pkg.Operations.dropbuild(v"1.2.3") == v"1.2.3"
            @test Pkg.Operations.dropbuild(v"1.2.3-rc1") == v"1.2.3-rc1"
        end
        @testset "new environment: value is `nothing`, then ~`VERSION` after resolve" begin
            isolate(loaded_depot = true) do
                Pkg.activate(; temp = true)
                @test Pkg.Types.Context().env.manifest.julia_version == nothing
                Pkg.add("Profile")
                @test Pkg.Types.Context().env.manifest.julia_version == Pkg.Operations.dropbuild(VERSION)
            end
        end
        @testset "activating old environment: maintains old version, then ~`VERSION` after resolve" begin
            reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
                Pkg.activate(env_dir)
                @test Pkg.Types.Context().env.manifest.julia_version == v"1.7.0-DEV"

                Pkg.add("Profile")
                @test Pkg.Types.Context().env.manifest.julia_version == Pkg.Operations.dropbuild(VERSION)
            end
        end
        @testset "instantiate manifest from different julia_version" begin
            reference_manifest_isolated_test("v1.0", v1 = true) do env_dir, env_manifest
                Pkg.activate(env_dir)
                @test_logs (:warn, r"The active manifest file") Pkg.instantiate()
                @test Pkg.Types.Context().env.manifest.julia_version == nothing
            end
            if VERSION >= v"1.8"
                reference_manifest_isolated_test("v2.0") do env_dir, env_manifest
                    Pkg.activate(env_dir)
                    @test_logs (:warn, r"The active manifest file") Pkg.instantiate()
                    @test Pkg.Types.Context().env.manifest.julia_version == v"1.7.0-DEV"
                end
            end
        end
        @testset "project_hash for identifying out of sync manifest" begin
            isolate(loaded_depot = true) do
                iob = IOBuffer()

                Pkg.activate(; temp = true)
                Pkg.add("Example")
                @test Pkg.is_manifest_current(Pkg.Types.Context()) === true

                Pkg.compat("Example", "0.4")
                @test Pkg.is_manifest_current(Pkg.Types.Context()) === false
                Pkg.status(io = iob)
                sync_msg_str = r"The project dependencies or compat requirements have changed since the manifest was last resolved."
                @test occursin(sync_msg_str, String(take!(iob)))
                @test_logs (:warn, sync_msg_str) Pkg.instantiate()

                Pkg.update()
                @test Pkg.is_manifest_current(Pkg.Types.Context()) === true
                Pkg.status(io = iob)
                @test !occursin(sync_msg_str, String(take!(iob)))

                Pkg.compat("Example", "0.5")
                Pkg.status(io = iob)
                @test occursin(sync_msg_str, String(take!(iob)))
                @test_logs (:warn, sync_msg_str) Pkg.instantiate()

                Pkg.rm("Example")
                @test Pkg.is_manifest_current(Pkg.Types.Context()) === true
                Pkg.status(io = iob)
                @test !occursin(sync_msg_str, String(take!(iob)))
            end
        end
    end
end

@testset "Manifest registry tracking" begin
    @testset "Manifest format upgraded to 2.1 when registries tracked" begin
        isolate(loaded_depot = true) do
            Pkg.activate(; temp = true)
            Pkg.add("Example")
            ctx = Pkg.Types.Context()

            # Check that manifest format is 2.1 when registries are tracked
            @test ctx.env.manifest.manifest_format >= v"2.1.0"

            # Check that registries section exists and has General registry
            @test !isempty(ctx.env.manifest.registries)
            @test any(reg -> reg.uuid == UUID("23338594-aafe-5451-b93e-139f81909106"), values(ctx.env.manifest.registries))

            # Check that Example package has registry field
            example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
            example_entry = ctx.env.manifest[example_uuid]
            @test !isempty(example_entry.registries)
            @test "General" in example_entry.registries
        end
    end

    @testset "Registries written and read from manifest" begin
        isolate(loaded_depot = true) do
            Pkg.activate(; temp = true)
            Pkg.add("Example")

            env_manifest = Pkg.Types.Context().env.manifest_file

            # Read the TOML and check structure
            manifest_toml = TOML.parsefile(env_manifest)
            @test haskey(manifest_toml, "registries")
            @test haskey(manifest_toml["registries"], "General")

            general_entry = manifest_toml["registries"]["General"]
            @test haskey(general_entry, "uuid")
            @test general_entry["uuid"] == "23338594-aafe-5451-b93e-139f81909106"
            @test haskey(general_entry, "url")

            # Check that packages have registry field
            @test haskey(manifest_toml, "deps")
            @test haskey(manifest_toml["deps"], "Example")
            example_entries = manifest_toml["deps"]["Example"]
            @test example_entries isa Vector
            @test length(example_entries) > 0
            # Check that at least one entry has registries field
            @test any(e -> haskey(e, "registries") || haskey(e, "registry"), example_entries)

            # Read it back with Pkg API and verify
            manifest = Pkg.Types.read_manifest(env_manifest)
            @test !isempty(manifest.registries)
            example_uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
            @test haskey(manifest, example_uuid)
            @test !isempty(manifest[example_uuid].registries)
        end
    end

    @testset "Instantiate with non-default registry from manifest" begin
        isolate(loaded_depot = true) do
            mktempdir() do test_dir
                # Create a test package git repository
                pkg_repo_path = joinpath(test_dir, "TestPkg.git")
                mkpath(joinpath(pkg_repo_path, "src"))
                pkg_uuid = uuid4()

                write(
                    joinpath(pkg_repo_path, "Project.toml"), """
                    name = "TestPkg"
                    uuid = "$pkg_uuid"
                    version = "0.1.0"
                    """
                )
                write(
                    joinpath(pkg_repo_path, "src", "TestPkg.jl"), """
                    module TestPkg
                    greet() = "Hello from TestPkg!"
                    end
                    """
                )
                Utils.git_init_and_commit(pkg_repo_path)

                # Get the git tree hash for the package
                pkg_tree_hash = cd(pkg_repo_path) do
                    return LibGit2.with(LibGit2.GitRepo(pkg_repo_path)) do repo
                        return string(LibGit2.GitHash(LibGit2.peel(LibGit2.GitTree, LibGit2.head(repo))))
                    end
                end

                # Create a custom registry
                regpath = joinpath(test_dir, "CustomReg")
                reg_uuid = uuid4()

                mkpath(joinpath(regpath, "TestPkg"))
                write(
                    joinpath(regpath, "Registry.toml"), """
                    name = "CustomReg"
                    uuid = "$reg_uuid"
                    repo = "$(regpath)"
                    [packages]
                    $pkg_uuid = { name = "TestPkg", path = "TestPkg" }
                    """
                )
                write(
                    joinpath(regpath, "TestPkg", "Package.toml"), """
                    name = "TestPkg"
                    uuid = "$pkg_uuid"
                    repo = "$pkg_repo_path"
                    """
                )
                write(
                    joinpath(regpath, "TestPkg", "Versions.toml"), """
                    ["0.1.0"]
                    git-tree-sha1 = "$pkg_tree_hash"
                    """
                )
                write(
                    joinpath(regpath, "TestPkg", "Compat.toml"), """
                    ["0.1"]
                    julia = "1.0-2"
                    """
                )
                Utils.git_init_and_commit(regpath)

                # Add the registry and a package from it
                Pkg.Registry.add(url = regpath)
                Pkg.activate(; temp = true)
                Pkg.add(Pkg.Types.PackageSpec(name = "TestPkg", uuid = pkg_uuid))

                # Get the manifest content
                manifest_file = Pkg.Types.Context().env.manifest_file
                manifest_content = read(manifest_file, String)

                # Now create a new isolated environment and copy the manifest
                isolate(loaded_depot = true) do
                    # Verify the custom registry is not installed
                    @test !any(r -> r.uuid == reg_uuid, Pkg.Registry.reachable_registries())

                    # Create a new temp environment with the manifest
                    mktempdir() do env_dir
                        project_file = joinpath(env_dir, "Project.toml")
                        new_manifest_file = joinpath(env_dir, "Manifest.toml")

                        write(
                            project_file, """
                            [deps]
                            TestPkg = "$pkg_uuid"
                            """
                        )
                        write(new_manifest_file, manifest_content)

                        Pkg.activate(env_dir)

                        # Before instantiate, registry should not be installed
                        @test !any(r -> r.uuid == reg_uuid, Pkg.Registry.reachable_registries())

                        # Instantiate should automatically install the registry from manifest
                        Pkg.instantiate()

                        # After instantiate, registry should be installed
                        @test any(r -> r.uuid == reg_uuid, Pkg.Registry.reachable_registries())
                    end
                end
            end
        end
    end

    @testset "Non-registry packages do not have registry field" begin
        isolate(loaded_depot = true) do
            mktempdir() do test_dir
                # Create a simple package to develop
                dev_pkg_dir = joinpath(test_dir, "DevPkg")
                mkpath(joinpath(dev_pkg_dir, "src"))
                dev_pkg_uuid = uuid4()

                write(
                    joinpath(dev_pkg_dir, "Project.toml"), """
                    name = "DevPkg"
                    uuid = "$dev_pkg_uuid"
                    version = "0.1.0"
                    """
                )
                write(
                    joinpath(dev_pkg_dir, "src", "DevPkg.jl"), """
                    module DevPkg
                    greet() = "Hello from DevPkg!"
                    end
                    """
                )

                # Create a git package
                git_pkg_dir = joinpath(test_dir, "GitPkg")
                mkpath(joinpath(git_pkg_dir, "src"))
                git_pkg_uuid = uuid4()

                write(
                    joinpath(git_pkg_dir, "Project.toml"), """
                    name = "GitPkg"
                    uuid = "$git_pkg_uuid"
                    version = "0.1.0"
                    """
                )
                write(
                    joinpath(git_pkg_dir, "src", "GitPkg.jl"), """
                    module GitPkg
                    greet() = "Hello from GitPkg!"
                    end
                    """
                )

                Utils.git_init_and_commit(git_pkg_dir)

                Pkg.activate(; temp = true)
                Pkg.develop(path = dev_pkg_dir)
                Pkg.add(url = git_pkg_dir)

                ctx = Pkg.Types.Context()

                # Developed package should not have registry field
                @test haskey(ctx.env.manifest, dev_pkg_uuid)
                dev_entry = ctx.env.manifest[dev_pkg_uuid]
                @test isempty(dev_entry.registries)

                # Git package should not have registry field
                @test haskey(ctx.env.manifest, git_pkg_uuid)
                git_entry = ctx.env.manifest[git_pkg_uuid]
                @test isempty(git_entry.registries)

                # Manifest format is always 2.1 now
                @test ctx.env.manifest.manifest_format == v"2.1.0"
                # Registries section should be empty since no registry packages
                @test isempty(ctx.env.manifest.registries)
            end
        end
    end

    @testset "Package in multiple registries records all" begin
        isolate(loaded_depot = true) do
            mktempdir() do test_dir
                # Create a test package git repository
                pkg_repo_path = joinpath(test_dir, "SharedPkg.git")
                mkpath(joinpath(pkg_repo_path, "src"))
                pkg_uuid = uuid4()

                write(
                    joinpath(pkg_repo_path, "Project.toml"), """
                    name = "SharedPkg"
                    uuid = "$pkg_uuid"
                    version = "1.0.0"
                    """
                )
                write(
                    joinpath(pkg_repo_path, "src", "SharedPkg.jl"), """
                    module SharedPkg
                    greet() = "Hello from SharedPkg!"
                    end
                    """
                )
                Utils.git_init_and_commit(pkg_repo_path)

                # Get the git tree hash for the package
                pkg_tree_hash = cd(pkg_repo_path) do
                    return LibGit2.with(LibGit2.GitRepo(pkg_repo_path)) do repo
                        return string(LibGit2.GitHash(LibGit2.peel(LibGit2.GitTree, LibGit2.head(repo))))
                    end
                end

                # Create two registries with the same package
                reg1_uuid = uuid4()
                reg1_path = joinpath(test_dir, "Registry1")
                mkpath(joinpath(reg1_path, "SharedPkg"))
                write(
                    joinpath(reg1_path, "Registry.toml"), """
                    name = "Registry1"
                    uuid = "$reg1_uuid"
                    repo = "$(reg1_path)"
                    [packages]
                    $pkg_uuid = { name = "SharedPkg", path = "SharedPkg" }
                    """
                )
                write(
                    joinpath(reg1_path, "SharedPkg", "Package.toml"), """
                    name = "SharedPkg"
                    uuid = "$pkg_uuid"
                    repo = "$pkg_repo_path"
                    """
                )
                write(
                    joinpath(reg1_path, "SharedPkg", "Versions.toml"), """
                    ["1.0.0"]
                    git-tree-sha1 = "$pkg_tree_hash"
                    """
                )
                write(
                    joinpath(reg1_path, "SharedPkg", "Compat.toml"), """
                    ["1"]
                    julia = "1.0-2"
                    """
                )
                Utils.git_init_and_commit(reg1_path)

                reg2_uuid = uuid4()
                reg2_path = joinpath(test_dir, "Registry2")
                mkpath(joinpath(reg2_path, "SharedPkg"))
                write(
                    joinpath(reg2_path, "Registry.toml"), """
                    name = "Registry2"
                    uuid = "$reg2_uuid"
                    repo = "$(reg2_path)"
                    [packages]
                    $pkg_uuid = { name = "SharedPkg", path = "SharedPkg" }
                    """
                )
                write(
                    joinpath(reg2_path, "SharedPkg", "Package.toml"), """
                    name = "SharedPkg"
                    uuid = "$pkg_uuid"
                    repo = "$pkg_repo_path"
                    """
                )
                write(
                    joinpath(reg2_path, "SharedPkg", "Versions.toml"), """
                    ["1.0.0"]
                    git-tree-sha1 = "$pkg_tree_hash"
                    """
                )
                write(
                    joinpath(reg2_path, "SharedPkg", "Compat.toml"), """
                    ["1"]
                    julia = "1.0-2"
                    """
                )
                Utils.git_init_and_commit(reg2_path)

                # Add both registries
                Pkg.Registry.add(url = reg1_path)
                Pkg.Registry.add(url = reg2_path)

                # Add the package
                Pkg.activate(; temp = true)
                Pkg.add(Pkg.Types.PackageSpec(name = "SharedPkg", uuid = pkg_uuid))

                ctx = Pkg.Types.Context()
                @test haskey(ctx.env.manifest, pkg_uuid)
                pkg_entry = ctx.env.manifest[pkg_uuid]

                # Package should reference both registries
                @test length(pkg_entry.registries) == 2
                @test "Registry1" in pkg_entry.registries
                @test "Registry2" in pkg_entry.registries

                # Both registries should be in the manifest
                @test haskey(ctx.env.manifest.registries, "Registry1")
                @test haskey(ctx.env.manifest.registries, "Registry2")

                # Check TOML output
                manifest_toml = TOML.parsefile(ctx.env.manifest_file)
                shared_pkg_entries = manifest_toml["deps"]["SharedPkg"]
                @test shared_pkg_entries isa Vector
                @test length(shared_pkg_entries) == 1
                registries_field = shared_pkg_entries[1]["registries"]
                @test registries_field isa Vector
                @test length(registries_field) == 2
                @test "Registry1" in registries_field
                @test "Registry2" in registries_field
            end
        end
    end
end

end # module
