using LibGit2

const JULIA_REPO_URL = "https://github.com/JuliaLang/julia.git"
const JULIA_REPO_DIR = "julia"
const PKG_VERSION_PATH = "stdlib/Pkg.version"
const PKG_REPO_URL = "https://github.com/JuliaLang/Pkg.jl.git"
const PKG_REPO_DIR = "Pkg.jl"

function checkout_or_update_repo(url, dir)
    if isdir(dir)
        println("Updating existing repository: $dir")
        repo = LibGit2.GitRepo(dir)
        LibGit2.fetch(repo)
    else
        println("Cloning repository: $url")
        LibGit2.clone(url, dir)
    end
    return
end

function get_tags(repo)
    refs = LibGit2.ref_list(repo)
    tags = filter(ref -> startswith(ref, "refs/tags/"), refs)
    return sort!(replace.(tags, "refs/tags/" => ""))
end

function is_stable_v1_release(tag)
    return occursin(r"^v\d+\.\d+\.\d+$", tag) && VersionNumber(tag) >= v"1.0.0"
end

function extract_pkg_sha1(text::AbstractString)
    m = match(r"PKG_SHA1\s*=\s*([a-f0-9]{40})", text)
    return m !== nothing ? m[1] : nothing
end

function get_commit_hash_for_pkg_version(repo, tag)
    return try
        tag_ref = LibGit2.GitReference(repo, "refs/tags/" * tag)
        LibGit2.checkout!(repo, string(LibGit2.GitHash(LibGit2.peel(tag_ref))))
        version_file = joinpath(JULIA_REPO_DIR, PKG_VERSION_PATH)
        if isfile(version_file)
            return extract_pkg_sha1(readchomp(version_file))
        else
            println("Warning: Pkg.version file missing for tag $tag")
            return nothing
        end
    catch
        println("Error processing tag $tag")
        rethrow()
    end
end

tempdir = mktempdir()
cd(tempdir) do
    # Update Julia repo
    checkout_or_update_repo(JULIA_REPO_URL, JULIA_REPO_DIR)
    julia_repo = LibGit2.GitRepo(JULIA_REPO_DIR)

    # Get Julia tags, filtering only stable releases
    julia_tags = filter(is_stable_v1_release, get_tags(julia_repo))
    version_commit_map = Dict{String, String}()

    for tag in julia_tags
        println("Processing Julia tag: $tag")
        commit_hash = get_commit_hash_for_pkg_version(julia_repo, tag)
        if commit_hash !== nothing
            version_commit_map[tag] = commit_hash
        end
    end

    # Update Pkg.jl repo
    checkout_or_update_repo(PKG_REPO_URL, PKG_REPO_DIR)
    pkg_repo = LibGit2.GitRepo(PKG_REPO_DIR)

    # Get existing tags in Pkg.jl
    pkg_tags = Set(get_tags(pkg_repo))

    # Filter out versions that already exist
    missing_versions = filter(v -> v ∉ pkg_tags, collect(keys(version_commit_map)))

    # Sort versions numerically
    sort!(missing_versions, by = VersionNumber)

    # Generate `git tag` commands
    println("\nGit tag commands for missing Pkg.jl versions:")
    for version in missing_versions
        commit = version_commit_map[version]
        println("git tag $version $commit")
    end
end
