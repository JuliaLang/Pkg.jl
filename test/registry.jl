module RegistryTests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, UUIDs, LibGit2, Test
using Pkg: depots1
using Pkg.REPLMode: pkgstr
using Pkg.Types: PkgError, manifest_info, PackageSpec, EnvCache

using ..Utils


function setup_test_registries(dir = pwd())
    # Set up two registries with the same name, with different uuid
    pkg_uuids = ["c5f1542f-b8aa-45da-ab42-05303d706c66", "d7897d3a-8e65-4b65-bdc8-28ce4e859565"]
    reg_uuids = ["e9fceed0-5623-4384-aff0-6db4c442647a", "a8e078ad-b4bd-4e09-a52f-c464826eef9d"]
    for i in 1:2
        regpath = joinpath(dir, "RegistryFoo$(i)")
        mkpath(joinpath(regpath, "Example"))
        write(joinpath(regpath, "Registry.toml"), """
            name = "RegistryFoo"
            uuid = "$(reg_uuids[i])"
            repo = "https://github.com"
            [packages]
            $(pkg_uuids[i]) = { name = "Example$(i)", path = "Example" }
            """)
        write(joinpath(regpath, "Example", "Package.toml"), """
            name = "Example$(i)"
            uuid = "$(pkg_uuids[i])"
            repo = "https://github.com/JuliaLang/Example.jl.git"
            """)
        write(joinpath(regpath, "Example", "Versions.toml"), """
            ["0.5.1"]
            git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
            """)
        write(joinpath(regpath, "Example", "Deps.toml"), """
            ["0.5"]
            julia = "0.6-1.0"
            """)
        write(joinpath(regpath, "Example", "Compat.toml"), """
            ["0.5"]
            julia = "0.6-1.0"
            """)
        git_init_and_commit(regpath)
    end
end

function test_installed(registries)
    @test setdiff(
        UUID[r.uuid for r in registries],
        UUID[r.uuid for r in Pkg.Registry.reachable_registries()]
        ) == UUID[]
end

function is_pkg_available(pkg::PackageSpec)
    uuids = Set{UUID}()
    for registry in Pkg.Registry.reachable_registries()
        union!(uuids, keys(registry))
    end
    return in(pkg.uuid, uuids)
end

function with_depot2(f)
    Base.DEPOT_PATH[1:2] .= Base.DEPOT_PATH[2:-1:1]
    f()
    Base.DEPOT_PATH[1:2] .= Base.DEPOT_PATH[2:-1:1]
end

@testset "registries" begin
    temp_pkg_dir() do depot; mktempdir() do depot2
        insert!(Base.DEPOT_PATH, 2, depot2)
        # set up registries
        regdir = mktempdir()
        setup_test_registries(regdir)
        general_url = Pkg.Registry.DEFAULT_REGISTRIES[1].url
        general_path = Pkg.Registry.DEFAULT_REGISTRIES[1].path
        general_linked = Pkg.Registry.DEFAULT_REGISTRIES[1].linked
        General = RegistrySpec(name = "General", uuid = "23338594-aafe-5451-b93e-139f81909106",
            url = general_url, path = general_path, linked = general_linked)
        Foo1 = RegistrySpec(name = "RegistryFoo", uuid = "e9fceed0-5623-4384-aff0-6db4c442647a",
            url = joinpath(regdir, "RegistryFoo1"))
        Foo2 = RegistrySpec(name = "RegistryFoo", uuid = "a8e078ad-b4bd-4e09-a52f-c464826eef9d",
            url = joinpath(regdir, "RegistryFoo2"))

        # Packages in registries
        Example  = PackageSpec(name = "Example",  uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
        Example1 = PackageSpec(name = "Example1", uuid = UUID("c5f1542f-b8aa-45da-ab42-05303d706c66"))
        Example2 = PackageSpec(name = "Example2", uuid = UUID("d7897d3a-8e65-4b65-bdc8-28ce4e859565"))

        # Add General registry
        ## Pkg REPL
        for reg in ("General",
                    "23338594-aafe-5451-b93e-139f81909106",
                    "General=23338594-aafe-5451-b93e-139f81909106")
            pkgstr("registry add $(reg)")
            test_installed([General])

            pkgstr("registry up $(reg)")
            test_installed([General])
            pkgstr("registry rm $(reg)")
            test_installed([])
        end

        ## Pkg REPL without argument
        pkgstr("registry add")
        test_installed([General])
        pkgstr("registry rm General")
        test_installed([])

        ## Registry API
        for reg in ("General",
                    RegistrySpec("General"),
                    RegistrySpec(name = "General"),
                    RegistrySpec(name = "General", path = general_path),
                    RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"),
                    RegistrySpec(name = "General", uuid = "23338594-aafe-5451-b93e-139f81909106"))
            Pkg.Registry.add(reg)
            test_installed([General])
            @test is_pkg_available(Example)
            Pkg.Registry.update(reg)
            test_installed([General])
            Pkg.Registry.rm(reg)
            test_installed([])
            @test !is_pkg_available(Example)
        end

        # Add registry from URL/local path.
        pkgstr("registry add $(Foo1.url)")
        test_installed([Foo1])
        @test is_pkg_available(Example1)
        @test !is_pkg_available(Example2)
        with_depot2(() -> pkgstr("registry add $(Foo2.url)"))
        test_installed([Foo1, Foo2])
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)

        # reset installed registries
        rm.(joinpath.(Base.DEPOT_PATH[1:2], "registries"); force=true, recursive=true)

        Registry.add(RegistrySpec(url = Foo1.url))
        test_installed([Foo1])
        @test is_pkg_available(Example1)
        @test !is_pkg_available(Example2)
        with_depot2(() -> Registry.add(RegistrySpec(url = Foo2.url)))
        test_installed([Foo1, Foo2])
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)


        pkgstr("registry up $(Foo1.uuid)")
        pkgstr("registry update $(Foo1.name)=$(Foo1.uuid)")
        Registry.update(RegistrySpec(uuid = Foo1.uuid))
        Registry.update(RegistrySpec(name = Foo1.name, uuid = Foo1.uuid))

        test_installed([Foo1, Foo2])
        pkgstr("registry rm $(Foo1.uuid)")
        test_installed([Foo2])
        @test !is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        Registry.add(RegistrySpec(url = Foo1.url))
        test_installed([Foo1, Foo2])
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        pkgstr("registry rm $(Foo1.name)=$(Foo1.uuid)")
        test_installed([Foo2])
        @test !is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        with_depot2() do
            pkgstr("registry rm $(Foo2.name)")
        end
        test_installed([])
        @test !is_pkg_available(Example1)
        @test !is_pkg_available(Example2)

        Registry.add(RegistrySpec(url = Foo1.url))
        with_depot2(() -> Registry.add(RegistrySpec(url = Foo2.url)))
        test_installed([Foo1, Foo2])
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        Registry.rm(RegistrySpec(uuid = Foo1.uuid))
        test_installed([Foo2])
        @test !is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        Registry.add(RegistrySpec(url = Foo1.url))
        test_installed([Foo1, Foo2])
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        Registry.rm(RegistrySpec(name = Foo1.name, uuid = Foo1.uuid))
        test_installed([Foo2])
        @test !is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        with_depot2() do
            Registry.rm(RegistrySpec(Foo2.name))
        end
        test_installed([])
        @test !is_pkg_available(Example1)
        @test !is_pkg_available(Example2)

        # multiple registries on the same time
        pkgstr("registry add General $(Foo1.url)")
        with_depot2(() -> pkgstr("registry add $(Foo2.url)"))
        test_installed([General, Foo1, Foo2])
        @test is_pkg_available(Example)
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        pkgstr("registry up General $(Foo1.uuid) $(Foo2.name)=$(Foo2.uuid)")
        pkgstr("registry rm General $(Foo1.uuid)")
        with_depot2() do
            pkgstr("registry rm General $(Foo2.name)=$(Foo2.uuid)")
        end
        test_installed([])
        @test !is_pkg_available(Example)
        @test !is_pkg_available(Example1)
        @test !is_pkg_available(Example2)

        Registry.add([RegistrySpec("General"),
                      RegistrySpec(url = Foo1.url)])
        with_depot2(() -> Registry.add([RegistrySpec(url = Foo2.url)]))
        test_installed([General, Foo1, Foo2])
        @test is_pkg_available(Example)
        @test is_pkg_available(Example1)
        @test is_pkg_available(Example2)
        Registry.update([RegistrySpec("General"),
                         RegistrySpec(uuid = Foo1.uuid),
                         RegistrySpec(name = Foo2.name, uuid = Foo2.uuid)])
        Registry.rm([RegistrySpec("General"),
                     RegistrySpec(uuid = Foo1.uuid),
                     ])
        with_depot2() do
            Registry.rm(RegistrySpec(name = Foo2.name, uuid = Foo2.uuid))
        end
        test_installed([])
        @test !is_pkg_available(Example)
        @test !is_pkg_available(Example1)
        @test !is_pkg_available(Example2)

        # Trying to add a registry with the same name as existing one
        pkgstr("registry add $(Foo1.url)")
        @test_throws PkgError pkgstr("registry add $(Foo2.url)")
        @test_throws PkgError Registry.add([RegistrySpec(url = Foo2.url)])

    end end

    # issue #711
    temp_pkg_dir() do depot; mktempdir() do depot2
        insert!(Base.DEPOT_PATH, 2, depot2)
        Registry.add("General")
        with_depot2(() -> Registry.add("General"))
        # This add should not error because depot/Example and depot2/Example have the same uuid
        Pkg.add("Example")
        @test isinstalled((name = "Example", uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")))
    end end

    # only clone default registry if there are no registries installed at all
    temp_pkg_dir() do depot1; mktempdir() do depot2
        append!(empty!(DEPOT_PATH), [depot1, depot2])
        @test length(Pkg.Registry.reachable_registries()) == 0
        Pkg.add("Example")
        @test length(Pkg.Registry.reachable_registries()) == 1
        Pkg.rm("Example")
        DEPOT_PATH[1:2] .= DEPOT_PATH[2:-1:1]
        Pkg.add("Example") # should not trigger a clone of default registries
        @test length(Pkg.Registry.reachable_registries()) == 1
    end end

    @testset "yanking" begin
        uuid = Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a") # Example
        # Tests that Example@0.5.1 does not get installed
        temp_pkg_dir() do env
            Pkg.Registry.add(RegistrySpec(url = "https://github.com/JuliaRegistries/Test"))
            Pkg.add("Example")
            @test manifest_info(EnvCache().manifest, uuid).version == v"0.5.0"
            Pkg.update() # should not update Example
            @test manifest_info(EnvCache().manifest, uuid).version == v"0.5.0"
            @test_throws Pkg.Resolve.ResolverError Pkg.add(PackageSpec(name="Example", version=v"0.5.1"))
            Pkg.rm("Example")
            Pkg.add("JSON") # depends on Example
            @test manifest_info(EnvCache().manifest, uuid).version == v"0.5.0"
            Pkg.update()
            @test manifest_info(EnvCache().manifest, uuid).version == v"0.5.0"
        end
        # Test that Example@0.5.1 can be obtained from an existing manifest
        temp_pkg_dir() do env
            Pkg.Registry.add(RegistrySpec(url = "https://github.com/JuliaRegistries/Test"))
            write(joinpath(env, "Project.toml"),"""
                [deps]
                Example = "7876af07-990d-54b4-ab0e-23690620f79a"
                """)
            write(joinpath(env, "Manifest.toml"),"""
                [[Example]]
                git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.1"
                """)
            Pkg.activate(env)
            Pkg.instantiate()
            @test manifest_info(EnvCache().manifest, uuid).version == v"0.5.1"
        end
        temp_pkg_dir() do env
            Pkg.Registry.add(RegistrySpec(url = "https://github.com/JuliaRegistries/Test"))
            write(joinpath(env, "Project.toml"),"""
                [deps]
                JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                """)
            write(joinpath(env, "Manifest.toml"),"""
                [[Example]]
                git-tree-sha1 = "8eb7b4d4ca487caade9ba3e85932e28ce6d6e1f8"
                uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
                version = "0.5.1"

                [[JSON]]
                deps = ["Example"]
                git-tree-sha1 = "1f7a25b53ec67f5e9422f1f551ee216503f4a0fa"
                uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
                version = "0.20.0"
                """)
            Pkg.activate(env)
            Pkg.instantiate()
            @test manifest_info(EnvCache().manifest, uuid).version == v"0.5.1"
        end
    end
end

if Pkg.Registry.registry_use_pkg_server()
@testset "compressed registry" begin
    for unpack in (true, nothing)
        withenv("JULIA_PKG_UNPACK_REGISTRY" => unpack) do
            temp_pkg_dir(;linked_reg=false) do depot
                # These get restored by temp_pkg_dir
                Pkg.Registry.DEFAULT_REGISTRIES[1].path = nothing
                Pkg.Registry.DEFAULT_REGISTRIES[1].url = "https://github.com/JuliaRegistries/General.git"

                # This should not uncompress the registry
                Registry.add(RegistrySpec(uuid = UUID("23338594-aafe-5451-b93e-139f81909106")))
                @test isfile(joinpath(DEPOT_PATH[1], "registries", "General.tar.gz")) != something(unpack, false)
                Pkg.add("Example")

                # Write some bad git-tree-sha1 here so that Pkg.update will have to update the registry
                if unpack == true
                    write(joinpath(DEPOT_PATH[1], "registries", "General", ".tree_info.toml"),
                        """
                        git-tree-sha1 = "179182faa6a80b3cf24445e6f55c954938d57941"
                        """)
                else
                    write(joinpath(DEPOT_PATH[1], "registries", "General.toml"),
                        """
                        git-tree-sha1 = "179182faa6a80b3cf24445e6f55c954938d57941"
                        uuid = "23338594-aafe-5451-b93e-139f81909106"
                        path = "General.tar.gz"
                        """)
                end
                Pkg.update()
                Pkg.Registry.rm(RegistrySpec(name = "General"))
                @test isempty(readdir(joinpath(DEPOT_PATH[1], "registries")))
            end
        end
    end
end
end

end # module
