function find_stdlib_deps(ctx::Context, path::String)
    stdlib_deps = Dict{UUID, String}()
    regexps = [Regex("\\b(import|using)\\s+((\\w|\\.)+\\s*,\\s*)*$lib\\b") for lib in values(ctx.stdlibs)]
    for (root, dirs, files) in walkdir(path; onerror = x->nothing)
        for file in files
            endswith(file, ".jl") || continue
            filecontent = try read(joinpath(root, file), String)
                catch e
                    e isa SystemError || rethrow()
                    ""
                end
            for ((uuid, stdlib), r) in zip(ctx.stdlibs, regexps)
                if occursin(r, filecontent)
                    stdlib_deps[uuid] = stdlib
                end
            end
        end
    end
    return stdlib_deps
end


# Backwards compatibility with Pkg2 REQUIRE format
function collect_require!(ctx::Context, pkg::PackageSpec, path::String,
                          fix_deps_map::Dict{UUID,Vector{PackageSpec}})
    fix_deps = PackageSpec[]
    reqfile = joinpath(path, "REQUIRE")
    # Checked out "old-school" packages have by definition a version higher than all registered.
    set_maximum_version_registry!(ctx, pkg)
    !haskey(fix_deps_map, pkg.uuid) && (fix_deps_map[pkg.uuid] = valtype(fix_deps_map)())
    if isfile(reqfile)
        for r in Pkg2.Reqs.read(reqfile)
            r isa Pkg2.Reqs.Requirement || continue
            pkg_name, vspec = r.package, VersionSpec(VersionRange[r.versions.intervals...])
            if pkg_name == "julia"
                if !(VERSION in vspec)
                    @warn("julia version requirement for package $(pkg.name) not satisfied")
                end
            else
                deppkg = PackageSpec(pkg_name, vspec)
                push!(fix_deps_map[pkg.uuid], deppkg)
                push!(fix_deps, deppkg)
            end
        end

        # Packages from REQUIRE files need to get their UUID from the registry
        registry_resolve!(ctx, fix_deps)
        project_deps_resolve!(ctx, fix_deps)
        ensure_resolved(ctx, fix_deps; registry=true)
    end

    # And collect the stdlibs
    stdlibs = find_stdlib_deps(ctx, path)
    for (uuid, name) in stdlibs
        deppkg = PackageSpec(name, uuid)
        push!(fix_deps_map[pkg.uuid], deppkg)
        push!(fix_deps, deppkg)
    end

    return
end

# Pkg2 test/REQUIRE compatibility
function pkg2_test_target_compatibility!(ctx, path, pkgs)
    test_reqfile = joinpath(path, "test", "REQUIRE")
    if isfile(test_reqfile)
        for r in Pkg2.Reqs.read(test_reqfile)
            r isa Pkg2.Reqs.Requirement || continue
            pkg_name, vspec = r.package, VersionSpec(VersionRange[r.versions.intervals...])
            pkg_name == "julia" && continue
            push!(pkgs, PackageSpec(pkg_name, vspec))
        end
        registry_resolve!(ctx, pkgs)
        project_deps_resolve!(ctx, pkgs)
        ensure_resolved(ctx, pkgs; registry=true)
    end
    return nothing
end
