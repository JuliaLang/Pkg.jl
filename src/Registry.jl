module Registry

import UUIDs
import LibGit2
import ..TOML, ..Operations, ..API
using ..Types

function write_toml(f::Function, names::String...)
    path = joinpath(names...) * ".toml"
    mkpath(dirname(path))
    open(path, "w") do io
        f(io)
    end
end

function create_registry(path; repo::Union{Nothing, String} = nothing, uuid = UUIDs.uuid1(), description = nothing)
    isdir(path) && error("$(abspath(path)) already exists")
    mkpath(path)
    write_mainfile(path, uuid, repo, description)
    LibGit2.with(LibGit2.init(path)) do repo
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "initial commit for registry $(basename(path))")
    end
    return
end

function write_mainfile(path, uuid, repo, description)
    d = Dict{String, Any}()
    d["name"] = basename(path)
    d["uuid"] = string(uuid)
    if repo !== nothing
        d["repo"]= repo
    end
    if description !== nothing
        d["description"] = description
    end
    write_mainfile(path, d)
end

function write_mainfile(path::String, data::Dict)
    open(joinpath(path, "Registry.toml"), "w") do io
        println(io, "name = ", repr(data["name"]))
        println(io, "uuid = ", repr(data["uuid"]))
        if haskey(data, "repo")
            println(io, "repo = ", repr(data["repo"]))
        end
        println(io)

        if haskey(data, "description")
            print(io, """
            description = \"\"\"
            $(data["description"])\"\"\"
            """
            )
        end

        println(io)
        println(io, "[packages]")
        if haskey(data, "packages")
            for (uuid, data) in sort!(collect(data["packages"]), by=first)
                println(io, uuid, " = { name = ", repr(data["name"]), ", path = ", repr(data["path"]), " }")
            end
        end
    end
end

struct PackageReg
    uuid::UUID
    name::String
    url::String
    version::VersionNumber
    git_tree_sha::SHA1
    deps::Dict{UUID, VersionSpec}
end


function collect_package_info(pkgpath::String)
    pkgpath = abspath(pkgpath)
    local git_tree_sha
    if !isdir(pkgpath)
        cmderror("directory $(repr(pkgpath)) not found")
    end
    if !isdir(joinpath(pkgpath, ".git"))
        cmderror("can only register git repositories as packages")
    end
    project_file = projectfile_path(pkgpath)
    if project_file === nothing
        cmderror("package needs a \"[Julia]Project.toml\" file")
    end
    LibGit2.with(LibGit2.GitRepo(pkgpath)) do repo
        if LibGit2.isdirty(repo)
            cmderror("git repo at $(repr(pkgpath)) is dirty")
        end
        head = LibGit2.head(repo)
        git_tree_sha = begin
            LibGit2.with(LibGit2.peel(LibGit2.GitTree, head)) do tree
                SHA1(string(LibGit2.GitHash(tree)))
            end
        end
    end
    url = ""
    try
        url = LibGit2.getconfig(pkgpath, "remote.origin.url", "")
    catch err
        cmderror("$pkg: $err")
    end
    isempty(url) && cmderror("$pkgpath: no URL configured")

    project = read_package(project_file)
    if !haskey(project, "version")
        cmderror("project file did not contain a version entry")
    end
    vers = VersionNumber(project["version"])
    vers = VersionNumber(vers.major, vers.minor, vers.patch)
    name = project["name"]
    uuid = UUID(project["uuid"])

    name_uuid = Dict{String, UUID}()
    deps = Dict{UUID, VersionSpec}()
    for (pkg, dep_uuid) in project["deps"]
        name_uuid[pkg] = UUID(dep_uuid)
        deps[UUID(dep_uuid)] = VersionSpec()
    end

    for (pkg, verspec) in get(project, "compat", [])
        if !haskey(name_uuid, pkg)
            cmderror("package $pkg in compat section does not exist in deps section")
        end
        dep_uuid = name_uuid[pkg]
        deps[dep_uuid] = Types.semver_spec(verspec)
    end

    return PackageReg(
        uuid,
        name,
        url,
        vers,
        git_tree_sha,
        deps
    )
end

register(registry::String, pkgpath) = register(registry, collect_package_info(pkgpath))
function register(registry::String, pkg::PackageReg)
    !isdir(registry) && error(abspath(registry), " does not exist")
    registry_main_file = joinpath(registry, "Registry.toml")
    !isfile(registry_main_file) && error(abspath(registry_main_file), " does not exist")
    registry_data = TOML.parsefile(joinpath(registry, "Registry.toml"))

    registry_packages = get(registry_data, "packages", Dict{String, Any}())

    bin = string(first(pkg.name))
    if haskey(registry_packages, string(pkg.uuid))
        registering_new = false
        reldir = registry_packages[string(pkg.uuid)]["path"]
    else
        registering_new = true
        binpath = joinpath(registry, bin)
        mkpath(binpath)
        # store the package in $name__$i where i is the no. of pkgs with the same name
        # unless i == 0, then store in $name
        candidates = filter(x -> startswith(x, pkg.name), readdir(binpath))
        r = Regex("$(pkg.name)(__)?[0-9]*?\$")
        offset = count(x -> occursin(r, x), candidates)
        if offset == 0
            reldir = joinpath(string(first(pkg.name)), pkg.name)
        else
            reldir = joinpath(string(first(pkg.name)), "$(pkg.name)__$(offset+1)")
        end
    end

    registry_packages[string(pkg.uuid)] = Dict("name" => pkg.name, "path" => reldir)
    pkg_registry_path = joinpath(registry, reldir)

    LibGit2.transact(LibGit2.GitRepo(registry)) do repo
        mkpath(pkg_registry_path)
        for f in ("Versions.toml", "Deps.toml", "Compat.toml")
            isfile(joinpath(pkg_registry_path, f)) || touch(joinpath(pkg_registry_path, f))
        end

        version_data = Operations.load_versions(pkg_registry_path)
        if haskey(version_data, pkg.version)
            cmderror("version $(pkg.version) already registered")
        end
        version_data[pkg.version] = pkg.git_tree_sha

        ctx = Context()
        for (uuid, v) in pkg.deps
            if !(is_stdlib(ctx, uuid) || string(uuid) in keys(registry_packages))
                cmderror("dependency with uuid $(uuid) not an stdlib nor registered package")
            end
        end

        deps_data = Operations.load_package_data_raw(UUID, joinpath(pkg_registry_path, "Deps.toml"))
        compat_data = Operations.load_package_data_raw(VersionSpec, joinpath(pkg_registry_path, "Compat.toml"))

        new_deps = Dict{String, Any}()
        new_compat = Dict{String, Any}()
        for (uuid, v) in pkg.deps
            if is_stdlib(ctx, uuid)
                name = ctx.stdlibs[uuid]
            else
                name = registry_packages[string(uuid)]["name"]
                new_compat[name] = v
            end
            new_deps[name] = uuid
        end
        deps_data[VersionRange(pkg.version)] = new_deps
        compat_data[VersionRange(pkg.version)] = new_compat

        # TODO: compression

        # Package.toml
        write_toml(joinpath(pkg_registry_path, "Package")) do io
            println(io, "name = ", repr(pkg.name))
            println(io, "uuid = ", repr(string(pkg.uuid)))
            println(io, "repo = ", repr(pkg.url))
        end

        # Versions.toml
        versionfile = joinpath(pkg_registry_path, "Versions.toml")
        isfile(versionfile) || touch(versionfile)
        write_toml(joinpath(pkg_registry_path, "Versions")) do io
            for (i, (ver, v)) in enumerate(sort!(collect(version_data), by=first))
                i > 1 && println(io)
                println(io, "[", toml_key(string(ver)), "]")
                println(io, "git-tree-sha1 = ", repr(string(pkg.git_tree_sha)))
            end
        end

        function write_version_data(f::String, d::Dict)
            write_toml(f) do io
                for (i, (ver, v)) in enumerate(sort!(collect(d), by=first))
                    i > 1 && println(io)
                    println(io, "[", toml_key(string(ver)), "]")
                    for (key, val) in sort!(collect(v))
                        println(io, key, " = \"$val\"")
                    end
                end
            end
        end

        # Compat.toml
        write_version_data(joinpath(pkg_registry_path, "Compat"), compat_data)

        # Deps.toml
        write_version_data(joinpath(pkg_registry_path, "Deps"), deps_data)

        # Registry.toml
        if registering_new
            write_mainfile(joinpath(registry), registry_data)
            LibGit2.add!(repo, "Registry.toml")
        end
        LibGit2.add!(repo, reldir)
        # Commit it
        prefix = registering_new ? "Register" : "Tag v$(pkg.version)"
        LibGit2.commit(repo, "$prefix $(pkg.name) [$(pkg.url)]")
    end
    return
end


toml_key(str::String) = occursin(r"[^\w-]", str) ? repr(str) : str
toml_key(strs::String...) = join(map(toml_key, [strs...]), '.')

end