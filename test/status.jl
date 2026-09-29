module StatusTests

using Test, UUIDs
import ..Pkg
using Pkg.Types: PkgError
using ..Utils

exuuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a") # UUID for `Example.jl`
json_uuid = UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6")

@testset "why" begin
    isolate() do
        Pkg.add(name = "StaticArrays", version = "1.5.20")

        io = IOBuffer()
        Pkg.why("StaticArrays"; io)
        str = String(take!(io))
        @test str == "  StaticArrays\n"

        Pkg.why("StaticArraysCore"; io)
        str = String(take!(io))
        @test str ==
            """  StaticArraysCore
              └── StaticArrays
            """

        Pkg.why("LinearAlgebra"; io)
        str = String(take!(io))
        @test str ==
            """  LinearAlgebra
              ├── StaticArrays
              └── Statistics
                  └── StaticArrays
            """

    end

    # A → C, C → D, C → E, E → D: C's dependents are shown once and then marked with (*).
    # F is in the manifest but not depended on by the project.
    isolate() do
        mktempdir() do dir
            uuids = Dict(n => string(uuid4()) for n in ("A", "C", "D", "E", "F"))
            write(
                joinpath(dir, "Project.toml"), """
                [deps]
                A = "$(uuids["A"])"
                """
            )
            write(
                joinpath(dir, "Manifest.toml"), """
                manifest_format = "2.0"

                [[deps.A]]
                deps = ["C"]
                uuid = "$(uuids["A"])"
                version = "0.1.0"

                [[deps.C]]
                deps = ["D", "E"]
                uuid = "$(uuids["C"])"
                version = "0.1.0"

                [[deps.D]]
                uuid = "$(uuids["D"])"
                version = "0.1.0"

                [[deps.E]]
                deps = ["D"]
                uuid = "$(uuids["E"])"
                version = "0.1.0"

                [[deps.F]]
                deps = ["D"]
                uuid = "$(uuids["F"])"
                version = "0.1.0"
                """
            )
            Pkg.activate(dir)
            Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
            io = IOBuffer()
            Pkg.why("D"; io)
            @test String(take!(io)) ==
                """  D
                  ├── C
                  │   └── A
                  └── E
                      └── C (*)
                """
            Pkg.why("D"; io, forward = true)
            @test String(take!(io)) ==
                """  A
                  └── C
                      ├── D
                      └── E
                          └── D
                """
            Pkg.why("F"; io)
            @test String(take!(io)) == ""
            Pkg.why(["A", "E"]; io)
            @test String(take!(io)) ==
                """  A

                  E
                  └── C
                      └── A
                """
        end
    end
end

@testset "Pkg.status" begin
    # other
    isolate(loaded_depot = true) do
        # IO is necessary even if we're not looking at it, because we have a short-circuit for
        # devnull (and also don't want to pollute the logs (if any))
        io = PipeBuffer()
        @test_deprecated Pkg.status(Pkg.PKGMODE_MANIFEST)
        @test_logs (:warn, r"diff option only available") match_mode = :any Pkg.status(diff = true; io)
    end
    # State changes
    isolate(loaded_depot = true) do
        io = IOBuffer()
        # Basic Add
        Pkg.add(Pkg.PackageSpec(; name = "Example", version = "0.3.0"); io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] \+ Example v0\.3\.0", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] \+ Example v0\.3\.0", output)
        # Double add should not claim "Updating"
        Pkg.add(Pkg.PackageSpec(; name = "Example", version = "0.3.0"); io = io)
        output = String(take!(io))
        @test occursin(r"No packages added to or removed from `.+Project\.toml`", output)
        @test occursin(r"No packages added to or removed from `.+Manifest\.toml`", output)
        # From tracking registry to tracking repo
        Pkg.add(Pkg.PackageSpec(; name = "Example", rev = "master"); io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v0\.3\.0 ⇒ v\d\.\d\.\d `https://github\.com/JuliaLang/Example\.jl\.git#master`", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v0\.3\.0 ⇒ v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master`", output)
        # From tracking repo to tracking path
        Pkg.develop("Example"; io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github\.com/JuliaLang/Example\.jl\.git#master` ⇒ v\d\.\d\.\d `.+`", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github\.com/JuliaLang/Example\.jl\.git#master` ⇒ v\d\.\d\.\d `.+`", output)
        # From tracking path to tracking repo
        Pkg.add(Pkg.PackageSpec(; name = "Example", rev = "master"); io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `.+` ⇒ v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master`", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `.+` ⇒ v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master`", output)
        # From tracking repo to tracking registered version
        Pkg.free("Example"; io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v\d\.\d\.\d", output)
        @test occursin(r"Updating `.+Manifest\.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d `https://github.com/JuliaLang/Example.jl.git#master` ⇒ v\d\.\d\.\d", output)
        # Removing registered version
        Pkg.rm("Example"; io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] - Example v\d\.\d\.\d", output)
        @test occursin(r"Updating `.+Manifest.toml`", output)
        @test occursin(r"\[7876af07\] - Example v\d\.\d\.\d", output)

        # Pinning a registered package
        Pkg.add("Example")
        Pkg.pin("Example"; io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d ⇒ v\d\.\d\.\d ⚲", output)
        @test occursin(r"Updating `.+Manifest.toml`", output)

        # Free a pinned package
        Pkg.free("Example"; io = io)
        output = String(take!(io))
        @test occursin(r"Updating `.+Project.toml`", output)
        @test occursin(r"\[7876af07\] ~ Example v\d\.\d\.\d ⚲ ⇒ v\d\.\d\.\d", output)
        @test occursin(r"Updating `.+Manifest.toml`", output)
    end
    # Project Status API
    isolate(loaded_depot = true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
        io = PipeBuffer()
        ## empty project
        Pkg.status(; io = io)
        @test occursin(r"Status `.+Project.toml` \(empty project\)", readline(io))
        ## loaded project
        Pkg.add("Markdown")
        Pkg.add(name = "JSON", version = "0.18.0")
        Pkg.develop("Example")
        Pkg.add(url = "https://github.com/00vareladavid/Unregistered.jl")
        Pkg.status(; io = io)
        @test occursin(r"Status `.+Project\.toml`", readline(io))
        @test occursin(r"\[7876af07\] Example\s*v\d\.\d\.\d\s*`.+`", readline(io))
        @test occursin(r"\[682c06a0\] JSON\s*v0.18.0", readline(io))
        @test occursin(r"\[dcb67f36\] Unregistered\s*v\d\.\d\.\d\s*`https://github\.com/00vareladavid/Unregistered\.jl#master`", readline(io))
        @test occursin(r"\[d6f4376e\] Markdown", readline(io))
    end
    ## status warns when package not installed
    isolate() do
        Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
        Pkg.activate(joinpath(@__DIR__, "test_packages", "Status"))
        io = PipeBuffer()
        Pkg.status(; io = io)
        @test occursin(r"Status `.+Project.toml`", readline(io))
        @test occursin(r"^→⌃ \[7876af07\] Example\s*v\d\.\d\.\d", readline(io))
        @test occursin(r"^   \[d6f4376e\] Markdown", readline(io))
        @test "Info Packages marked with → are not downloaded, use `instantiate` to download" == strip(readline(io))
        @test "Info Packages marked with ⌃ have new versions available and may be upgradable." == strip(readline(io))
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest.toml`", readline(io))
        @test occursin(r"^→⌃ \[7876af07\] Example\s*v\d\.\d\.\d", readline(io))
        @test occursin(r"^   \[2a0f44e3\] Base64", readline(io))
        @test occursin(r"^   \[d6f4376e\] Markdown", readline(io))
        @test "Info Packages marked with → are not downloaded, use `instantiate` to download" == strip(readline(io))
        @test "Info Packages marked with ⌃ have new versions available and may be upgradable." == strip(readline(io))
        Pkg.instantiate(; io = devnull) # download Example
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest.toml`", readline(io))
        @test occursin(r"^⌃ \[7876af07\] Example\s*v\d\.\d\.\d", readline(io))
        @test occursin(r"^  \[2a0f44e3\] Base64", readline(io))
        @test occursin(r"^  \[d6f4376e\] Markdown", readline(io))
        @test "Info Packages marked with ⌃ have new versions available and may be upgradable." == strip(readline(io))
    end
    # Manifest Status API
    isolate(loaded_depot = true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
        io = PipeBuffer()
        ## empty manifest
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST)
        @test occursin(r"Status `.+Manifest\.toml` \(empty manifest\)", readline(io))
        # loaded manifest
        Pkg.add(name = "Example", version = "0.3.0")
        Pkg.add("Markdown")
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST)
        statuslines = readlines(io)
        @test occursin(r"Status `.+Manifest.toml`", first(statuslines))
        @test any(l -> occursin(r"\[7876af07\] Example\s*v0\.3\.0", l), statuslines)
        @test any(l -> occursin(r"\[2a0f44e3\] Base64", l), statuslines)
        @test any(l -> occursin(r"\[d6f4376e\] Markdown", l), statuslines)
        # Test that manifest status with filter shows package and its dependencies (issue #1989)
        Pkg.add(name = "JSON", version = "0.21.0")  # JSON has dependencies
        Pkg.status("JSON"; io = io, mode = Pkg.PKGMODE_MANIFEST)
        statuslines = readlines(io)
        @test occursin(r"Status `.+Manifest.toml`", first(statuslines))
        @test any(l -> occursin(r"\[682c06a0\] JSON\s*v0\.21\.0", l), statuslines)
        # JSON's dependencies (Parsers, Dates, Mmap, Unicode) should also be shown
        @test any(l -> occursin(r"Parsers", l), statuslines)
        # But Example and Markdown (not dependencies of JSON) should not be shown
        @test !any(l -> occursin(r"\[7876af07\] Example", l), statuslines)
        @test !any(l -> occursin(r"\[d6f4376e\] Markdown", l), statuslines)
    end
    # Diff API
    isolate(loaded_depot = true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
        io = PipeBuffer()
        projdir = dirname(Pkg.project().path)
        mkpath(projdir)
        git_init_and_commit(projdir)
        ## empty project + empty diff
        Pkg.status(; io = io, diff = true)
        @test occursin(r"No packages added to or removed from `.+Project\.toml`", readline(io))
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST, diff = true)
        @test occursin(r"No packages added to or removed from `.+Manifest\.toml`", readline(io))
        ### empty diff + filter
        Pkg.status("Example"; io = io, diff = true)
        @test occursin(r"No packages added to or removed from `.+Project\.toml`", readline(io))
        ## non-empty project but empty diff
        Pkg.add("Markdown")
        git_init_and_commit(dirname(Pkg.project().path))
        Pkg.status(; io = io, diff = true)
        @test occursin(r"No packages added to or removed from `.+Project\.toml`", readline(io))
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST, diff = true)
        @test occursin(r"No packages added to or removed from `.+Manifest\.toml`", readline(io))
        ### filter should still show "empty diff"
        Pkg.status("Example"; io = io, diff = true)
        @test occursin(r"No packages added to or removed from `.+Project\.toml`", readline(io))
        ## non-empty project + non-empty diff
        Pkg.rm("Markdown")
        Pkg.add(name = "Example", version = "0.3.0")
        ## diff project
        Pkg.status(; io = io, diff = true)
        @test occursin(r"Diff `.+Project\.toml`", readline(io))
        @test occursin(r"\[7876af07\] \+ Example\s*v0\.3\.0", readline(io))
        @test occursin(r"\[d6f4376e\] - Markdown", readline(io))
        @test occursin("Info Packages marked with ⌃ have new versions available and may be upgradable.", readline(io))
        ## diff manifest
        Pkg.status(; io = io, mode = Pkg.PKGMODE_MANIFEST, diff = true)
        statuslines = readlines(io)
        @test occursin(r"Diff `.+Manifest.toml`", first(statuslines))
        @test any(l -> occursin(r"\[7876af07\] \+ Example\s*v0\.3\.0", l), statuslines)
        @test any(l -> occursin(r"\[2a0f44e3\] - Base64", l), statuslines)
        @test any(l -> occursin(r"\[d6f4376e\] - Markdown", l), statuslines)
        @test any(l -> occursin("Info Packages marked with ⌃ have new versions available and may be upgradable.", l), statuslines)
        ## diff project with filtering
        Pkg.status("Markdown"; io = io, diff = true)
        @test occursin(r"Diff `.+Project\.toml`", readline(io))
        @test occursin(r"\[d6f4376e\] - Markdown", readline(io))
        ## empty diff + filter
        Pkg.status("Base64"; io = io, diff = true)
        @test occursin(r"No Matches in diff for `.+Project\.toml`", readline(io))
        ## diff manifest with filtering
        Pkg.status("Base64"; io = io, mode = Pkg.PKGMODE_MANIFEST, diff = true)
        @test occursin(r"Diff `.+Manifest.toml`", readline(io))
        @test occursin(r"\[2a0f44e3\] - Base64", readline(io))
        ## manifest diff + empty filter
        Pkg.status("FooBar"; io = io, mode = Pkg.PKGMODE_MANIFEST, diff = true)
        @test occursin(r"No Matches in diff for `.+Manifest.toml`", readline(io))
    end
    # Outdated API
    isolate(loaded_depot = true) do
        Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
        Pkg.add("Example"; io = devnull)
        v = Pkg.dependencies()[exuuid].version
        io = IOBuffer()
        Pkg.add(Pkg.PackageSpec(name = "Example", version = "0.4.0"); io = devnull)
        Pkg.status(; outdated = true, io = io)
        str = String(take!(io))
        @test occursin(Regex("⌃\\s*\\[7876af07\\] Example\\s*v0.4.0\\s*\\(<v$v\\)"), str)
        Pkg.compat("Example", "0.4.1")
        Pkg.status(; outdated = true, io = io)
        str = String(take!(io))
        @test occursin(Regex("⌃\\s*\\[7876af07\\] Example\\s*v0.4.0\\s*\\[<v0.4.1\\], \\(<v$v\\)"), str)
    end
end

@testset "status --outdated: compat only taken from registries containing the version (#4849)" begin
    isolate(loaded_depot = true) do
        dep_uuid = "6b8c0ba6-8e4e-4a0b-9e5a-2f0d9c1a7e11"
        function write_dep_registry(name, uuid, versions, compat)
            reg = joinpath(DEPOT_PATH[1], "registries", name)
            pkg_path = joinpath(reg, "D", "DepOnExample")
            mkpath(pkg_path)
            write(
                joinpath(reg, "Registry.toml"), """
                name = "$name"
                uuid = "$uuid"
                repo = "whydoineedthis?"

                [packages]
                $dep_uuid = { name = "DepOnExample", path = "D/DepOnExample" }
                """
            )
            write(
                joinpath(pkg_path, "Package.toml"), """
                name = "DepOnExample"
                uuid = "$dep_uuid"
                repo = "https://example.com/DepOnExample.jl.git"
                """
            )
            write(
                joinpath(pkg_path, "Versions.toml"),
                join(("[\"$v\"]\ngit-tree-sha1 = \"46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc\"\n" for v in versions), "\n")
            )
            write(
                joinpath(pkg_path, "Deps.toml"), """
                ["1"]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            compat === nothing || write(
                joinpath(pkg_path, "Compat.toml"), """
                ["1"]
                Example = "$compat"
                """
            )
            return reg
        end
        # RegA has DepOnExample 1.0.0 and 1.1.0 with no compat on Example.
        # RegB only has 1.0.0 but its Compat.toml range "1" also covers 1.1.0,
        # which RegB does not contain.
        write_dep_registry("RegA", "d3e3f5c0-3c5e-4f1a-9a3e-1c2b3d4e5f60", ["1.0.0", "1.1.0"], nothing)
        regb = write_dep_registry("RegB", "f0e1d2c3-b4a5-4697-8879-6a5b4c3d2e1f", ["1.0.0"], "0.5.3")

        mktempdir() do tmp
            write(
                joinpath(tmp, "Project.toml"), """
                [deps]
                DepOnExample = "$dep_uuid"
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """
            )
            write(
                joinpath(tmp, "Manifest.toml"), """
                julia_version = "$VERSION"
                manifest_format = "2.0"

                [[deps.DepOnExample]]
                deps = ["Example"]
                git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
                uuid = "$dep_uuid"
                version = "1.1.0"

                [[deps.Example]]
                git-tree-sha1 = "46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.3"
                """
            )
            Pkg.activate(tmp)
            Pkg.Registry.add(Pkg.RegistrySpec[], io = devnull) # load reg before io capturing
            example_status_line() = let io = IOBuffer()
                Pkg.status(; outdated = true, io = io)
                lines = split(String(take!(io)), '\n')
                only(filter(contains("[7876af07] Example"), lines))
            end
            # DepOnExample 1.1.0 is not in RegB, so RegB's compat must not hold Example back
            line = example_status_line()
            @test occursin(r"Example\s*v0.5.3\s*\(<v[\d.]+\)", line)
            @test !occursin("DepOnExample", line)

            # Once RegB also contains 1.1.0 its compat does apply
            open(joinpath(regb, "D", "DepOnExample", "Versions.toml"), append = true) do io
                write(io, "\n[\"1.1.0\"]\ngit-tree-sha1 = \"46e44e869b4d90b96bd8ed1fdcf32244fddfb6cc\"\n")
            end
            line = example_status_line()
            @test occursin(r"Example\s*v0.5.3\s*\(<v[\d.]+\): DepOnExample", line)
        end
    end
end

@testset "Pkg.compat" begin
    # State changes
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            Pkg.activate(tempdir)
            Pkg.add("Example")
            iob = IOBuffer()
            Pkg.status(compat = true, io = iob)
            output = String(take!(iob))
            @test occursin(r"Compat `.+Project.toml`", output)
            @test occursin(r"\[7876af07\] *Example *none", output)
            @test occursin(r"julia *none", output)

            Pkg.compat("Example", "0.2,0.3")
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") == "0.2,0.3"
            Pkg.status(compat = true, io = iob)
            output = String(take!(iob))
            @test occursin(r"Compat `.+Project.toml`", output)
            @test occursin(r"\[7876af07\] *Example *0.2,0.3", output)
            @test occursin(r"julia *none", output)

            Pkg.compat("Example", nothing)
            Pkg.compat("julia", "1.8")
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") == nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "julia") == "1.8"
            Pkg.status(compat = true, io = iob)
            output = String(take!(iob))
            @test occursin(r"Compat `.+Project.toml`", output)
            @test occursin(r"\[7876af07\] *Example *none", output)
            @test occursin(r"julia *1.8", output)
        end
    end

    # Test compat --current functionality
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            Pkg.activate(path)
            # Add Example - this will automatically set a compat entry
            Pkg.add("Example")

            # Example now has a compat entry from the add operation
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") !== nothing

            # Use compat current to set compat entry for packages without compat entries (like Markdown)
            iob = IOBuffer()
            Pkg.compat("Markdown", current = true, io = iob)
            output = String(take!(iob))
            @test occursin("new entry set for Markdown based on its current version", output)

            Pkg.compat(current = true, io = iob)
            output = String(take!(iob))
            @test occursin("new entry set for julia based on its current version", output)

            # Check that all compat entries are set
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "julia") !== nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") !== nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Markdown") !== nothing

            # Test with no missing compat entries
            iob = IOBuffer()
            Pkg.compat(current = true, io = iob)
            output = String(take!(iob))
            @test occursin("no missing compat entries found. No changes made.", output)
        end
    end

    # Test compat current with multiple packages
    isolate(loaded_depot = true) do;
        mktempdir() do tempdir
            path = copy_test_package(tempdir, "SimplePackage")
            Pkg.activate(path)
            # Add both packages - this will automatically set compat entries for them
            Pkg.add("Example")
            Pkg.add("JSON")
            Pkg.compat("Example", nothing)
            Pkg.compat("JSON", nothing)

            # Both packages now have compat entries from the add operations
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") === nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "JSON") === nothing

            # Use compat current to set compat entries for packages without compat entries (like Markdown)
            iob = IOBuffer()
            Pkg.compat(current = true, io = iob)
            output = String(take!(iob))
            @test occursin("new entries set for", output)
            @test occursin("julia", output)
            @test occursin("Markdown", output)
            @test occursin("Example", output)
            @test occursin("JSON", output)

            # Check that all compat entries are set
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "julia") !== nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Example") !== nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "JSON") !== nothing
            @test Pkg.Operations.get_compat_str(Pkg.Types.Context().env.project, "Markdown") !== nothing
        end
    end
end

if :version in fieldnames(Base.PkgOrigin)
    @testset "sysimage functionality" begin
        old_sysimage_modules = copy(Base._sysimage_modules)
        old_pkgorigins = copy(Base.pkgorigins)
        try
            # Fake having a packages in the sysimage.
            json_pkgid = Base.PkgId(json_uuid, "JSON")
            push!(Base._sysimage_modules, json_pkgid)
            Base.pkgorigins[json_pkgid] = Base.PkgOrigin(nothing, nothing, v"0.20.1")
            isolate(loaded_depot = true) do
                Pkg.add("JSON"; io = devnull)
                Pkg.dependencies(json_uuid) do pkg
                    pkg.version == v"0.20.1"
                end
                io = IOBuffer()
                Pkg.status(; outdated = true, io = io)
                str = String(take!(io))
                @test occursin("⌅ [682c06a0] JSON v0.20.1", str)
                @test occursin("[sysimage]", str)

                @test_throws PkgError Pkg.add(name = "JSON", rev = "master"; io = devnull)
                @test_throws PkgError Pkg.develop("JSON"; io = devnull)

                Pkg.respect_sysimage_versions(false)
                Pkg.add("JSON"; io = devnull)
                Pkg.dependencies(json_uuid) do pkg
                    pkg.version != v"0.20.1"
                end
            end
        finally
            copy!(Base._sysimage_modules, old_sysimage_modules)
            copy!(Base.pkgorigins, old_pkgorigins)
            Pkg.respect_sysimage_versions(true)
        end
    end
end

@testset "status diff non-root" begin
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            Pkg.generate("A")
            git_init_and_commit(".")
            Pkg.activate("A")
            Pkg.add("Example")
            io = IOBuffer()
            Pkg.status(; io, diff = true)
            str = String(take!(io))
            @test occursin("+ Example", str)
        end
    end
end

@testset "status showing incompatible loaded deps" begin
    isolate(loaded_depot = true) do
        cmd = addenv(`$(Base.julia_cmd()) --color=no --startup-file=no -e "
            using Pkg
            Pkg.activate(temp=true)
            Pkg.add(Pkg.PackageSpec(name=\"Example\", version=v\"0.5.4\"))
            using Example
            Pkg.activate(temp=true)
            Pkg.add(Pkg.PackageSpec(name=\"Example\", version=v\"0.5.5\"))
            "`, "JULIA_DEPOT_PATH" => join(Base.DEPOT_PATH, Sys.iswindows() ? ";" : ":"))
        iob = IOBuffer()
        run(pipeline(cmd, stderr = iob, stdout = iob))
        out = String(take!(iob))
        @test occursin("[loaded: v0.5.4]", out)
    end
end

@testset "issue #1180: broken toml-files in HEAD" begin
    temp_pkg_dir() do dir
        cd(dir) do
            write("Project.toml", "[deps]\nExample = \n")
            git_init_and_commit(dir)
            write("Project.toml", "[deps]\nExample = \"7876af07-990d-54b4-ab0e-23690620f79a\"\n")
            Pkg.activate(dir)
            io = PipeBuffer() # IO is required to avoid short-circuit in Pkg.status
            @test_logs (:warn, r"could not read project from HEAD") Pkg.status(diff = true; io)
        end
    end
end

end # module
