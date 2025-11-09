# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    Pkg.Status

Encapsulates all environment status reporting.
Inputs are an `EnvCache`, the reachable registries, and the `PackageSpec` filters
requested by API/REPL callers.

The execution flow is:
1. Build a `StatusOptions`/`StatusContext` pair capturing the user’s flags,
   filter set, and IO metadata.
2. Compute manifest/project diff pairs via `diff_array`, then filter/sort them
   to the rows that should be displayed.
3. Summarize each row into `PackageStatusData` and aggregate footer state inside
   a `StatusReport`. During this step the module queries registries for compat,
   deprecation, and extension information as needed.
4. Render the entries and footers through `printpkgstyle`, reusing cached
   indicator glyphs so output stays consistent in REPL and non-REPL contexts.
"""
module Status

using UUIDs: UUID
import LibGit2

using ..Types
using ..Types: Context, pkgerror
using ..GitTools

import ..Pkg: Registry, pathrepr, printpkgstyle, discover_repo, in_repl_mode, stdout_f
import ..Pkg: RESPECT_SYSIMAGE_VERSIONS
import ..Operations:
    load_all_deps,
    load_all_deps_loadable,
    load_project_deps,
    load_direct_deps,
    is_pkgversion_yanked,
    get_pkg_deprecation_info,
    get_compat_workspace,
    get_compat_str,
    is_package_downloaded,
    is_tracking_repo,
    is_tracking_path,
    is_tracking_registry,
    PKGORIGIN_HAVE_VERSION,
    JULIA_UUID

export status, show_update, status_compat_info, print_compat, print_single

"""
Holds all knobs toggled by API/REPL callers so they can be passed around as a unit.
"""
Base.@kwdef struct StatusOptions
    manifest::Bool              # `true` for manifest view, `false` for project view
    diff::Bool                  # render diff-only output when an old manifest is present
    workspace::Bool             # include workspace entries alongside the active project
    outdated::Bool              # filter packages down to those with upgrades available
    deprecated::Bool            # filter packages down to those with deprecation info
    extensions::Bool            # show extension/weakdep trees instead of main rows
    mode::PackageMode           # controls whether project/manifest/both are displayed
    hidden_upgrades_info::Bool  # force info footer even if held-back packages were filtered away
    show_usagetips::Bool        # append CLI hints (e.g. `status --outdated`) to footers
end

"""
Captures the environment plus IO metadata needed during a status invocation.
"""
struct StatusContext
    env::EnvCache                                   # active environment being inspected
    old_env::Union{EnvCache, Nothing}               # comparison environment (git diff or manual)
    registries::Vector{Registry.RegistryInstance}   # reachable registries for compat lookups
    header::Symbol                                  # header label (:Status, :Manifest, etc.)
    filter_uuids::Vector{UUID}                      # UUID filters requested by the caller
    filter_names::Vector{String}                    # name filters requested by the caller
    io::IO                                          # destination for status output
    ignore_indent::Bool                             # REPL vs non-REPL indentation toggle
end

"""
Caches the colored glyphs used to annotate each row.
"""
struct StatusIndicators
    missing::String     # glyph for packages that are not downloaded locally
    upgradable::String  # glyph for packages with unconstrained upgrades available
    heldback::String    # glyph for packages blocked by compat/system constraints
end

StatusIndicators(io::IO) = StatusIndicators(
    sprint((i, args) -> printstyled(i, args...; color = Base.error_color()), "→", context = io),
    sprint((i, args) -> printstyled(i, args...; color = :green), "⌃", context = io),
    sprint((i, args) -> printstyled(i, args...; color = Base.warn_color()), "⌅", context = io),
)

const StatusDiffEntry = Tuple{Union{UUID, Nothing}, Union{PackageSpec, Nothing}, Union{PackageSpec, Nothing}}

"""
Lightweight bundle that threads context, options, and cached glyphs through the status
pipeline so helper signatures stay compact.
"""
struct StatusRun
    ctx::StatusContext          # immutable view of environment, registries, and IO metadata
    opts::StatusOptions         # set of flags derived from API/REPL inputs
    indicators::StatusIndicators  # pre-rendered glyphs reused for every entry/footer
end

StatusRun(ctx::StatusContext, opts::StatusOptions) = StatusRun(ctx, opts, StatusIndicators(ctx.io))


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

function stat_rep(x::PackageSpec; name = true)
    name_str = name && x.name !== nothing ? string(x.name) : ""
    version_str = x.version == VersionSpec() ? "" : "v$(x.version)"
    rev = ""
    if x.repo.rev !== nothing
        rev = occursin(r"\b([a-f0-9]{40})\b", x.repo.rev) ? x.repo.rev[1:7] : x.repo.rev
    end
    subdir_str = x.repo.subdir === nothing ? "" : ":$(x.repo.subdir)"
    repo = is_tracking_repo(x) ? "`$(x.repo.source)$(subdir_str)#$(rev)`" : ""
    path_str = is_tracking_path(x) ? "$(pathrepr(x.path))" : ""
    pinned = x.pinned ? "⚲" : ""
    return join(filter(!isempty, [name_str, version_str, repo, path_str, pinned]), " ")
end

print_single(io::IO, pkg::PackageSpec) = print(io, stat_rep(pkg))

is_instantiated(::Nothing) = false
is_instantiated(x::PackageSpec) = x.version != VersionSpec() || is_stdlib(x.uuid)

function print_diff(io::IO, old::Union{Nothing, PackageSpec}, new::Union{Nothing, PackageSpec})
    return if !is_instantiated(old) && is_instantiated(new)
        printstyled(io, "+ $(stat_rep(new))"; color = :light_green)
    elseif !is_instantiated(new)
        printstyled(io, "- $(stat_rep(old))"; color = :light_red)
    elseif is_tracking_registry(old) && is_tracking_registry(new) &&
            new.version isa VersionNumber && old.version isa VersionNumber && new.version != old.version
        if new.version > old.version
            printstyled(io, "↑ $(stat_rep(old)) ⇒ $(stat_rep(new; name = false))"; color = :light_yellow)
        else
            printstyled(io, "↓ $(stat_rep(old)) ⇒ $(stat_rep(new; name = false))"; color = :light_magenta)
        end
    else
        printstyled(io, "~ $(stat_rep(old)) ⇒ $(stat_rep(new; name = false))"; color = :light_yellow)
    end
end

# ---------------------------------------------------------------------------
# Data gathering helpers
# ---------------------------------------------------------------------------

function status_compat_info(pkg::PackageSpec, env::EnvCache, regs::Vector{Registry.RegistryInstance})
    pkg.version isa VersionNumber || return nothing # Can happen when there is no manifest
    manifest, project = env.manifest, env.project
    packages_holding_back = String[]
    max_version, max_version_in_compat = v"0", v"0"
    for reg in regs
        reg_pkg = get(reg, pkg.uuid, nothing)
        reg_pkg === nothing && continue
        info = Registry.registry_info(reg, reg_pkg)
        versions = keys(info.version_info)
        versions = filter(v -> !Registry.isyanked(info, v), versions)
        max_version_reg = maximum(versions; init = v"0")
        max_version = max(max_version, max_version_reg)
        compat_spec = get_compat_workspace(env, pkg.name)
        versions_in_compat = filter(in(compat_spec), versions)
        max_version_in_compat = max(max_version_in_compat, maximum(versions_in_compat; init = v"0"))
    end
    max_version == v"0" && return nothing
    pkg.version >= max_version && return nothing

    pkgid = Base.PkgId(pkg.uuid, pkg.name)
    if PKGORIGIN_HAVE_VERSION && RESPECT_SYSIMAGE_VERSIONS[] && Base.in_sysimage(pkgid)
        pkgorigin = get(Base.pkgorigins, pkgid, nothing)
        if pkgorigin !== nothing && pkg.version !== nothing && pkg.version == pkgorigin.version
            return ["sysimage"], max_version, max_version_in_compat
        end
    end

    if pkg.version == max_version_in_compat && max_version_in_compat != max_version
        return ["compat"], max_version, max_version_in_compat
    end

    manifest_info = get(manifest, pkg.uuid, nothing)
    manifest_info === nothing && return nothing

    for (uuid, dep_pkg) in manifest
        is_stdlib(uuid) && continue
        if !(pkg.uuid in values(dep_pkg.deps))
            continue
        end
        dep_info = get(manifest, uuid, nothing)
        dep_info === nothing && continue
        for reg in regs
            reg_pkg = get(reg, uuid, nothing)
            reg_pkg === nothing && continue
            info = Registry.registry_info(reg, reg_pkg)
            compat_info_v_uuid = Registry.query_compat_for_version(info, dep_info.version, pkg.uuid)
            compat_info_v_uuid === nothing && continue
            if !(max_version in compat_info_v_uuid)
                push!(packages_holding_back, dep_pkg.name)
            end
        end
    end

    julia_compatible_versions = Set{VersionNumber}()
    for reg in regs
        reg_pkg = get(reg, pkg.uuid, nothing)
        reg_pkg === nothing && continue
        info = Registry.registry_info(reg, reg_pkg)
        for v in keys(info.version_info)
            julia_vspec = Registry.query_compat_for_version(info, v, JULIA_UUID)
            if julia_vspec !== nothing && VERSION in julia_vspec
                push!(julia_compatible_versions, v)
            end
        end
    end
    if !(max_version in julia_compatible_versions)
        push!(packages_holding_back, "julia")
    end

    return sort!(unique!(packages_holding_back)), max_version, max_version_in_compat
end

function diff_array(old_env::Union{EnvCache, Nothing}, new_env::EnvCache; manifest = true, workspace = false)
    function index_pkgs(pkgs, uuid)
        idx = findfirst(pkg -> pkg.uuid == uuid, pkgs)
        return idx === nothing ? nothing : pkgs[idx]
    end
    if workspace
        new = manifest ? load_all_deps(new_env) : load_direct_deps(new_env)
    else
        new = manifest ? load_all_deps_loadable(new_env) : load_project_deps(new_env.project, new_env.project_file, new_env.manifest, new_env.manifest_file)
    end

    T, S = Union{UUID, Nothing}, Union{PackageSpec, Nothing}
    if old_env === nothing
        return Tuple{T, S, S}[(pkg.uuid, nothing, pkg)::Tuple{T, S, S} for pkg in new]
    end
    if workspace
        old = manifest ? load_all_deps(old_env) : load_direct_deps(old_env)
    else
        old = manifest ? load_all_deps_loadable(old_env) : load_project_deps(old_env.project, old_env.project_file, old_env.manifest, old_env.manifest_file)
    end
    all_uuids = union(T[pkg.uuid for pkg in old], T[pkg.uuid for pkg in new])
    return Tuple{T, S, S}[(uuid, index_pkgs(old, uuid), index_pkgs(new, uuid))::Tuple{T, S, S} for uuid in all_uuids]
end

function status_ext_info(pkg::PackageSpec, env::EnvCache)
    manifest = env.manifest
    manifest_info = get(manifest, pkg.uuid, nothing)
    manifest_info === nothing && return nothing
    depses = manifest_info.deps
    weakdepses = manifest_info.weakdeps
    exts = manifest_info.exts
    if !isempty(weakdepses) && !isempty(exts)
        v = ExtInfo[]
        for (ext, extdeps) in exts
            extdeps isa String && (extdeps = String[extdeps])
            ext_loaded = (Base.get_extension(Base.PkgId(pkg.uuid, pkg.name), Symbol(ext)) !== nothing)
            extdeps_info = Tuple{String, Bool}[]
            for extdep in extdeps
                if !(haskey(weakdepses, extdep) || haskey(depses, extdep))
                    pkgerror(
                        isnothing(pkg.name) ? "M" : "$(pkg.name) has a malformed Project.toml, ",
                        "the extension package $extdep is not listed in [weakdeps] or [deps]"
                    )
                end
                uuid = get(weakdepses, extdep, nothing)
                if uuid === nothing
                    uuid = depses[extdep]
                end
                loaded = haskey(Base.loaded_modules, Base.PkgId(uuid, extdep))
                push!(extdeps_info, (extdep, loaded))
            end
            push!(v, ExtInfo((ext, ext_loaded), extdeps_info))
        end
        return v
    end
    return nothing
end

"""
Represents a package extension along with the load state of its weak dependencies.
"""
struct ExtInfo
    ext::Tuple{String, Bool}               # (extension name, whether it is currently loaded)
    weakdeps::Vector{Tuple{String, Bool}}  # weak dep names paired with their load status
end

"""
Fully describes a single row in the status table.
"""
struct PackageStatusData
    uuid::UUID                         # package identifier row belongs to
    old::Union{Nothing, PackageSpec}   # version from old manifest/project (diff mode)
    new::Union{Nothing, PackageSpec}   # current version from active environment
    downloaded::Bool                   # whether artifacts exist in the depot/scratch
    upgradable::Bool                   # true when an unconstrained upgrade is available
    heldback::Bool                     # true when upgrades exist but compat prevents them
    compat_data::Union{Nothing, Tuple{Vector{String}, VersionNumber, VersionNumber}}  # data for --outdated display
    changed::Bool                      # indicates addition/removal/version change
    extinfo::Union{Nothing, Vector{ExtInfo}}        # extension metadata when requested
    deprecation_info::Union{Nothing, Dict{String, Any}}  # resolved registry deprecation payload
end

"""
Aggregated representation of everything required to render a status block and footer.
"""
struct StatusReport
    packages::Vector{PackageStatusData}  # ordered rows ready for rendering
    lpadding::Int                       # padding needed to align glyph prefix column
    all_packages_downloaded::Bool       # true when no visible packages require instantiation
    no_packages_upgradable::Bool        # true when no visible packages can upgrade
    no_visible_packages_heldback::Bool  # true when compat-locked packages were filtered out
    no_packages_heldback::Bool          # true when no packages are compat-locked at all
end

"""
Mutable helper used while building reports so we keep padding and footer flags in sync.
"""
Base.@kwdef mutable struct StatusAccumulator
    lpadding::Int = 2                    # recorded left padding width (2 == no glyphs needed)
    all_packages_downloaded::Bool = true # cleared when a visible package needs instantiation
    no_packages_upgradable::Bool = true  # cleared when at least one row is upgradable
    no_visible_packages_heldback::Bool = true # cleared when any rendered row is held back
    no_packages_heldback::Bool = true    # cleared when compat data says *any* package is held back
end

function update!(acc::StatusAccumulator, pkg::PackageStatusData)
    if !pkg.downloaded && (pkg.upgradable || pkg.heldback)
        acc.lpadding = max(acc.lpadding, 3)
    end
    acc.all_packages_downloaded &= (!pkg.changed || pkg.downloaded)
    acc.no_packages_upgradable &= (!pkg.changed || !pkg.upgradable)
    acc.no_visible_packages_heldback &= (!pkg.changed || !pkg.heldback)
    acc.no_packages_heldback &= !pkg.heldback
    return acc
end

# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

# Sort stdlibs last, then JLLs, then alphabetically for deterministic output.
function status_pair_key((uuid, old, new)::StatusDiffEntry)
    pkg = something(new, old, nothing)
    name = pkg === nothing || pkg.name === nothing ? "" : pkg.name
    stdlib = uuid isa UUID && is_stdlib(uuid)
    return (stdlib, endswith(name, "_jll"), name, uuid)
end

function print_status(
        env::EnvCache, old_env::Union{Nothing, EnvCache}, registries::Vector{Registry.RegistryInstance}, header::Symbol,
        uuids::Vector, names::Vector; manifest = true, diff = false, ignore_indent::Bool, workspace::Bool, outdated::Bool, deprecated::Bool, extensions::Bool, io::IO,
        mode::PackageMode, hidden_upgrades_info::Bool, show_usagetips::Bool = true
    )
    opts = StatusOptions(
        manifest,
        diff,
        workspace,
        outdated,
        deprecated,
        extensions,
        mode,
        hidden_upgrades_info,
        show_usagetips,
    )
    ctx = StatusContext(env, old_env, registries, header, uuids, names, io, ignore_indent)
    run = StatusRun(ctx, opts)
    pairs = diff_array(old_env, env; manifest = opts.manifest, workspace = opts.workspace)
    handle_empty_status(run, pairs) && return nothing
    filtered_pairs = filter_status_pairs(run, pairs)
    filtered_pairs === nothing && return nothing
    print_status_header(run)
    sorted_pairs = sort!(filtered_pairs, by = status_pair_key)
    report = collect_status_report(sorted_pairs, run)
    render_status_entries(report, run)
    render_status_footer(report, run)
    return nothing
end

function handle_empty_status(run::StatusRun, pairs)::Bool
    ctx, opts = run.ctx, run.opts
    if isempty(pairs) && !opts.diff
        file = opts.manifest ? ctx.env.manifest_file : ctx.env.project_file
        kind = opts.manifest ? "manifest" : "project"
        printpkgstyle(ctx.io, ctx.header, "$(pathrepr(file)) (empty $kind)", ctx.ignore_indent)
        return true
    end
    if opts.diff && all(p -> p[2] == p[3], pairs)
        if opts.manifest
            printpkgstyle(
                ctx.io,
                :Manifest,
                "No packages added to or removed from $(pathrepr(ctx.env.manifest_file))",
                ctx.ignore_indent; color = Base.info_color(),
            )
        else
            printpkgstyle(
                ctx.io,
                :Project,
                "No packages added to or removed from $(pathrepr(ctx.env.project_file))",
                ctx.ignore_indent; color = Base.info_color(),
            )
        end
        return true
    end
    return false
end

function filter_status_pairs(run::StatusRun, pairs)
    ctx, opts = run.ctx, run.opts
    filter_active = !isempty(ctx.filter_uuids) || !isempty(ctx.filter_names)
    filter_active || return pairs
    matching_ids = Set{UUID}()
    for (id, old, new) in pairs
        pkg = something(new, old, nothing)
        pkg === nothing && continue
        if (id in ctx.filter_uuids) || (pkg.name !== nothing && pkg.name in ctx.filter_names)
            push!(matching_ids, id)
        end
    end
    if opts.manifest && !isempty(matching_ids)
        deps_to_add = Set{UUID}()
        for id in matching_ids
            entry = get(ctx.env.manifest, id, nothing)
            entry === nothing && continue
            union!(deps_to_add, values(entry.deps))
        end
        union!(matching_ids, deps_to_add)
    end
    filtered = eltype(pairs)[(id, old, new) for (id, old, new) in pairs if id in matching_ids]
    if isempty(filtered)
        file = opts.manifest ? ctx.env.manifest_file : ctx.env.project_file
        prefix = opts.diff ? "diff for " : ""
        printpkgstyle(ctx.io, Symbol("No Matches"), "in $(prefix)$(pathrepr(file))", ctx.ignore_indent)
        return nothing
    end
    return filtered
end

function print_status_header(run::StatusRun)
    ctx, opts = run.ctx, run.opts
    file = opts.manifest ? ctx.env.manifest_file : ctx.env.project_file
    readonly_suffix = ctx.env.project.readonly ? " (readonly)" : ""
    printpkgstyle(ctx.io, ctx.header, pathrepr(file) * readonly_suffix, ctx.ignore_indent)
    if opts.workspace && !opts.manifest
        for (path, _) in ctx.env.workspace
            relative_path = Types.relative_project_path(ctx.env.project_file, path)
            printpkgstyle(ctx.io, :Status, relative_path, true)
        end
    end
end

function collect_status_report(pairs, run::StatusRun)
    # Walk each diff pair once, building both the row vector and aggregate flags for footer messaging.
    packages = PackageStatusData[]
    acc = StatusAccumulator()
    for (uuid, old, new) in pairs
        entry = package_status_entry(uuid, old, new, run)
        entry === nothing && continue
        push!(packages, entry)
        update!(acc, entry)
    end
    return StatusReport(
        packages,
        acc.lpadding,
        acc.all_packages_downloaded,
        acc.no_packages_upgradable,
        acc.no_visible_packages_heldback,
        acc.no_packages_heldback,
    )
end

function package_status_entry(uuid, old, new, run::StatusRun)
    ctx, opts = run.ctx, run.opts
    Types.is_project_uuid(ctx.env, uuid) && return nothing
    # All filtering (diff-only rows, --outdated, --deprecated, etc.) happens here so
    # later stages can assume the entry should be shown.
    changed = old != new
    opts.diff && !changed && return nothing
    latest_version = true
    compat_info = nothing
    ext_info = nothing
    if new !== nothing && !is_stdlib(new.uuid)
        compat_info = status_compat_info(new, ctx.env, ctx.registries)
        latest_version = compat_info === nothing
        ext_info = status_ext_info(new, ctx.env)
    end
    opts.outdated && latest_version && return nothing
    opts.extensions && ext_info === nothing && return nothing
    deprecation_info = nothing
    pkg_deprecated = false
    if new !== nothing
        pkg_spec = something(new, old)
        deprecation_info = get_pkg_deprecation_info(pkg_spec, ctx.registries)
        pkg_deprecated = deprecation_info !== nothing
    end
    opts.deprecated && !pkg_deprecated && return nothing
    pkg_downloaded = !is_instantiated(new) || is_package_downloaded(ctx.env.manifest_file, new)
    new_ver_available = new !== nothing && !latest_version && !is_tracking_repo(new) && !is_tracking_path(new)
    pkg_upgradable = new_ver_available && compat_info !== nothing && isempty(compat_info[1])
    pkg_heldback = new_ver_available && compat_info !== nothing && !isempty(compat_info[1])
    return PackageStatusData(
        uuid,
        old,
        new,
        pkg_downloaded,
        pkg_upgradable,
        pkg_heldback,
        compat_info,
        changed,
        ext_info,
        deprecation_info,
    )
end

function render_status_entries(report::StatusReport, run::StatusRun)
    for pkg in report.packages
        render_package_entry(pkg, report, run)
    end
end

function render_package_entry(pkg::PackageStatusData, report::StatusReport, run::StatusRun)
    render_entry_prefix(pkg, report, run)
    pkg_spec = something(pkg.new, pkg.old)
    render_entry_badges(pkg, pkg_spec, run)
    render_loaded_warning(pkg, pkg_spec, run)
    render_extension_block(pkg, run)
    println(run.ctx.io)
end

function render_entry_prefix(pkg, report, run::StatusRun)
    ctx, opts, indicators = run.ctx, run.opts, run.indicators
    # Prefix prints download/upgradability markers while keeping column widths stable.
    pad = 0
    print_padding(x) = (print(ctx.io, x); pad += 1)
    if !pkg.downloaded
        print_padding(indicators.missing)
    elseif report.lpadding > 2
        print_padding(" ")
    end
    if pkg.upgradable
        print_padding(indicators.upgradable)
    elseif pkg.heldback
        print_padding(indicators.heldback)
    end
    while pad < report.lpadding
        print_padding(" ")
    end
    printstyled(ctx.io, "[", string(pkg.uuid)[1:8], "] "; color = :light_black)
    if opts.diff
        print_diff(ctx.io, pkg.old, pkg.new)
    else
        print_single(ctx.io, something(pkg.new, pkg.old))
    end
end

function render_entry_badges(pkg::PackageStatusData, pkg_spec::PackageSpec, run::StatusRun)
    ctx, opts = run.ctx, run.opts
    # Badges annotate rows with metadata that users commonly rely on (yanked, deprecated, outdated).
    if is_pkgversion_yanked(pkg_spec, ctx.registries)
        printstyled(ctx.io, " [yanked]"; color = :yellow)
    end
    if pkg.deprecation_info !== nothing
        printstyled(ctx.io, " [deprecated]"; color = :yellow)
    end
    if opts.deprecated && !opts.diff && pkg.deprecation_info !== nothing
        reason = get(pkg.deprecation_info, "reason", nothing)
        alternative = get(pkg.deprecation_info, "alternative", nothing)
        if reason !== nothing
            printstyled(ctx.io, " (reason: ", reason, ")"; color = :yellow)
        end
        if alternative !== nothing
            printstyled(ctx.io, " (alternative: ", alternative, ")"; color = :yellow)
        end
    end
    if opts.outdated && !opts.diff && pkg.compat_data !== nothing
        render_outdated_annotation(pkg, run)
    end
end

function render_outdated_annotation(pkg::PackageStatusData, run::StatusRun)
    ctx = run.ctx
    packages_holding_back, max_version, max_version_compat = pkg.compat_data
    if pkg.new.version !== max_version_compat && max_version_compat != max_version
        printstyled(ctx.io, " [<v", max_version_compat, "]", color = :light_magenta)
        printstyled(ctx.io, ",")
    end
    printstyled(ctx.io, " (<v", max_version, ")"; color = Base.warn_color())
    if packages_holding_back == ["compat"]
        printstyled(ctx.io, " [compat]"; color = :light_magenta)
    elseif packages_holding_back == ["sysimage"]
        printstyled(ctx.io, " [sysimage]"; color = :light_magenta)
    else
        pkg_str = isempty(packages_holding_back) ? "" : string(": ", join(packages_holding_back, ", "))
        printstyled(ctx.io, pkg_str; color = Base.warn_color())
    end
end

function render_loaded_warning(pkg::PackageStatusData, pkg_spec::PackageSpec, run::StatusRun)
    ctx = run.ctx
    pkgid = Base.PkgId(pkg.uuid, pkg_spec.name)
    m = get(Base.loaded_modules, pkgid, nothing)
    if !(m isa Module) || pkg_spec.version === nothing
        return
    end
    loaded_path = pathof(m)
    env_path = Base.locate_package(pkgid)
    if loaded_path === nothing || env_path === nothing || samefile(loaded_path, env_path)
        return
    end
    loaded_version = pkgversion(m)
    env_version = pkg_spec.version
    if loaded_version !== env_version
        printstyled(ctx.io, " [loaded: v$loaded_version]"; color = :light_yellow)
    else
        loaded_version_str = loaded_version === nothing ? "" : " (v$loaded_version)"
        env_version_str = env_version === nothing ? "" : " (v$env_version)"
        printstyled(
            ctx.io,
            " [loaded: `$loaded_path`$loaded_version_str expected `$env_path`$env_version_str]";
            color = :light_yellow,
        )
    end
end

function render_extension_block(pkg::PackageStatusData, run::StatusRun)
    opts = run.opts
    ctx = run.ctx
    if !opts.extensions || opts.diff || pkg.extinfo === nothing
        return
    end
    println(ctx.io)
    for (i, ext) in enumerate(pkg.extinfo)
        sym = i == length(pkg.extinfo) ? '└' : '├'
        print(ctx.io, "              ", sym, "─ ")
        print_extension_entry(ctx.io, ext.ext)
        print(ctx.io, " [")
        join(ctx.io, sprint.(print_extension_entry, ext.weakdeps; context = ctx.io), ", ")
        print(ctx.io, "]")
        i == length(pkg.extinfo) || println(ctx.io)
    end
end

function print_extension_entry(io::IO, entry::Tuple{String, Bool})
    color_val = entry[2] ? :light_green : :light_black
    return printstyled(io, entry[1]; color = color_val)
end

function render_status_footer(report::StatusReport, run::StatusRun)
    ctx, opts, indicators = run.ctx, run.opts, run.indicators
    if !opts.diff && !report.all_packages_downloaded && !isempty(report.packages)
        printpkgstyle(
            ctx.io,
            :Info,
            "Packages marked with $(indicators.missing) are not downloaded, use `instantiate` to download",
            ctx.ignore_indent; color = Base.info_color(),
        )
    end
    if !opts.outdated && (opts.mode != PKGMODE_COMBINED || opts.manifest)
        tipend = opts.manifest ? " -m" : ""
        tip = opts.show_usagetips ? " To see why use `status --outdated$tipend`" : ""
        if !report.no_packages_upgradable && report.no_visible_packages_heldback
            printpkgstyle(
                ctx.io,
                :Info,
                "Packages marked with $(indicators.upgradable) have new versions available and may be upgradable.",
                ctx.ignore_indent; color = Base.info_color(),
            )
        end
        if !report.no_visible_packages_heldback && report.no_packages_upgradable
            printpkgstyle(
                ctx.io,
                :Info,
                "Packages marked with $(indicators.heldback) have new versions available but compatibility constraints restrict them from upgrading.$tip",
                ctx.ignore_indent; color = Base.info_color(),
            )
        end
        if !report.no_visible_packages_heldback && !report.no_packages_upgradable
            printpkgstyle(
                ctx.io,
                :Info,
                "Packages marked with $(indicators.upgradable) and $(indicators.heldback) have new versions available. Those with $(indicators.upgradable) may be upgradable, but those with $(indicators.heldback) are restricted by compatibility constraints from upgrading.$tip",
                ctx.ignore_indent; color = Base.info_color(),
            )
        end
        if !opts.manifest && opts.hidden_upgrades_info && report.no_visible_packages_heldback && !report.no_packages_heldback
            printpkgstyle(
                ctx.io,
                :Info,
                "Some packages have new versions but compatibility constraints restrict them from upgrading.$tip",
                ctx.ignore_indent; color = Base.info_color(),
            )
        end
    end
    any_yanked_packages = any(pkg -> is_pkgversion_yanked(something(pkg.new, pkg.old), ctx.registries), report.packages)
    if any_yanked_packages
        yanked_str = sprint((io, args) -> printstyled(io, args...; color = :yellow), "[yanked]", context = ctx.io)
        printpkgstyle(
            ctx.io,
            :Warning,
            "Package versions marked with $yanked_str have been pulled from their registry. It is recommended to update them to resolve a valid version.",
            ctx.ignore_indent; color = Base.warn_color(),
        )
    end
    any_deprecated_packages = any(pkg -> pkg.deprecation_info !== nothing, report.packages)
    if !opts.deprecated && any_deprecated_packages
        deprecated_str = sprint((io, args) -> printstyled(io, args...; color = :yellow), "[deprecated]", context = ctx.io)
        tipend = opts.manifest ? " -m" : ""
        tip = opts.show_usagetips ? " Use `status --deprecated$tipend` to see more information." : ""
        printpkgstyle(
            ctx.io,
            :Info,
            "Packages marked with $deprecated_str are no longer maintained.$tip",
            ctx.ignore_indent; color = Base.info_color(),
        )
    end
end


function git_head_env(env, project_dir)
    new_env = EnvCache()
    try
        LibGit2.with(LibGit2.GitRepo(project_dir)) do repo
            git_path = LibGit2.path(repo)
            project_path = relpath(env.project_file, git_path)
            manifest_path = relpath(env.manifest_file, git_path)
            new_env.project = read_project(GitTools.git_file_stream(repo, "HEAD:$project_path", fakeit = true))
            new_env.manifest = read_manifest(GitTools.git_file_stream(repo, "HEAD:$manifest_path", fakeit = true))
            return new_env
        end
    catch err
        err isa PkgError || rethrow(err)
        return nothing
    end
end

function show_update(env::EnvCache, registries::Vector{Registry.RegistryInstance}; io::IO, hidden_upgrades_info = false)
    old_env = EnvCache()
    old_env.project = env.original_project
    old_env.manifest = env.original_manifest
    status(env, registries; header = :Updating, mode = PKGMODE_COMBINED, env_diff = old_env, ignore_indent = false, io = io, hidden_upgrades_info)
    return nothing
end

function status(
        env::EnvCache, registries::Vector{Registry.RegistryInstance}, pkgs::Vector{PackageSpec} = PackageSpec[];
        header = nothing, mode::PackageMode = PKGMODE_PROJECT, git_diff::Bool = false, env_diff = nothing, ignore_indent = true,
        io::IO, workspace::Bool = false, outdated::Bool = false, deprecated::Bool = false, extensions::Bool = false, hidden_upgrades_info::Bool = false, show_usagetips::Bool = true
    )
    io == Base.devnull && return
    if header === nothing && env.pkg !== nothing
        readonly_status = env.project.readonly ? " (readonly)" : ""
        printpkgstyle(io, :Project, string(env.pkg.name, " v", env.pkg.version, readonly_status), true; color = Base.info_color())
    end
    old_env = nothing
    if git_diff
        project_dir = dirname(env.project_file)
        git_repo_dir = discover_repo(project_dir)
        if git_repo_dir == nothing
            @warn "diff option only available for environments in git repositories, ignoring."
        else
            old_env = git_head_env(env, git_repo_dir)
            if old_env === nothing
                @warn "could not read project from HEAD, displaying absolute status instead."
            end
        end
    elseif env_diff !== nothing
        old_env = env_diff
    end
    filter_uuids = [pkg.uuid::UUID for pkg in pkgs if pkg.uuid !== nothing]
    filter_names = [pkg.name::String for pkg in pkgs if pkg.name !== nothing]

    diff = old_env !== nothing
    header = something(header, diff ? :Diff : :Status)
    if mode == PKGMODE_PROJECT || mode == PKGMODE_COMBINED
        print_status(env, old_env, registries, header, filter_uuids, filter_names; manifest = false, diff, ignore_indent, io, workspace, outdated, deprecated, extensions, mode, hidden_upgrades_info, show_usagetips)
    end
    if mode == PKGMODE_MANIFEST || mode == PKGMODE_COMBINED
        print_status(env, old_env, registries, header, filter_uuids, filter_names; diff, ignore_indent, io, workspace, outdated, deprecated, extensions, mode, hidden_upgrades_info, show_usagetips)
    end
    return if Types.is_manifest_current(env) === false
        tip = if show_usagetips
            if in_repl_mode()
                " It is recommended to `pkg> resolve` or consider `pkg> update` if necessary."
            else
                " It is recommended to `Pkg.resolve()` or consider `Pkg.update()` if necessary."
            end
        else
            ""
        end
        printpkgstyle(
            io, :Warning, "The project dependencies or compat requirements have changed since the manifest was last resolved.$tip",
            ignore_indent; color = Base.warn_color()
        )
    end
end

"""
    status(ctx::Context, pkgs::Vector{PackageSpec}; kwargs...)

High-level status entry point that routes between compat display and regular status.
Handles validation of flag combinations.
"""
function status(ctx::Context, pkgs::Vector{PackageSpec}; diff::Bool = false, mode = PKGMODE_PROJECT, workspace::Bool = false, outdated::Bool = false, deprecated::Bool = false, compat::Bool = false, extensions::Bool = false, io::IO = stdout_f())
    if compat
        diff && pkgerror("Compat status has no `diff` mode")
        outdated && pkgerror("Compat status has no `outdated` mode")
        deprecated && pkgerror("Compat status has no `deprecated` mode")
        extensions && pkgerror("Compat status has no `extensions` mode")
        print_compat(ctx, pkgs; io)
    else
        status(ctx.env, ctx.registries, pkgs; mode, git_diff = diff, io, outdated, deprecated, extensions, workspace)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Compat helpers
# ---------------------------------------------------------------------------

function compat_line(io, pkg, uuid, compat_str, longest_dep_len; indent = "  ")
    iob = IOBuffer()
    ioc = IOContext(iob, :color => get(io, :color, false)::Bool)
    if isnothing(uuid)
        print(ioc, "$indent           ")
    else
        printstyled(ioc, "$indent[", string(uuid)[1:8], "] "; color = :light_black)
    end
    print(ioc, rpad(pkg, longest_dep_len))
    if isnothing(compat_str)
        printstyled(ioc, " none"; color = :light_black)
    else
        print(ioc, " ", compat_str)
    end
    return String(take!(iob))
end

function print_compat(ctx::Context, pkgs_in::Vector{PackageSpec} = PackageSpec[]; io = nothing)
    io = something(io, ctx.io)
    printpkgstyle(io, :Compat, pathrepr(ctx.env.project_file))
    names = [pkg.name for pkg in pkgs_in]
    pkgs = isempty(pkgs_in) ? ctx.env.project.deps : filter(pkg -> in(first(pkg), names), ctx.env.project.deps)
    add_julia = isempty(pkgs_in) || any(p -> p.name == "julia", pkgs_in)
    longest_dep_len = isempty(pkgs) ? length("julia") : max(reduce(max, map(length, collect(keys(pkgs)))), length("julia"))
    if add_julia
        println(io, compat_line(io, "julia", nothing, get_compat_str(ctx.env.project, "julia"), longest_dep_len))
    end
    for (dep, uuid) in pkgs
        println(io, compat_line(io, dep, uuid, get_compat_str(ctx.env.project, dep), longest_dep_len))
    end
    return
end
print_compat(pkg::String; kwargs...) = print_compat(Context(), pkg; kwargs...)
print_compat(; kwargs...) = print_compat(Context(); kwargs...)

end # module
