# This file is a part of Julia. License is MIT: https://julialang.org/license

module ResolverTranslation

using UUIDs
using ..Resolve
using Pkg.Versions: VersionSpec

import Resolver

struct SATResolverError <: Exception
    msg::String
end

function translate_to_new_resolver(
        all_compat::Dict{UUID, Dict{VersionNumber, Dict{UUID, VersionSpec}}},
        weak_compat::Dict{UUID, Dict{VersionNumber, Set{UUID}}},
        fixed::Dict{UUID, Resolve.Fixed},
        reqs::Resolve.Requires
    )
    # Check that all required packages are present in all_compat
    missing_packages = setdiff(keys(reqs), keys(all_compat))
    if !isempty(missing_packages)
        error("internal error: required packages missing from compatibility data: $(missing_packages)")
    end

    pkg_data_entries = []

    for (pkg_uuid, version_compat) in all_compat
        # Extract all versions for this package
        all_versions = sort!(collect(keys(version_compat)), rev = true)

        # Filter versions based on requirements and fixed package constraints
        if haskey(reqs, pkg_uuid)
            req_spec = reqs[pkg_uuid]
            versions = filter(v -> v in req_spec, all_versions)
        else
            versions = all_versions
        end

        # Apply constraints from ALL fixed packages (including weak deps)
        for (_, fixed_entry) in fixed
            if haskey(fixed_entry.requires, pkg_uuid)
                fixed_constraint = fixed_entry.requires[pkg_uuid]
                versions = filter(v -> v in fixed_constraint, versions)
                # Continue to apply constraints from other fixed packages (intersection)
            end
        end

        # Build regular dependencies (non-weak)
        deps = Dict{VersionNumber, Vector{UUID}}()
        # Build compatibility constraints (includes weak deps)
        comp = Dict{VersionNumber, Dict{UUID, VersionSpec}}()

        for version in versions
            deps[version] = UUID[]
            comp[version] = Dict{UUID, VersionSpec}()

            # Get weak deps for this version
            weak_deps = get(Set{UUID}, get(Dict, weak_compat, pkg_uuid), version)

            # Process all compatibility info
            for (dep_uuid, version_spec) in version_compat[version]
                if dep_uuid in weak_deps
                    # Weak dependency: add to compat only (don't force installation)
                    comp[version][dep_uuid] = version_spec
                else
                    # Regular dependency: add to both deps and compat
                    push!(deps[version], dep_uuid)
                    comp[version][dep_uuid] = version_spec
                end
            end

            sort!(deps[version])
        end

        # Handle fixed packages - they get constrained to their fixed version
        if haskey(fixed, pkg_uuid)
            fixed_entry = fixed[pkg_uuid]
            # Only include the fixed version
            versions = [fixed_entry.version]
            deps_fixed = UUID[]
            comp_fixed = Dict{UUID, VersionSpec}()

            # Add regular dependencies from fixed entry
            for (dep_uuid, version_spec) in fixed_entry.requires
                if dep_uuid in fixed_entry.weak
                    # Weak dependency: add to compat only
                    comp_fixed[dep_uuid] = version_spec
                else
                    # Regular dependency: add to both
                    push!(deps_fixed, dep_uuid)
                    comp_fixed[dep_uuid] = version_spec
                end
            end

            sort!(deps_fixed)
            deps = Dict(fixed_entry.version => deps_fixed)
            comp = Dict(fixed_entry.version => comp_fixed)
        end

        push!(pkg_data_entries, pkg_uuid => Resolver.PkgData(versions, deps, comp))
    end

    # Create the properly typed dictionary
    pkg_data = Dict(pkg_data_entries)
    return pkg_data
end

function translate_from_new_resolver(
        pkgs::Vector{UUID},
        vers::Matrix{Union{VersionNumber, Nothing}},
        required_packages::Vector{UUID},
        uuid_to_name::Dict{UUID, String}
    )::Dict{UUID, VersionNumber}
    # Filter out packages with nothing versions (not installed in solution)
    solution_dict = Dict{UUID, VersionNumber}()
    unsatisfied_requirements = UUID[]

    for (i, pkg_uuid) in enumerate(pkgs)
        version = vers[i, 1]  # First solution
        if version !== nothing
            solution_dict[pkg_uuid] = version
        elseif pkg_uuid in required_packages
            # This is a required package but the solver couldn't find a solution for it
            push!(unsatisfied_requirements, pkg_uuid)
        end
    end

    # Check if any required packages couldn't be satisfied
    if !isempty(unsatisfied_requirements)
        unsatisfied_names = [get(uuid_to_name, uuid, string(uuid)) for uuid in unsatisfied_requirements]
        throw(
            SATResolverError(
                "SAT resolver could not satisfy requirements for packages: $(join(unsatisfied_names, ", ")). " *
                    "This may indicate dependency conflicts or unsatisfiable constraints."
            )
        )
    end

    return solution_dict
end

function resolve_with_new_solver(
        all_compat::Dict{UUID, Dict{VersionNumber, Dict{UUID, VersionSpec}}},
        weak_compat::Dict{UUID, Dict{VersionNumber, Set{UUID}}},
        uuid_to_name::Dict{UUID, String},
        reqs::Resolve.Requires,
        fixed::Dict{UUID, Resolve.Fixed}
    )::Dict{UUID, VersionNumber}
    # Translate to new resolver format
    pkg_data = translate_to_new_resolver(all_compat, weak_compat, fixed, reqs)
    # Convert PkgData to PkgInfo format that the resolver expects
    required_packages = collect(keys(reqs))
    pkg_info = Resolver.pkg_info(pkg_data, required_packages)

    # Call new resolver
    pkgs, vers_matrix = Resolver.resolve(pkg_info, required_packages)

    # Translate back from new resolver format
    return translate_from_new_resolver(pkgs, vers_matrix, required_packages, uuid_to_name)
end

end # module
