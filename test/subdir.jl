module SubdirTests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, UUIDs, Test
using Pkg.REPLMode: pkgstr
using Pkg.Types: PackageSpec

using ..Utils

# Derived from RegistryTools' gitcmd.
function gitcmd(path::AbstractString)
    Cmd(["git", "-C", path, "-c", "user.name=RegistratorTests",
         "-c", "user.email=ci@juliacomputing.com"])
end

# Create a repository containing two packages in different
# subdirectories, `Package` and `Dep`, where the former depends on the
# latter. Return the tree hashes for the two packages.
function setup_packages_repository(dir)
    package_dir = joinpath(dir, "julia")
    mkpath(joinpath(package_dir, "src"))
    write(joinpath(package_dir, "Project.toml"), """
        name = "Package"
        uuid = "408b23ff-74ea-48c4-abc7-a671b41e2073"
        version = "1.0.0"

        [deps]
        Dep = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        """)
    write(joinpath(package_dir, "src", "Package.jl"), """
        module Package end
        """)

    dep_dir = joinpath(dir, "dependencies", "Dep")
    mkpath(joinpath(dep_dir, "src"))
    write(joinpath(dep_dir, "Project.toml"), """
        name = "Dep"
        uuid = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        version = "1.0.0"
        """)
    write(joinpath(dep_dir, "src", "Dep.jl"), """
        module Dep end
        """)

    git = gitcmd(dir)
    run(`$git init -q`)
    run(`$git add .`)
    run(`$git commit -qm 'Create repository.'`)
    package_tree_hash = readchomp(`$git rev-parse HEAD:julia`)
    dep_tree_hash = readchomp(`$git rev-parse HEAD:dependencies/Dep`)
    return package_tree_hash, dep_tree_hash
end

# Convert a path into a file URL.
function make_file_url(path)
    # Turn the slashes on Windows. In case the path starts with a
    # drive letter, an extra slash will be needed in the file URL.
    path = replace(path, "\\" => "/")
    if !startswith(path, "/")
        path = "/" * path
    end
    return "file://$(path)"
end

# Create a registry with the two packages `Package` and `Dep`.
function setup_registry(dir, packages_dir_url, package_tree_hash, dep_tree_hash)
    package_path = joinpath(dir, "P", "Package")
    dep_path = joinpath(dir, "D", "Dep")
    mkpath(package_path)
    mkpath(dep_path)
    write(joinpath(dir, "Registry.toml"), """
        name = "Registry"
        uuid = "cade28e2-3b52-4f58-aeba-0b1386f9894b"
        repo = "https://github.com"
        [packages]
        408b23ff-74ea-48c4-abc7-a671b41e2073 = { name = "Package", path = "P/Package" }
        d43cb7ef-9818-40d3-bb27-28fb4aa46cc5 = { name = "Dep", path = "D/Dep" }
        """)
    write(joinpath(package_path, "Package.toml"), """
        name = "Package"
        uuid = "408b23ff-74ea-48c4-abc7-a671b41e2073"
        repo = "$(packages_dir_url)"
        subdir = "julia"
        """)
    write(joinpath(package_path, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "$(package_tree_hash)"
        """)
    write(joinpath(package_path, "Deps.toml"), """
        [1]
        Dep = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        """)

    write(joinpath(dep_path, "Package.toml"), """
        name = "Dep"
        uuid = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        repo = "$(packages_dir_url)"
        subdir = "dependencies/Dep"
        """)
    write(joinpath(dep_path, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "$(dep_tree_hash)"
        """)

    git = gitcmd(dir)
    run(`$git init -q`)
    run(`$git add .`)
    run(`$git commit -qm 'Create repository.'`)
end

@testset "subdir" begin
    temp_pkg_dir() do depot
        # Apparently the working directory can turn out to be a
        # removed directory when getting here, which doesn't go well
        # with the `pkg"add ..."` calls. Just set it to something that
        # exists.
        cd(@__DIR__)
        # Setup a repository with two packages and a registry where
        # these packages are registered.
        packages_dir = mktempdir()
        registry_dir = mktempdir()
        packages_dir_url = make_file_url(packages_dir)
        tree_hashes = setup_packages_repository(packages_dir)
        setup_registry(registry_dir, packages_dir_url, tree_hashes...)
        pkgstr("registry add $(registry_dir)")
        dep = (name="Dep", uuid=UUID("d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"))

        # Ordinary add from registry.
        pkg"add Package"
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkg"add Dep"
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add version from registry.
        pkg"add Package@1.0.0"
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkg"add Dep@1.0.0"
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add branch from registry.
        pkg"add Package#master"
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkg"add Dep#master"
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Develop from registry.
        pkg"develop Package"
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkg"develop Dep"
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from path.
        Pkg.add(Pkg.PackageSpec(path=packages_dir, subdir="julia"))
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        Pkg.add(Pkg.PackageSpec(path=packages_dir, subdir="dependencies/Dep"))
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from path, REPL subdir syntax.
        pkgstr("add $(packages_dir):julia")
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkgstr("add $(packages_dir):dependencies/Dep")
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from path at branch.
        Pkg.add(Pkg.PackageSpec(path=packages_dir, subdir="julia", rev="master"))
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        Pkg.add(Pkg.PackageSpec(path=packages_dir, subdir="dependencies/Dep", rev="master"))
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from path at branch, REPL subdir syntax
        @show "add $(packages_dir):julia#master"
        pkgstr("add $(packages_dir):julia#master")
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkgstr("add $(packages_dir):dependencies/Dep#master")
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Develop from path.
        Pkg.develop(Pkg.PackageSpec(path=packages_dir, subdir="julia"))
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        Pkg.develop(Pkg.PackageSpec(path=packages_dir, subdir="dependencies/Dep"))
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Develop from path, REPL subdir syntax.
        pkgstr("develop $(packages_dir):julia")
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkgstr("develop $(packages_dir):dependencies/Dep")
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from url.
        Pkg.add(Pkg.PackageSpec(url=packages_dir_url, subdir="julia"))
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        Pkg.add(Pkg.PackageSpec(url=packages_dir_url, subdir="dependencies/Dep"))
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from url, REPL subdir syntax.
        pkgstr("add $(packages_dir_url):julia")
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkgstr("add $(packages_dir_url):dependencies/Dep")
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from url at branch.
        Pkg.add(Pkg.PackageSpec(url=packages_dir_url, subdir="julia",
                                rev="master"))
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        Pkg.add(Pkg.PackageSpec(url=packages_dir_url, subdir="dependencies/Dep", rev="master"))
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Add from url at branch, REPL subdir syntax.
        pkgstr("add $(packages_dir_url):julia#master")
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkgstr("add $(packages_dir_url):dependencies/Dep#master")
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Develop from url.
        Pkg.develop(Pkg.PackageSpec(url=packages_dir_url, subdir="julia"))
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        Pkg.develop(Pkg.PackageSpec(url=packages_dir_url, subdir="dependencies/Dep"))
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"

        # Develop from url, REPL subdir syntax.
        pkgstr("develop $(packages_dir_url):julia")
        @test isinstalled("Package")
        @test !isinstalled("Dep")
        @test isinstalled(dep)
        pkg"rm Package"

        pkgstr("develop $(packages_dir_url):dependencies/Dep")
        @test !isinstalled("Package")
        @test isinstalled("Dep")
        pkg"rm Dep"
    end
end

end # module
