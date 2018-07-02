function create_project(path::String)
    ctx = Context()

    # Package data
    path = abspath(path)
    m = match(Types.reg_pkg, path)
    m === nothing && cmderror("cannot determine package name from URL: $(path)")
    pkgname = m.captures[1]

    mainpkg = PackageSpec(pkgname)
    registry_resolve!(ctx.env, [mainpkg])
    if !has_uuid(mainpkg)
        uuid = UUIDs.uuid1()
        @info "Unregistered package, giving it a new UUID: $uuid"
        mainpkg.version = v"0.1.0"
    else
        uuid = mainpkg.uuid
        @info "Registered package, using already given UUID: $(mainpkg.uuid)"
        Operations.set_maximum_version_registry!(ctx.env, mainpkg)
        v = mainpkg.version
        # Remove the build
        mainpkg.version = VersionNumber(v.major, v.minor, v.patch)
    end

    # Dependency data
    dep_pkgs = PackageSpec[]
    test_pkgs = PackageSpec[]
    compatibility = Pair{String, String}[]

    reqfiles = [joinpath(path, "REQUIRE"), joinpath(path, "test", "REQUIRE")]
    for (reqfile, pkgs) in zip(reqfiles, [dep_pkgs, test_pkgs])
        if isfile(reqfile)
            for r in Pkg2.Reqs.read(reqfile)
                r isa Pkg2.Reqs.Requirement || continue
                r.package == "julia" && continue
                push!(pkgs, PackageSpec(r.package))
                intervals = r.versions.intervals
                if length(intervals) != 1
                    @warn "Project.toml creator cannot handle multiple requirements for $(r.package), ignoring"
                else
                    l = intervals[1].lower
                    h = intervals[1].upper
                    if l != v"0.0.0-"
                        # no upper bound
                        if h == typemax(VersionNumber)
                            push!(compatibility, r.package => string(">=", VersionNumber(l.major, l.minor, l.patch)))
                        else # assume semver
                            push!(compatibility, r.package => string(">=", VersionNumber(l.major, l.minor, l.patch), ", ",
                                                                     "<", VersionNumber(h.major, h.minor, h.patch)))
                        end
                    end
                end
            end
            registry_resolve!(ctx.env, pkgs)
            ensure_resolved(ctx.env, pkgs)
        end
    end

    stdlib_deps = Operations.find_stdlib_deps(ctx, path)
    for (stdlib_uuid, stdlib) in stdlib_deps
        pkg = PackageSpec(stdlib, stdlib_uuid)
        if stdlib == "Test"
            push!(test_pkgs, pkg)
        else
            push!(dep_pkgs, pkg)
        end
    end

    # Write project

    project = Dict(
        "name" => pkgname,
        "uuid" => string(uuid),
        "version" => string(mainpkg.version),
        "deps" => Dict(pkg.name => string(pkg.uuid) for pkg in dep_pkgs)
    )

    if !isempty(compatibility)
        project["compat"] =
            Dict(name => ver for (name, ver) in compatibility)
    end

    if !isempty(test_pkgs)
        project["targets"] =
            Dict("test" =>
                Dict("deps" =>
                    Dict(pkg.name => string(pkg.uuid) for pkg in test_pkgs)
                )
            )
    end

    open(joinpath(path, "Project.toml"), "w") do io
        TOML.print(io, project, sorted=true, by=key -> (Types.project_key_order(key), key))
    end

    @info "Added Project.toml to $(path)"
end