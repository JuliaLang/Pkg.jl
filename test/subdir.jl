module SubdirTests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, UUIDs, Test
using Pkg.REPLMode: pkgstr
using Pkg.Types: PackageSpec
using Pkg: stdout_f, stderr_f

using ..Utils

# Derived from RegistryTools' gitcmd.
function gitcmd(path::AbstractString)
    return Cmd(
        [
            "git", "-C", path, "-c", "user.name=RegistratorTests",
            "-c", "user.email=ci@juliacomputing.com",
        ]
    )
end

# Create a repository containing two packages in different
# subdirectories, `Package` and `Dep`, where the former depends on the
# latter. Return the tree hashes for the two packages.
function setup_packages_repository(dir)
    package_dir = joinpath(dir, "julia")
    mkpath(joinpath(package_dir, "src"))
    write(
        joinpath(package_dir, "Project.toml"), """
        name = "Package"
        uuid = "408b23ff-74ea-48c4-abc7-a671b41e2073"
        version = "1.0.0"

        [deps]
        Dep = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        """
    )
    write(
        joinpath(package_dir, "src", "Package.jl"), """
        module Package end
        """
    )

    dep_dir = joinpath(dir, "dependencies", "Dep")
    mkpath(joinpath(dep_dir, "src"))
    write(
        joinpath(dep_dir, "Project.toml"), """
        name = "Dep"
        uuid = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        version = "1.0.0"
        """
    )
    write(
        joinpath(dep_dir, "src", "Dep.jl"), """
        module Dep end
        """
    )

    git = gitcmd(dir)
    run(pipeline(`$git init -q`, stdout = stdout_f(), stderr = stderr_f()))
    run(pipeline(`$git add .`, stdout = stdout_f(), stderr = stderr_f()))
    run(pipeline(`$git commit -qm 'Create repository.'`, stdout = stdout_f(), stderr = stderr_f()))
    fix_default_branch(; dir)
    package_tree_hash = readchomp(`$git rev-parse HEAD:julia`)
    dep_tree_hash = readchomp(`$git rev-parse HEAD:dependencies/Dep`)
    return package_tree_hash, dep_tree_hash
end

const DEP = (name = "Dep", uuid = UUID("d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"))

# Commit a change to `Dep` and return its new tree hash.
function update_dep(dir)
    open(io -> println(io, "# update"), joinpath(dir, "dependencies", "Dep", "src", "Dep.jl"), "a")
    git = gitcmd(dir)
    run(pipeline(`$git commit -qam 'Update Dep.'`, stdout = stdout_f(), stderr = stderr_f()))
    return readchomp(`$git rev-parse HEAD:dependencies/Dep`)
end

# Replace the history of `dir` so that none of its earlier trees are reachable.
function rewrite_history(dir)
    open(io -> println(io, "# rewritten"), joinpath(dir, "dependencies", "Dep", "src", "Dep.jl"), "a")
    git = gitcmd(dir)
    for cmd in (
            `$git checkout -q --orphan rewritten`, `$git add -A`, `$git commit -qm 'Rewrite history.'`,
            `$git branch -q -D master`, `$git branch -m master`,
            `$git reflog expire --expire=now --all`, `$git gc -q --prune=now`,
        )
        run(pipeline(cmd, stdout = stdout_f(), stderr = stderr_f()))
    end
    return nothing
end

dep_spec(url; kwargs...) = Pkg.PackageSpec(; url, subdir = "dependencies/Dep", kwargs...)


# Create a registry with the two packages `Package` and `Dep`.
function setup_registry(dir, packages_dir_url, package_tree_hash, dep_tree_hash)
    package_path = joinpath(dir, "P", "Package")
    dep_path = joinpath(dir, "D", "Dep")
    mkpath(package_path)
    mkpath(dep_path)
    write(
        joinpath(dir, "Registry.toml"), """
        name = "Registry"
        uuid = "cade28e2-3b52-4f58-aeba-0b1386f9894b"
        repo = "https://github.com"
        [packages]
        408b23ff-74ea-48c4-abc7-a671b41e2073 = { name = "Package", path = "P/Package" }
        d43cb7ef-9818-40d3-bb27-28fb4aa46cc5 = { name = "Dep", path = "D/Dep" }
        """
    )
    write(
        joinpath(package_path, "Package.toml"), """
        name = "Package"
        uuid = "408b23ff-74ea-48c4-abc7-a671b41e2073"
        repo = "$(packages_dir_url)"
        subdir = "julia"
        """
    )
    write(
        joinpath(package_path, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "$(package_tree_hash)"
        """
    )
    write(
        joinpath(package_path, "Deps.toml"), """
        [1]
        Dep = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        """
    )

    write(
        joinpath(dep_path, "Package.toml"), """
        name = "Dep"
        uuid = "d43cb7ef-9818-40d3-bb27-28fb4aa46cc5"
        repo = "$(packages_dir_url)"
        subdir = "dependencies/Dep"
        """
    )
    write(
        joinpath(dep_path, "Versions.toml"), """
        ["1.0.0"]
        git-tree-sha1 = "$(dep_tree_hash)"
        """
    )

    git = gitcmd(dir)
    run(pipeline(`$git init -q`, stdout = stdout_f(), stderr = stderr_f()))
    run(pipeline(`$git add .`, stdout = stdout_f(), stderr = stderr_f()))
    run(pipeline(`$git commit -qm 'Create repository.'`, stdout = stdout_f(), stderr = stderr_f()))
    return fix_default_branch(; dir)
end

# Some of our tests assume that the default branch name is `master`.
# However, if the user has `init.defaultBranch` set in their global Git config, `git init`
# might create repositories with a default branch name that is not equal to `master`.
#
# Therefore, after we make the first commit to a new repository, we check and see what the
# branch name is. If the branch name is `master`, we do nothing. If the branch name is not
# `master`, then we run the following commands:
# 1. `git branch -f master`
# 2. `git checkout master`
# 3. `git branch -D $(old_branch_name)`
#
# Note: this requires Git 1.2.0+ or Git 2.0.0+
#
# Note: we cannot use `git init -b`, because that requires Git 2.28.0+, and we want to
# support older versions of Git. Therefore, we instead use `git branch -f` and `git branch -D`,
# which only require Git 1.2.0+ or Git 2.0.0+.
function fix_default_branch(; dir::String, new_branch_name::String = "master")
    old_branch_name = _current_branch_name(; dir)
    git = gitcmd(dir)
    if old_branch_name != new_branch_name
        # Note: the `branch -f` flag is supported in Git 1.2.0+ and Git 2.0.0+
        # Note: the `branch -D` flag is supported in Git 1.2.0+ and Git 2.0.0+
        run(`$(git) branch -f $(new_branch_name)`)
        run(`$(git) checkout $(new_branch_name)`)
        run(`$(git) branch -D $(old_branch_name)`)
    end
    # A sanity check to make sure that the branch rename worked successfully.
    @test _current_branch_name(; dir) == new_branch_name
    return nothing
end
function _current_branch_name(; dir::String)
    git = gitcmd(dir)
    return strip(read(`$(git) rev-parse --abbrev-ref HEAD`, String))
end

@testset "subdir" begin
    temp_pkg_dir() do depot
        # Apparently the working directory can turn out to be a
        # removed directory when getting here, which doesn't go well
        # with the `pkg"add ..."` calls. Just set it to something that
        # exists.
        cd(@__DIR__) do
            # Setup a repository with two packages and a registry where
            # these packages are registered.
            packages_dir = mktempdir()
            registry_dir = mktempdir()
            packages_dir_url = make_file_url(packages_dir)
            tree_hashes = setup_packages_repository(packages_dir)
            setup_registry(registry_dir, packages_dir_url, tree_hashes...)
            pkgstr("registry add $(registry_dir)")
            dep = DEP

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

            # Test that adding a second time doesn't error (#3391)
            pkg"add Package#master"
            @test isinstalled("Package")
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

            # Test developing twice (#3391)
            pkg"develop Package"
            @test isinstalled("Package")
            pkg"rm Package"

            pkg"develop Dep"
            @test !isinstalled("Package")
            @test isinstalled("Dep")
            pkg"rm Dep"

            # Add from path.
            Pkg.add(Pkg.PackageSpec(path = packages_dir, subdir = "julia"))
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            Pkg.add(Pkg.PackageSpec(path = packages_dir, subdir = "dependencies/Dep"))
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
            pkg"dev Dep" # 4269
            @test isinstalled("Dep")
            pkg"rm Dep"

            # Add from path at branch.
            Pkg.add(Pkg.PackageSpec(path = packages_dir, subdir = "julia", rev = "master"))
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            Pkg.add(Pkg.PackageSpec(path = packages_dir, subdir = "dependencies/Dep", rev = "master"))
            @test !isinstalled("Package")
            @test isinstalled("Dep")
            pkg"rm Dep"

            # Add from path at branch, REPL subdir syntax
            pkgstr("add $(packages_dir)#master:julia")
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            pkgstr("add $(packages_dir)#master:dependencies/Dep")
            @test !isinstalled("Package")
            @test isinstalled("Dep")
            pkg"rm Dep"

            # Develop from path.
            Pkg.develop(Pkg.PackageSpec(path = packages_dir, subdir = "julia"))
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            Pkg.develop(Pkg.PackageSpec(path = packages_dir, subdir = "dependencies/Dep"))
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
            Pkg.add(Pkg.PackageSpec(url = packages_dir_url, subdir = "julia"))
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            Pkg.add(Pkg.PackageSpec(url = packages_dir_url, subdir = "dependencies/Dep"))
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
            Pkg.add(
                Pkg.PackageSpec(
                    url = packages_dir_url, subdir = "julia",
                    rev = "master"
                )
            )
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            Pkg.add(Pkg.PackageSpec(url = packages_dir_url, subdir = "dependencies/Dep", rev = "master"))
            @test !isinstalled("Package")
            @test isinstalled("Dep")
            pkg"rm Dep"

            # Add from url at branch, REPL subdir syntax.
            pkgstr("add $(packages_dir_url)#master:julia")
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            pkgstr("add $(packages_dir_url)#master:dependencies/Dep")
            @test !isinstalled("Package")
            @test isinstalled("Dep")
            pkg"rm Dep"

            # Develop from url.
            Pkg.develop(Pkg.PackageSpec(url = packages_dir_url, subdir = "julia"))
            @test isinstalled("Package")
            @test !isinstalled("Dep")
            @test isinstalled(dep)
            pkg"rm Package"

            Pkg.develop(Pkg.PackageSpec(url = packages_dir_url, subdir = "dependencies/Dep"))
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
        end #cd
    end
end

@testset "resolve with a subdir package missing from the depot (#4851)" begin
    temp_pkg_dir() do project
        cd(@__DIR__) do
            packages_dir = mktempdir()
            packages_dir_url = make_file_url(packages_dir)
            _, dep_tree_hash = setup_packages_repository(packages_dir)

            Pkg.add(dep_spec(packages_dir_url))
            @test isinstalled("Dep")
            @test Pkg.dependencies()[DEP.uuid].tree_hash == dep_tree_hash

            rm(joinpath(DEPOT_PATH[1], "packages", "Dep"); recursive = true)
            @test !isinstalled("Dep")
            Pkg.resolve()
            @test isinstalled("Dep")

            update_dep(packages_dir)
            rm(joinpath(DEPOT_PATH[1], "packages", "Dep"); recursive = true)
            rm(Pkg.Types.add_repo_cache_path(packages_dir_url); recursive = true)
            @test !isinstalled("Dep")

            Pkg.resolve()
            @test isinstalled("Dep")
            @test Pkg.dependencies()[DEP.uuid].tree_hash == dep_tree_hash
        end
    end
end

@testset "pin, and an unreachable tree, of a subdir package missing from the depot" begin
    temp_pkg_dir() do project
        cd(@__DIR__) do
            packages_dir = mktempdir()
            packages_dir_url = make_file_url(packages_dir)
            setup_packages_repository(packages_dir)
            Pkg.add(dep_spec(packages_dir_url))

            rm(joinpath(DEPOT_PATH[1], "packages", "Dep"); recursive = true)
            Pkg.pin("Dep")
            @test isinstalled("Dep")
            Pkg.free("Dep")

            rewrite_history(packages_dir)
            rm(joinpath(DEPOT_PATH[1], "packages", "Dep"); recursive = true)
            rm(Pkg.Types.add_repo_cache_path(packages_dir_url); recursive = true)
            @test_throws "Did not find tree" Pkg.resolve()
            # Updating the package resolves it again from its tracked rev, as the error suggests.
            Pkg.update("Dep")
            @test isinstalled("Dep")
        end
    end
end

@testset "rev lookups of a subdir package: tree rev, update, pinned re-add" begin
    temp_pkg_dir() do project
        cd(@__DIR__) do
            packages_dir = mktempdir()
            packages_dir_url = make_file_url(packages_dir)
            _, dep_tree_hash = setup_packages_repository(packages_dir)

            root_tree_hash = readchomp(`$(gitcmd(packages_dir)) rev-parse 'HEAD^{tree}'`)
            Pkg.add(dep_spec(packages_dir_url; rev = root_tree_hash))
            @test Pkg.dependencies()[DEP.uuid].tree_hash == dep_tree_hash
            pkg"rm Dep"

            Pkg.add(dep_spec(packages_dir_url))
            new_tree_hash = update_dep(packages_dir)
            Pkg.update()
            @test Pkg.dependencies()[DEP.uuid].tree_hash == new_tree_hash

            Pkg.pin("Dep")
            update_dep(packages_dir)
            Pkg.add(dep_spec(packages_dir_url))
            @test Pkg.dependencies()[DEP.uuid].tree_hash == new_tree_hash
        end
    end
end

end # module
