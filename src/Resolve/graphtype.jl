# This file is a part of Julia. License is MIT: https://julialang.org/license

# The ResolveLog is used to keep track of events that take place during the
# resolution process. We use one ResolveLogEntry per package, and record all events
# associated with that package. An event consists of two items: another
# entry representing another package's influence (or `nothing`) and
# a message for the log.
#
# Specialized functions called `log_event_[...]!` are used to store the
# various events. The events are also recorded in order in a shared
# ResolveJournal, which is used to provide a plain chronological view.
#
# The `showlog` functions are used for display, and called to create messages
# in case of resolution errors.

const UUID0 = UUID(UInt128(0))

const ResolveJournal = Vector{Tuple{UUID, String}}

mutable struct ResolveLogEntry
    journal::ResolveJournal # shared with all other entries
    pkg::UUID
    header::String
    events::Vector{Tuple{Any, String}} # here Any should ideally be Union{ResolveLogEntry,Nothing}
    ResolveLogEntry(journal::ResolveJournal, pkg::UUID, header::String = "") = new(journal, pkg, header, [])
end

function Base.push!(entry::ResolveLogEntry, reason::Tuple{Union{ResolveLogEntry, Nothing}, String}, to_journal::Bool = true)
    push!(entry.events, reason)
    to_journal && entry.pkg ≠ uuid_julia && push!(entry.journal, (entry.pkg, reason[2]))
    return entry
end

mutable struct ResolveLog
    # init: used to keep track of all package entries which were created during
    #       initialization, since the `pool` can be pruned during the resolution
    #       process.
    init::ResolveLogEntry

    # globals: records global events not associated to any particular package
    globals::ResolveLogEntry

    # pool: records entries associated to each package
    pool::Dict{UUID, ResolveLogEntry}

    # journal: record all messages in order (shared between all entries)
    journal::ResolveJournal

    # exact: keeps track of whether the resolve process is still exact, or
    #        heuristics have been employed
    exact::Bool

    # verbose: print global events messages on screen
    verbose::Bool

    # UUID to names
    uuid_to_name::Dict{UUID, String}

    function ResolveLog(uuid_to_name::Dict{UUID, String}, verbose::Bool = false)
        journal = ResolveJournal()
        init = ResolveLogEntry(journal, UUID0, "")
        globals = ResolveLogEntry(journal, UUID0, "Global events:")
        return new(init, globals, Dict{UUID, ResolveLogEntry}(), journal, true, verbose, uuid_to_name)
    end
end

# Installation state: either a version, or uninstalled
const InstState = Union{VersionNumber, Nothing}


# GraphData is basically a part of Graph that collects data structures useful
# for interfacing the internal abstract representation of Graph with the
# input/output (e.g. converts between package UUIDs and node numbers, etc.)
mutable struct GraphData
    # packages list
    pkgs::Vector{UUID}

    # number of packages
    np::Int

    # states per package: one per version + uninstalled
    spp::Vector{Int}

    # package dict: associates an index to each package id
    pdict::Dict{UUID, Int}

    # package versions: for each package, keep the list of the
    #                   possible version numbers; this defines a
    #                   mapping from version numbers of a package
    #                   to indices
    pvers::Vector{Vector{VersionNumber}}

    # versions dict: associates a version index to each package
    #                version; such that
    #                  pvers[p0][vdict[p0][vn]] = vn
    vdict::Vector{Dict{VersionNumber, Int}}

    # UUID to names
    uuid_to_name::Dict{UUID, String}

    # pruned packages: during graph simplification, packages that
    #                  only have one allowed version are pruned.
    #                  This keeps track of them, so that they may
    #                  be returned in the solution (unless they
    #                  were explicitly fixed)
    pruned::Dict{UUID, VersionNumber}

    # equivalence classes: for each package and each of its possible
    #                      states, keep track of other equivalent states
    eq_classes::Dict{UUID, Dict{InstState, Set{InstState}}}

    # resolve log: keep track of the resolution process
    rlog::ResolveLog

    function GraphData(
            compat_compressed::Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}},
            pkg_versions::Dict{UUID, Vector{VersionNumber}},
            uuid_to_name::Dict{UUID, String},
            verbose::Bool = false
        )
        # generate pkgs
        pkgs = sort!(collect(keys(pkg_versions)))
        np = length(pkgs)

        # generate pdict
        pdict = Dict{UUID, Int}(pkgs[p0] => p0 for p0 in 1:np)

        # generate spp and pvers from provided version lists
        pvers = [pkg_versions[pkgs[p0]] for p0 in 1:np]
        spp = length.(pvers) .+ 1

        # generate vdict
        vdict = [Dict{VersionNumber, Int}(vn => i for (i, vn) in enumerate(pvers[p0])) for p0 in 1:np]

        # nothing is pruned yet, of course
        pruned = Dict{UUID, VersionNumber}()

        # equivalence classes (at the beginning each state represents just itself)
        eq_vn(v0, p0) = (v0 == spp[p0] ? nothing : pvers[p0][v0])

        # Hot code, measure performance before changing
        eq_classes = Dict{UUID, Dict{InstState, Set{InstState}}}()
        for p0 in 1:np
            d = Dict{InstState, Set{InstState}}()
            for v0 in 1:spp[p0]
                let p0 = p0 # Due to https://github.com/JuliaLang/julia/issues/15276
                    d[eq_vn(v0, p0)] = Set{InstState}((eq_vn(v0, p0),))
                end
            end
            eq_classes[pkgs[p0]] = d
        end

        # the resolution log is actually initialized below
        rlog = ResolveLog(uuid_to_name, verbose)

        data = new(pkgs, np, spp, pdict, pvers, vdict, uuid_to_name, pruned, eq_classes, rlog)

        init_log!(data)

        return data
    end

    function Base.copy(data::GraphData)
        pkgs = copy(data.pkgs)
        np = data.np
        spp = copy(data.spp)
        pdict = copy(data.pdict)
        pvers = [copy(data.pvers[p0]) for p0 in 1:np]
        vdict = [copy(data.vdict[p0]) for p0 in 1:np]
        pruned = copy(data.pruned)
        eq_classes = Dict(p => copy(eq) for (p, eq) in data.eq_classes)
        rlog = deepcopy(data.rlog)
        uuid_to_name = rlog.uuid_to_name

        return new(pkgs, np, spp, pdict, pvers, vdict, uuid_to_name, pruned, eq_classes, rlog)
    end
end

mutable struct Graph
    # data:
    #   stores all the structures required to map between
    #   parsed items (names, UUIDS, version numbers...) and
    #   the numeric representation used in the main Graph data
    #   structure.
    data::GraphData

    # adjacency matrix:
    #   for each package, has the list of neighbors
    #   indices
    gadj::Vector{Vector{Int}}

    # compatibility mask:
    #   for each package p0 has a list of bool masks.
    #   Each entry in the list gmsk[p0] is relative to the
    #   package p1 as read from gadj[p0].
    #   Each mask has dimension spp1 × spp0, where
    #   spp0 is the number of states of p0, and
    #   spp1 is the number of states of p1.
    gmsk::Vector{Vector{BitMatrix}}

    # constraints:
    #   a mask of allowed states for each package (e.g. to express
    #   requirements)
    gconstr::Vector{BitVector}

    # adjacency dict:
    #   allows one to retrieve the indices in gadj, so that
    #   gadj[p0][adjdict[p1][p0]] = p1
    #   ("At which index does package p1 appear in gadj[p0]?")
    adjdict::Vector{Dict{Int, Int}}

    # indices of the packages that were *explicitly* required
    #   used to favor their versions at resolution
    req_inds::Set{Int}

    # indices of the packages that were *explicitly* fixed
    #   used to avoid returning them in the solution
    fix_inds::Set{Int}

    ignored::BitVector

    # stack of constraints/ignored packages:
    #   allows to keep a sort of "versioning" of the constraints
    #   such that the solver can implement tentative solutions
    solve_stack::Vector{Tuple{Vector{BitVector}, BitVector}}

    # states per package: same as in GraphData
    spp::Vector{Int}

    # number of packages (all Vectors above have this length)
    np::Int

    # some workspace vectors
    newmsg::Vector{FieldValue}
    diff::Vector{FieldValue}
    cavfld::Vector{FieldValue}

    function Graph(
            deps_compressed::Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}},
            compat_compressed::Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}},
            weak_deps_compressed::Dict{UUID, Vector{Dict{VersionRange, Set{UUID}}}},
            weak_compat_compressed::Dict{UUID, Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}},
            pkg_versions::Dict{UUID, Vector{VersionNumber}},
            pkg_versions_per_registry::Dict{UUID, Vector{Set{VersionNumber}}},
            uuid_to_name::Dict{UUID, String},
            reqs::Requires,
            fixed::Dict{UUID, Fixed},
            verbose::Bool = false,
            julia_version::Union{VersionNumber, Nothing} = VERSION
        )

        # Tell the resolver about julia itself
        uuid_to_name[uuid_julia] = "julia"
        if julia_version !== nothing
            fixed[uuid_julia] = Fixed(julia_version)
            deps_compressed[uuid_julia] = [Dict{VersionRange, Set{UUID}}()]
            compat_compressed[uuid_julia] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
            weak_deps_compressed[uuid_julia] = [Dict{VersionRange, Set{UUID}}()]
            weak_compat_compressed[uuid_julia] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
            pkg_versions[uuid_julia] = [julia_version]
            pkg_versions_per_registry[uuid_julia] = [Set([julia_version])]
        else
            deps_compressed[uuid_julia] = [Dict{VersionRange, Set{UUID}}()]
            compat_compressed[uuid_julia] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
            weak_deps_compressed[uuid_julia] = [Dict{VersionRange, Set{UUID}}()]
            weak_compat_compressed[uuid_julia] = [Dict{VersionRange, Dict{UUID, VersionSpec}}()]
            pkg_versions[uuid_julia] = VersionNumber[]
            pkg_versions_per_registry[uuid_julia] = [Set{VersionNumber}()]
        end

        data = GraphData(compat_compressed, pkg_versions, uuid_to_name, verbose)
        pkgs, np, spp, pdict, pvers, vdict, rlog = data.pkgs, data.np, data.spp, data.pdict, data.pvers, data.vdict, data.rlog
        extended_deps = let spp = spp # Due to https://github.com/JuliaLang/julia/issues/15276
            [Vector{Dict{Int, BitVector}}(undef, spp[p0] - 1) for p0 in 1:np]
        end
        vnmap = Dict{UUID, VersionSpec}()
        reg_result = Dict{UUID, VersionSpec}()
        req = Dict{Int, VersionSpec}()
        for p0 in 1:np
            uuid0 = pkgs[p0]

            # Query compressed deps and compat data for this version (including weak deps)
            # We have a vector of per-registry dictionaries, need to query across all
            uuid0_deps_list = get(Vector{Dict{VersionRange, Set{UUID}}}, deps_compressed, uuid0)
            uuid0_compat_list = get(Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}, compat_compressed, uuid0)
            uuid0_weak_deps_list = get(Vector{Dict{VersionRange, Set{UUID}}}, weak_deps_compressed, uuid0)
            uuid0_weak_compat_list = get(Vector{Dict{VersionRange, Dict{UUID, VersionSpec}}}, weak_compat_compressed, uuid0)
            uuid0_versions_per_reg = get(Vector{Set{VersionNumber}}, pkg_versions_per_registry, uuid0)

            for v0 in 1:(spp[p0] - 1)
                vn = pvers[p0][v0]
                empty!(req)
                Registry.query_compat_for_version_multi_registry!(vnmap, reg_result, uuid0_deps_list, uuid0_compat_list, uuid0_weak_deps_list, uuid0_weak_compat_list, uuid0_versions_per_reg, vn)

                # Filter out incompatible stdlib compat entries from registry dependencies
                for (dep_uuid, dep_compat) in vnmap
                    if Types.is_stdlib(dep_uuid) && !(dep_uuid in Types.UPGRADABLE_STDLIBS_UUIDS)
                        stdlib_ver = Types.stdlib_version(dep_uuid, julia_version)
                        if stdlib_ver !== nothing && !isempty(dep_compat) && !(stdlib_ver in dep_compat)
                            @debug "Ignoring incompatible stdlib compat entry" dep = get(uuid_to_name, dep_uuid, string(dep_uuid)) stdlib_ver dep_compat package = uuid_to_name[uuid0] version = vn
                            delete!(vnmap, dep_uuid)
                        end
                    end
                end

                for (uuid1, vs) in vnmap
                    p1 = pdict[uuid1]
                    p1 == p0 && error("Package $(pkgID(pkgs[p0], uuid_to_name)) version $vn has a dependency with itself")
                    # check conflicts instead of intersecting?
                    # (intersecting is used by fixed packages though...)
                    req_p1 = get(req, p1, nothing)
                    if req_p1 == nothing
                        req[p1] = vs
                    else
                        req[p1] = req_p1 ∩ vs
                    end
                end

                # Translate the requirements into bit masks
                # Hot code, measure performance before changing
                req_msk = Dict{Int, BitVector}()
                sizehint!(req_msk, length(req))

                for (p1, vs) in req
                    pv = pvers[p1]
                    # Allocate BitVector with space for weak dep flag
                    req_msk_p1 = BitVector(undef, spp[p1])
                    # Use optimized batch version check (fills indices 1 through spp[p1]-1)
                    Versions.matches_spec_range!(req_msk_p1, pv, vs, spp[p1] - 1)
                    # Check if this is a weak dep across all registries
                    weak = false
                    for weak_deps_dict in uuid0_weak_deps_list
                        if Registry.is_weak_dep(weak_deps_dict, vn, pkgs[p1])
                            weak = true
                            break
                        end
                    end
                    req_msk_p1[end] = weak
                    req_msk[p1] = req_msk_p1
                end
                extended_deps[p0][v0] = req_msk
            end
        end

        gadj = [Int[] for p0 in 1:np]
        gmsk = [BitMatrix[] for p0 in 1:np]
        gconstr = let spp = spp # Due to https://github.com/JuliaLang/julia/issues/15276
            [trues(spp[p0]) for p0 in 1:np]
        end
        adjdict = [Dict{Int, Int}() for p0 in 1:np]

        for p0 in 1:np, v0 in 1:(spp[p0] - 1), (p1, rmsk1) in extended_deps[p0][v0]
            @assert p0 ≠ p1
            j0 = get(adjdict[p1], p0, length(gadj[p0]) + 1)
            j1 = get(adjdict[p0], p1, length(gadj[p1]) + 1)

            @assert (j0 > length(gadj[p0]) && j1 > length(gadj[p1])) ||
                (j0 ≤ length(gadj[p0]) && j1 ≤ length(gadj[p1]))

            if j0 > length(gadj[p0])
                push!(gadj[p0], p1)
                push!(gadj[p1], p0)
                j0 = length(gadj[p0])
                j1 = length(gadj[p1])

                adjdict[p1][p0] = j0
                adjdict[p0][p1] = j1

                bm = trues(spp[p1], spp[p0])
                bmt = trues(spp[p0], spp[p1])

                push!(gmsk[p0], bm)
                push!(gmsk[p1], bmt)
            else
                bm = gmsk[p0][j0]
                bmt = gmsk[p1][j1]
            end

            @inbounds for v1 in 1:spp[p1]
                rmsk1[v1] && continue
                bm[v1, v0] = false
                bmt[v0, v1] = false
            end
        end

        req_inds = Set{Int}()
        fix_inds = Set{Int}()

        ignored = falses(np)
        solve_stack = Tuple{Vector{BitVector}, BitVector}[]

        graph = new(
            data, gadj, gmsk, gconstr, adjdict, req_inds, fix_inds, ignored, solve_stack, spp, np,
            FieldValue[], FieldValue[], FieldValue[]
        )

        _add_fixed!(graph, fixed)
        _add_reqs!(graph, reqs, :explicit_requirement)

        @assert check_consistency(graph)
        check_constraints(graph)

        return graph
    end

    function Base.copy(graph::Graph)
        data = copy(graph.data)
        np = graph.np
        spp = data.spp
        gadj = [copy(graph.gadj[p0]) for p0 in 1:np]
        gmsk = [[copy(graph.gmsk[p0][j0]) for j0 in 1:length(gadj[p0])] for p0 in 1:np]
        gconstr = [copy(graph.gconstr[p0]) for p0 in 1:np]
        adjdict = [copy(graph.adjdict[p0]) for p0 in 1:np]
        req_inds = copy(graph.req_inds)
        fix_inds = copy(graph.fix_inds)
        ignored = copy(graph.ignored)
        solve_stack = [([copy(gc0) for gc0 in sav_gconstr], copy(sav_ignored)) for (sav_gconstr, sav_ignored) in graph.solve_stack]

        return new(data, gadj, gmsk, gconstr, adjdict, req_inds, fix_inds, ignored, solve_stack, spp, np)
    end
end


"""
Add explicit requirements to the graph.
"""
function add_reqs!(graph::Graph, reqs::Requires)
    _add_reqs!(graph, reqs, :explicit_requirement)
    check_constraints(graph)
    # TODO: add reqs to graph data?
    return graph
end

function _add_reqs!(graph::Graph, reqs::Requires, reason; weak_reqs::Set{UUID} = Set{UUID}())
    gconstr = graph.gconstr
    spp = graph.spp
    req_inds = graph.req_inds
    pdict = graph.data.pdict
    pvers = graph.data.pvers

    for (rp, rvs) in reqs
        haskey(pdict, rp) || error("unknown required package $(pkgID(rp, graph))")
        rp0 = pdict[rp]
        new_constr = trues(spp[rp0])
        for rv0 in 1:(spp[rp0] - 1)
            rvn = pvers[rp0][rv0]
            rvn ∈ rvs || (new_constr[rv0] = false)
        end
        weak = rp ∈ weak_reqs
        new_constr[end] = weak
        old_constr = copy(gconstr[rp0])
        gconstr[rp0] .&= new_constr
        reason ≡ :explicit_requirement && push!(req_inds, rp0)
        old_constr ≠ gconstr[rp0] && log_event_req!(graph, rp, rvs, reason)
    end
    return graph
end

"Add fixed packages to the graph, and their requirements."
function add_fixed!(graph::Graph, fixed::Dict{UUID, Fixed})
    _add_fixed!(graph, fixed)
    check_constraints(graph)
    # TODO: add fixed to graph data?
    return graph
end

function _add_fixed!(graph::Graph, fixed::Dict{UUID, Fixed})
    gconstr = graph.gconstr
    spp = graph.spp
    fix_inds = graph.fix_inds
    pdict = graph.data.pdict
    vdict = graph.data.vdict

    for (fp, fx) in fixed
        haskey(pdict, fp) || error("unknown fixed package $(pkgID(fp, graph))")
        fp0 = pdict[fp]
        fv0 = vdict[fp0][fx.version]
        new_constr = falses(spp[fp0])
        new_constr[fv0] = true
        gconstr[fp0] .&= new_constr
        push!(fix_inds, fp0)
        bkitem = log_event_fixed!(graph, fp, fx)
        _add_reqs!(graph, fx.requires, (fp, bkitem); weak_reqs = fx.weak)
    end
    return graph
end

pkgID(p::UUID, rlog::ResolveLog) = pkgID(p, rlog.uuid_to_name)
pkgID(p::UUID, data::GraphData) = pkgID(p, data.uuid_to_name)
pkgID(p0::Int, data::GraphData) = pkgID(data.pkgs[p0], data)
pkgID(p, graph::Graph) = pkgID(p, graph.data)

## user-friendly representation of package IDs ##
function pkgID(p::UUID, uuid_to_name::Dict{UUID, String})
    name = get(uuid_to_name, p, "(unknown)")
    uuid_short = string(p)[1:8]
    return "$name [$uuid_short]"
end

function check_consistency(graph::Graph)
    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    gmsk = graph.gmsk
    gconstr = graph.gconstr
    adjdict = graph.adjdict
    req_inds = graph.req_inds
    fix_inds = graph.fix_inds
    ignored = graph.ignored
    solve_stack = graph.solve_stack
    data = graph.data
    pkgs = data.pkgs
    pdict = data.pdict
    pvers = data.pvers
    vdict = data.vdict
    pruned = data.pruned
    eq_classes = data.eq_classes
    rlog = data.rlog
    # TODO: check ignored and solve_stack

    @assert np ≥ 0
    @assert data.spp ≡ spp
    for x in Any[spp, gadj, gmsk, gconstr, adjdict, ignored, rlog.pool, pkgs, pdict, pvers, vdict]
        @assert length(x)::Int == np
    end
    for p0 in 1:np
        @assert pdict[pkgs[p0]] == p0
        spp0 = spp[p0]
        @assert spp0 ≥ 1
        pvers0 = pvers[p0]
        vdict0 = vdict[p0]
        @assert length(pvers0) == spp0 - 1
        for v0 in 1:(spp0 - 1)
            @assert vdict0[pvers0[v0]] == v0
        end
        for (vn, v0) in vdict0
            @assert 1 ≤ v0 ≤ spp0 - 1
            @assert pvers0[v0] == vn
        end
        gconstr0 = gconstr[p0]
        @assert length(gconstr0) == spp0

        gadj0 = gadj[p0]
        gmsk0 = gmsk[p0]
        adjdict0 = adjdict[p0]
        @assert length(gmsk0) == length(gadj0)
        @assert length(adjdict0) == length(gadj0)
        for (j0, p1) in enumerate(gadj0)
            @assert p1 ≠ p0
            @assert adjdict[p1][p0] == j0
            spp1 = spp[p1]
            @assert size(gmsk0[j0]) == (spp1, spp0)
            j1 = adjdict0[p1]
            gmsk1 = gmsk[p1]
            # This assert is a bit too expensive
            # @assert gmsk1[j1] == permutedims(gmsk0[j0])
        end
    end
    for (p, p0) in pdict
        @assert 1 ≤ p0 ≤ np
        @assert pkgs[p0] == p
        @assert !haskey(pruned, p)
    end
    for p0 in req_inds
        @assert 1 ≤ p0 ≤ np
        @assert !gconstr[p0][end]
    end
    for p0 in fix_inds
        @assert 1 ≤ p0 ≤ np
        @assert !gconstr[p0][end]
        @assert count(gconstr[p0]) ≤ 1 # note: the 0 case should be handled by check_constraints
    end

    for (p, eq_cl) in eq_classes, (rvn, rvs) in eq_cl
        @assert rvn ∈ rvs
    end

    for (sav_gconstr, sav_ignored) in solve_stack
        @assert length(sav_ignored) == np
        @assert length(sav_gconstr) == np
        for p0 in 1:np
            @assert length(sav_gconstr[p0]) == spp[p0]
        end
    end

    return true
end

function push_snapshot!(graph::Graph)
    np = graph.np
    gconstr = graph.gconstr
    ignored = graph.ignored
    solve_stack = graph.solve_stack
    sav_gconstr = [copy(gc0) for gc0 in gconstr]
    sav_ignored = copy(ignored)
    push!(solve_stack, (gconstr, ignored))
    graph.gconstr = sav_gconstr
    graph.ignored = sav_ignored
    return graph
end

function pop_snapshot!(graph::Graph)
    np = graph.np
    solve_stack = graph.solve_stack
    @assert length(solve_stack) > 0
    sav_gconstr, sav_ignored = pop!(graph.solve_stack)
    graph.gconstr = sav_gconstr
    graph.ignored = sav_ignored
    return graph
end

function wipe_snapshots!(graph::Graph)
    np = graph.np
    solve_stack = graph.solve_stack
    if length(solve_stack) > 0
        graph.gconstr, graph.ignored = first(solve_stack)
        empty!(solve_stack)
    end
    return graph
end

# system colors excluding whites/greys/blacks and error-red
const CONFLICT_COLORS = [1:6; 10:14];
pkgID_color(pkgID) = CONFLICT_COLORS[mod1(hash(pkgID), end)]

logstr(pkgID) = logstr(pkgID, pkgID)
function logstr(pkgID, args...)
    # workout the string with the color codes, check stderr to decide if color is enabled
    return sprint(args; context = stderr::IO) do io, iargs
        printstyled(io, iargs...; color = pkgID_color(pkgID))
    end
end

"""
    range_compressed_versionspec(pool, subset=pool)

 - `pool`: all versions that exist (a superset of `subset`)
 - `subset`: the subset of those versions that we want to include in the spec.

Finds a minimal collection of ranges as a `VersionSpec`, that permits everything in the
`subset`, but does not permit anything else from the `pool`.
"""
function range_compressed_versionspec(pool, subset = pool)
    length(subset) == 1 && return VersionSpec(only(subset))
    # PREM-OPT: we keep re-sorting these, probably not required.
    sort!(pool)
    sort!(subset)
    @assert subset ⊆ pool

    contiguous_subsets = VersionRange[]

    range_start = first(subset)
    pool_ii = findfirst(isequal(range_start), pool) + 1  # skip-forward til we have started
    for s in @view subset[2:end]
        if s != pool[pool_ii]
            range_end = pool[pool_ii - 1]  # previous element was last in this range
            push!(contiguous_subsets, VersionRange(range_start, range_end))
            range_start = s  # start a new range
            while (s != pool[pool_ii])  # advance til time to start
                pool_ii += 1
            end
        end
        pool_ii += 1
    end
    push!(contiguous_subsets, VersionRange(range_start, last(subset)))

    return VersionSpec(contiguous_subsets)
end

function init_log!(data::GraphData)
    np = data.np
    pkgs = data.pkgs
    pvers = data.pvers
    rlog = data.rlog
    for p0 in 1:np
        p = pkgs[p0]
        reginfo = registry_info(p) # TODO: p::UUID - need to convert to PkgEntry
        id = pkgID(p0, data)
        versions = pvers[p0]
        if isempty(versions)
            msg = "$(logstr(id)) has no known versions!" # This shouldn't happen?
        else
            not_yanked_versions = [ver.v for ver in versions if !isyanked(reginfo, ver)]
            vspec = range_compressed_versionspec(versions, not_yanked_versions)
            vers = logstr(id, vspec)
            uuid = data.pkgs[p0]
            name = data.uuid_to_name[uuid]
            pkgid = Base.PkgId(uuid, name)
            msg = "possible versions are: $vers or uninstalled"
            if Base.in_sysimage(pkgid)
                msg *= " (package in sysimage!)"
            end
        end
        first_entry = get!(rlog.pool, p) do
            ResolveLogEntry(rlog.journal, p, "$(logstr(id)) log:")
        end

        if p ≠ uuid_julia
            push!(first_entry, (nothing, msg))
            push!(rlog.init, (first_entry, ""), false)
        end
    end
    return data
end

function log_event_fixed!(graph::Graph, fp::UUID, fx::Fixed)
    rlog = graph.data.rlog
    id = pkgID(fp, rlog)
    msg = "$(logstr(id)) is fixed to version $(logstr(id, fx.version))"
    entry = rlog.pool[fp]
    push!(entry, (nothing, msg))
    return entry
end

function _vs_string(p0::Int, vmask::BitVector, id::String, pvers::Vector{Vector{VersionNumber}})
    if any(vmask[1:(end - 1)])
        vspec = range_compressed_versionspec(pvers[p0], pvers[p0][vmask[1:(end - 1)]])
        vns = logstr(id, vspec)
        vmask[end] && (vns *= " or uninstalled")
    else
        @assert vmask[end]
        vns = "uninstalled"
    end
    return vns
end

function log_event_req!(graph::Graph, rp::UUID, rvs::VersionSpec, reason)
    rlog = graph.data.rlog
    gconstr = graph.gconstr
    pdict = graph.data.pdict
    pvers = graph.data.pvers
    id = pkgID(rp, rlog)
    msg = "restricted to versions $(logstr(id, rvs)) by "
    if reason isa Symbol
        @assert reason === :explicit_requirement
        other_entry = nothing
        msg *= "an explicit requirement"
    else
        other_p, other_entry = reason::Tuple{UUID, ResolveLogEntry}
        if other_p == uuid_julia
            msg *= "julia compatibility requirements"
            other_entry = nothing # don't propagate the log
        else
            msg *= logstr(pkgID(other_p, rlog))
        end
    end
    rp0 = pdict[rp]
    @assert !gconstr[rp0][end] || reason ≢ :explicit_requirement
    if any(gconstr[rp0])
        msg *= ", leaving only versions: $(_vs_string(rp0, gconstr[rp0], id, pvers))"
    else
        msg *= " — no versions left"
    end
    entry = rlog.pool[rp]
    push!(entry, (other_entry, msg))
    return entry
end

function log_event_pin!(graph::Graph, p::UUID, vn::VersionNumber)
    rlog = graph.data.rlog
    id = pkgID(p, rlog)
    msg = "pinned to version $(logstr(id, vn)) during version validation"
    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

function log_event_validate!(graph::Graph, p0::Int, vmask::BitVector)
    rlog = graph.data.rlog
    gconstr = graph.gconstr
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p0]
    id = pkgID(p, rlog)

    @assert any(gconstr[p0])
    nrem = count(vmask)
    @assert nrem > 0
    uninst_removed = vmask[end]

    msg = "restricted by version validation to versions: $(_vs_string(p0, gconstr[p0], id, pvers))"
    if nrem == 1 && uninst_removed
        msg *= " (uninstalled state disallowed)"
    else
        msg *= " ($(nrem)/$(length(vmask)) versions removed"
        if uninst_removed
            msg *= ", including uninstalled"
        end
        msg *= ")"
    end
    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

function log_event_global!(graph::Graph, msg::String)
    rlog = graph.data.rlog
    rlog.verbose && @info(msg)
    return push!(rlog.globals, (nothing, msg))
end

function log_event_implicit_req!(graph::Graph, p1::Int, vmask::BitVector, p0::Int)
    rlog = graph.data.rlog
    gconstr = graph.gconstr
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p1]
    id = pkgID(p, rlog)

    other_p, other_entry = pkgs[p0], rlog.pool[pkgs[p0]]
    other_id = pkgID(other_p, rlog)
    if any(vmask)
        if all(vmask[1:(end - 1)])    # Check if all versions are allowed (except uninstalled)
            @assert other_p ≠ uuid_julia
            msg = "required (without additional version restrictions) by $(logstr(other_id))"
        else
            msg = "restricted by "
            if other_p == uuid_julia
                msg *= "julia compatibility requirements "
                other_entry = nothing # don't propagate the log
            else
                msg *= "compatibility requirements with $(logstr(other_id)) "
            end
            msg *= "to versions: $(_vs_string(p1, vmask, id, pvers))"
            if vmask ≠ gconstr[p1]
                if any(gconstr[p1])
                    msg *= ", leaving only versions: $(_vs_string(p1, gconstr[p1], id, pvers))"
                else
                    msg *= " — no versions left"
                end
            end
        end
    else
        msg = "found to have no compatible versions left with "
        if other_p == uuid_julia
            msg *= "julia"
            other_entry = nothing # don't propagate the log
        else
            msg *= logstr(other_id)
        end
    end
    entry = rlog.pool[p]
    push!(entry, (other_entry, msg))
    return entry
end

function log_event_pruned!(graph::Graph, p0::Int, s0::Int)
    rlog = graph.data.rlog
    spp = graph.spp
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p0]
    id = pkgID(p, rlog)
    if s0 == spp[p0]
        msg = "determined to be unneeded during graph pruning"
    else
        ver = logstr(id, pvers[p0][s0])
        msg = "fixed during graph pruning to its only remaining available version, $ver"
    end
    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

function log_event_greedysolved!(graph::Graph, p0::Int, s0::Int)
    rlog = graph.data.rlog
    spp = graph.spp
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p0]
    id = pkgID(p, rlog)
    if s0 == spp[p0]
        msg = "determined to be unneeded by the solver"
    else
        ver = logstr(id, pvers[p0][s0])
        if s0 == spp[p0] - 1
            msg = "set by the solver to its maximum version: $ver"
        else
            msg = "set by the solver to the maximum version compatible with the constraints: $ver"
        end
    end
    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

function log_event_maxsumsolved!(graph::Graph, p0::Int, s0::Int, why::Symbol)
    rlog = graph.data.rlog
    spp = graph.spp
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p0]
    id = pkgID(p, rlog)
    if s0 == spp[p0]
        @assert why === :uninst
        msg = "determined to be unneeded by the solver"
    else
        @assert why === :constr
        ver = logstr(id, pvers[p0][s0])
        if s0 == spp[p0] - 1
            msg = "set by the solver to its maximum version: $ver"
        else
            xver = logstr(id, pvers[p0][s0 + 1])
            msg = "set by the solver to version: $ver (version $xver would violate its constraints)"
        end
    end
    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

function log_event_maxsumsolved!(graph::Graph, p0::Int, s0::Int, p1::Int)
    rlog = graph.data.rlog
    spp = graph.spp
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p0]
    id = pkgID(p, rlog)
    other_id = pkgID(pkgs[p1], rlog)
    @assert s0 ≠ spp[p0]
    ver = logstr(id, pvers[p0][s0])
    if s0 == spp[p0] - 1
        msg = "set by the solver to its maximum version: $ver (installation is required by $other_id)"
    else
        xver = logstr(id, pvers[p0][s0 + 1])
        msg = "set by the solver version: $ver (version $xver would violate a dependency relation with $other_id)"
    end
    other_entry = rlog.pool[pkgs[p1]]
    entry = rlog.pool[p]
    push!(entry, (other_entry, msg))
    return entry
end

function log_event_eq_classes!(graph::Graph, p0::Int)
    rlog = graph.data.rlog
    spp = graph.spp
    gconstr = graph.gconstr
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers

    p = pkgs[p0]
    id = pkgID(p, rlog)
    msg = "versions reduced by equivalence to: "

    if any(gconstr[p0][1:(end - 1)])
        vspec = range_compressed_versionspec(pvers[p0], pvers[p0][gconstr[p0][1:(end - 1)]])
        msg *= logstr(id, vspec)
        gconstr[p0][end] && (msg *= " or uninstalled")
    elseif gconstr[p0][end]
        msg *= "uninstalled"
    else
        msg *= "no version"
    end

    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

function log_event_maxsumtrace!(graph::Graph, p0::Int, s0::Int)
    rlog = graph.data.rlog
    rlog.exact = false
    p = graph.data.pkgs[p0]
    id = pkgID(p, rlog)
    if s0 < graph.spp[p0]
        ver = logstr(id, graph.data.pvers[p0][s0])
        msg = "fixed by the MaxSum heuristic to version $ver"
    else
        msg = "determined to be unneeded by the MaxSum heuristic"
    end
    entry = rlog.pool[p]
    push!(entry, (nothing, msg))
    return entry
end

"Get the resolution log, detached"
get_resolve_log(graph::Graph) = deepcopy(graph.data.rlog)

const _logindent = " "

showlog(graph::Graph, args...; kw...) = showlog(stdout_f(), graph, args...; kw...)
showlog(io::IO, graph::Graph, args...; kw...) = showlog(io, graph.data.rlog, args...; kw...)
showlog(rlog::ResolveLog, args...; kw...) = showlog(stdout_f(), rlog, args...; kw...)

"""
Show the full resolution log. The `view` keyword controls how the events are displayed/grouped:

 * `:plain` for a shallow view, grouped by package, alphabetically (the default)
 * `:tree` for a tree view in which the log of a package is displayed as soon as it appears
           in the process (the top-level is still grouped by package, alphabetically)
 * `:chronological` for a flat view of all events in chronological order
"""
function showlog(io::IO, rlog::ResolveLog; view::Symbol = :plain)
    view ∈ [:plain, :tree, :chronological] || throw(ArgumentError("the view argument should be `:plain`, `:tree` or `:chronological`"))
    println(io, "Resolve log:")
    view === :chronological && return showlogjournal(io, rlog)
    seen = IdDict()
    recursive = (view === :tree)
    _show(io, rlog, rlog.globals, _logindent, seen, false)
    initentries = Union{ResolveLogEntry, Nothing}[event[1]::Union{ResolveLogEntry, Nothing} for event in rlog.init.events]
    for entry in sort!(initentries, by = (entry -> pkgID(entry.pkg, rlog)))
        seen[entry] = true
        _show(io, rlog, entry, _logindent, seen, recursive)
    end
    return
end

ansi_length(s) = textwidth(replace(s, r"\e\[[0-9]+(?:;[0-9]+)*m" => ""))

function showlogjournal(io::IO, rlog::ResolveLog)
    journal = rlog.journal
    id(p) = p == UUID0 ? "[global event]" : logstr(pkgID(p, rlog))
    padding = maximum(ansi_length(id(p)) for (p, _) in journal; init = 0)
    for (p, msg) in journal
        s = id(p)
        l = ansi_length(s)
        pad = max(0, padding - l)
        println(io, ' ', s, ' '^pad, ": ", msg)
    end
    return
end

"""
Show the resolution log for some package, and all the other packages that affected
it during resolution. The `view` option can be either `:plain` or `:tree` (works
the same as for `showlog(io, rlog)`); the default is `:tree`.
"""
function showlog(io::IO, rlog::ResolveLog, p::UUID; view::Symbol = :tree)
    view ∈ [:plain, :tree] || throw(ArgumentError("the view argument should be `:plain` or `:tree`"))
    entry = rlog.pool[p]
    return if view === :tree
        _show(io, rlog, entry, _logindent, IdDict{Any, Any}(entry => true), true)
    else
        entries = ResolveLogEntry[entry]
        collect_log_entries!(entries, entry)
        for entry in entries
            _show(io, rlog, entry, _logindent, IdDict(), false)
        end
    end
end

function collect_log_entries!(entries::Vector{ResolveLogEntry}, entry::ResolveLogEntry)
    for (other_entry, _) in entry.events
        (other_entry ≡ nothing || other_entry ∈ entries) && continue
        push!(entries, other_entry)
        collect_log_entries!(entries, other_entry)
    end
    return
end

# Show a recursive tree with requirements applied to a package, either directly or indirectly
function _show(io::IO, rlog::ResolveLog, entry::ResolveLogEntry, indent::String, seen::IdDict, recursive::Bool)
    toplevel = (indent == _logindent)
    firstglyph = toplevel ? "" : "└─"
    pre = toplevel ? "" : "  "
    println(io, indent, firstglyph, entry.header)
    l = length(entry.events)
    for (i, (otheritem, msg)) in enumerate(entry.events)
        if !isempty(msg)
            print(io, indent * pre, (i == l ? '└' : '├'), '─')
            println(io, msg)
            newindent = indent * pre * (i == l ? "  " : "│ ")
        else
            newindent = indent
        end
        otheritem ≡ nothing && continue
        recursive || continue
        if otheritem ∈ keys(seen)
            println(io, newindent, "└─", otheritem.header, " see above")
            continue
        end
        seen[otheritem] = true
        _show(io, rlog, otheritem, newindent, seen, recursive)
    end
    return
end

is_julia(graph::Graph, p0::Int) = graph.data.pkgs[p0] == uuid_julia

"Check for contradictions in the constraints."
function check_constraints(graph::Graph)
    np = graph.np
    gconstr = graph.gconstr
    pkgs = graph.data.pkgs
    rlog = graph.data.rlog
    exact = graph.data.rlog.exact

    id(p0::Int) = pkgID(p0, graph)

    for p0 in 1:np
        any(gconstr[p0]) && continue
        if exact
            err_msg = "Unsatisfiable requirements detected for package $(logstr(id(p0))):\n"
        else
            err_msg = "Resolve failed to satisfy requirements for package $(logstr(id(p0))):\n"
        end
        err_msg *= sprint(showlog, rlog, pkgs[p0])
        throw(ResolverError(chomp(err_msg)))
    end
    return true
end

"""
Propagates current constraints, determining new implicit constraints.
Throws an error in case impossible requirements are detected, printing
a log trace.
"""
function propagate_constraints!(graph::Graph, sources::Set{Int} = Set{Int}(); log_events::Bool = true, err_msg_preamble::String = "")
    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    gmsk = graph.gmsk
    gconstr = graph.gconstr
    adjdict = graph.adjdict
    ignored = graph.ignored
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers
    rlog = graph.data.rlog
    exact = rlog.exact

    id(p0::Int) = pkgID(pkgs[p0], graph)

    log_events && isempty(sources) && log_event_global!(graph, "propagating constraints")

    # unless otherwise specified, start from packages which
    # are not allowed to be uninstalled
    staged = isempty(sources) ?
        Set{Int}(p0 for p0 in 1:np if !gconstr[p0][end]) :
        sources

    seen = copy(staged)
    staged_next = Set{Int}()

    # Pre-allocate workspace for added constraints
    max_spp = maximum(spp, init = 0)
    added_constr1 = BitVector(undef, max_spp)
    old_gconstr1 = BitVector(undef, max_spp)

    while !isempty(staged)
        staged_next = Set{Int}()
        for p0 in staged
            gconstr0 = gconstr[p0]
            for (j1, p1) in enumerate(gadj[p0])
                # if p1 is ignored, the relation between it and all its neighbors
                # has already been propagated
                ignored[p1] && continue

                # we don't propagate to julia (purely to have better error messages)
                pkgs[p1] == uuid_julia && continue

                msk = gmsk[p0][j1]
                # if an entire row of the sub-mask is false, that version of p1
                # is effectively forbidden
                # (this is just like calling `any` row-wise)
                # sub_msk = msk[:, gconstr0]
                # added_constr1 = any!(BitVector(undef, spp[p1]), sub_msk)
                # The code below is equivalent to the shorter code above, but avoids allocating
                spp1 = spp[p1]
                resize!(added_constr1, spp1)
                fill!(added_constr1, false)
                for v1 in 1:spp1
                    for v0 in 1:spp[p0]
                        if gconstr0[v0] && msk[v1, v0]
                            added_constr1[v1] = true
                            break
                        end
                    end
                end

                # apply the new constraints, checking for contradictions
                # (keep the old ones for comparison)
                gconstr1 = gconstr[p1]
                copy!(old_gconstr1, gconstr1)
                gconstr1 .&= added_constr1
                # if the new constraints are more restrictive than the
                # previous ones, record it and propagate them next
                if gconstr1 ≠ old_gconstr1
                    push!(staged_next, p1)
                    log_events && log_event_implicit_req!(graph, p1, added_constr1, p0)
                elseif p1 ∉ seen
                    push!(staged_next, p1)
                end
                if !any(gconstr1)
                    err_msg = err_msg_preamble # currently used by validate_versions!
                    if exact
                        err_msg *= "Unsatisfiable requirements detected for package $(logstr(id(p1))):\n"
                    else
                        err_msg *= "Resolve failed to satisfy requirements for package $(logstr(id(p1))):\n"
                    end
                    err_msg *= sprint(showlog, rlog, pkgs[p1])
                    throw(ResolverError(chomp(err_msg)))
                end
            end
        end
        union!(seen, staged_next)
        staged = staged_next
    end
    return graph
end

"""
Enforce the uninstalled state on all packages that are not reachable from the required ones
or from the packages in the `sources` argument.
"""
function disable_unreachable!(graph::Graph, sources::Set{Int} = Set{Int}())
    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    gmsk = graph.gmsk
    gconstr = graph.gconstr
    adjdict = graph.adjdict
    pkgs = graph.data.pkgs

    log_event_global!(graph, "disabling unreachable nodes")

    # 2nd argument are packages which are not allowed to be uninstalled
    staged = union(sources, Set{Int}(p0 for p0 in 1:np if !gconstr[p0][end]))
    seen = copy(staged)

    while !isempty(staged)
        staged_next = Set{Int}()
        for p0 in staged
            gconstr0idx = findall(gconstr[p0][1:(end - 1)])
            for (j1, p1) in enumerate(gadj[p0])
                all(gmsk[p0][j1][end, gconstr0idx]) && continue # the package is not required by any of the allowed versions of p0
                p1 ∈ seen || push!(staged_next, p1)
            end
        end
        union!(seen, staged_next)
        staged = staged_next
    end

    # Force uninstalled state for all unseen packages
    for p0 in 1:np
        p0 ∈ seen && continue
        gconstr0 = gconstr[p0]
        @assert gconstr0[end]
        fill!(gconstr0, false)
        gconstr0[end] = true
    end

    return graph
end

"""
Validate package versions one at a time, by checking what would happen by forcing that version and propagating
the constraints. Versions which lead to unsatisfiable constraints are then diabled. If all versions of a package
(including "uninstalled") are invalid, then the requirements are unsatisfiable.

The algorithm starts from an initial pool of packages to check. Then, for each package, if any invalid version is
detected all the neighboring packages in the graph are also added to the pool.
If sources are provided, use those packages as initial pool, otherwise the initial pool is the whole graph.

If "skim=true", stop checking each package as soon as a valid version (besides possibly "uninstalled") is found.
This is a heuristic that trades thoroughness for speed.
"""
function validate_versions!(graph::Graph, sources::Set{Int} = Set{Int}(); skim::Bool = true)
    np = graph.np
    spp = graph.spp
    gconstr = graph.gconstr
    gadj = graph.gadj
    pkgs = graph.data.pkgs
    pvers = graph.data.pvers
    rlog = graph.data.rlog

    changed = false

    np == 0 && return graph, changed

    id(p0::Int) = pkgID(p0, graph)

    log_event_global!(graph, "validating versions [mode=$(skim ? "skim" : "deep")]")

    sumspp = sum(count(gconstr[p0]) for p0 in 1:np)

    # TODO: better data structure (need a FIFO queue with fast membership loopup)
    squeue = union(sources, Set{Int}(p0 for p0 in 1:np if !gconstr[p0][end]))
    isempty(squeue) && (squeue = Set{Int}(1:np))
    queue = collect(squeue)

    while !isempty(queue)
        p0 = popfirst!(queue)
        delete!(squeue, p0)

        gconstr0 = gconstr[p0]
        old_gconstr0 = copy(gconstr0)
        for v0 in reverse!(findall(gconstr0))
            push_snapshot!(graph)
            fill!(graph.gconstr[p0], false)
            graph.gconstr[p0][v0] = true
            disable = false
            try
                propagate_constraints!(graph, Set{Int}([p0]), log_events = false)
            catch err
                err isa ResolverError || rethrow()
                disable = true
            end
            pop_snapshot!(graph)
            @assert graph.gconstr ≡ gconstr
            @assert graph.gconstr[p0] ≡ gconstr0
            gconstr0[v0] = !disable
            # in skim mode, get out as soon as we find an installable version
            if skim && v0 != spp[p0] && !disable
                break
            end
        end
        if old_gconstr0 ≠ gconstr0
            changed = true
            unsat = !any(gconstr0)
            if unsat
                # we'll trigger a failure by pinning the highest version
                v0 = findlast(old_gconstr0[1:(end - 1)])
                @assert v0 ≢ nothing # this should be ensured by a previous pruning
                # @info "pinning $(logstr(id(p0))) to version $(pvers[p0][v0])"
                log_event_pin!(graph, pkgs[p0], pvers[p0][v0])
                graph.gconstr[p0][v0] = true
                err_msg_preamble = "Package $(logstr(id(p0))) has no possible versions; here is the log when trying to validate the highest version left until this point, $(logstr(id(p0), pvers[p0][v0]))):\n"
                propagate_constraints!(graph, Set{Int}([p0]); err_msg_preamble)
                @assert false # the above call must fail
            end

            vmask = old_gconstr0 .⊻ gconstr0
            log_event_validate!(graph, p0, vmask)

            for p1 in gadj[p0]
                if p1 ∉ squeue
                    push!(squeue, p1)
                    push!(queue, p1)
                end
            end
            propagate_constraints!(graph, Set{Int}([p0]))
        end
    end

    sumspp_new = sum(count(gconstr[p0]) for p0 in 1:np)

    log_event_global!(graph, "versions validation completed, stats (total n. of states): before = $(sumspp) after = $(sumspp_new) diff = $(sumspp - sumspp_new)")

    return graph, changed
end

"""
Reduce the number of versions in the graph by putting all the versions of
a package that behave identically into equivalence classes, keeping only
the highest version of the class as representative.
"""
function compute_eq_classes!(graph::Graph)
    log_event_global!(graph, "computing version equivalence classes")

    np = graph.np
    sumspp = sum(graph.spp)

    # Preallocate workspace matrix - make it large enough for worst case
    max_rows = maximum(1 + sum(size(m, 1) for m in graph.gmsk[p0]; init = 0) for p0 in 1:np; init = 1)
    max_cols = maximum(graph.spp; init = 1)
    cmat_workspace = BitMatrix(undef, max_rows, max_cols)
    cvecs_workspace = [BitVector(undef, max_rows) for _ in 1:max_cols]

    for p0 in 1:np
        build_eq_classes1!(graph, p0, cmat_workspace, cvecs_workspace)
    end

    log_event_global!(graph, "computed version equivalence classes, stats (total n. of states): before = $(sumspp) after = $(sum(graph.spp))")

    @assert check_consistency(graph)

    return graph
end

function build_eq_classes1!(graph::Graph, p0::Int, cmat_workspace::BitMatrix, cvecs_workspace::Vector{BitVector})
    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    gmsk = graph.gmsk
    gconstr = graph.gconstr
    adjdict = graph.adjdict
    data = graph.data
    pkgs = data.pkgs
    pvers = data.pvers
    vdict = data.vdict
    eq_classes = data.eq_classes
    rlog = data.rlog

    # concatenate all the constraints; the columns of the
    # result encode the behavior of each version
    # cmat = vcat(BitMatrix(permutedims(gconstr[p0])), gmsk[p0]...)
    ncols = spp[p0]
    cmat_workspace[1, 1:ncols] = gconstr[p0]
    row_idx = 2
    for j1 in 1:length(gmsk[p0])
        msk = gmsk[p0][j1]
        nrows_msk = size(msk, 1)
        cmat_workspace[row_idx:(row_idx + nrows_msk - 1), 1:ncols] = msk
        row_idx += nrows_msk
    end

    # cvecs = [cmat[:, v0] for v0 in 1:spp[p0]]
    nrows = row_idx - 1
    cvecs = view(cvecs_workspace, 1:ncols)
    for v0 in 1:ncols
        resize!(cvecs[v0], nrows)
        copy!(cvecs[v0], view(cmat_workspace, 1:nrows, v0))
    end

    # find unique behaviors
    repr_vecs = unique(cvecs)

    # number of equivalent classes
    neq = length(repr_vecs)

    neq == spp[p0] && return # nothing to do here

    # group versions into sets that behave identically
    eq_sets = [Set{Int}(v0 for v0 in 1:spp[p0] if cvecs[v0] == rvec) for rvec in repr_vecs]
    sort!(eq_sets, by = maximum)

    # each set is represented by its highest-valued member
    repr_vers = map(maximum, eq_sets)
    # the last representative must always be the uninstalled state
    @assert repr_vers[end] == spp[p0]

    # update equivalence classes
    eq_vn(v0) = (v0 == spp[p0] ? nothing : pvers[p0][v0])
    eq_classes0 = eq_classes[pkgs[p0]]
    for (v0, rvs) in zip(repr_vers, eq_sets)
        @assert v0 ∈ rvs
        vn0 = eq_vn(v0)
        for v1 in rvs
            v1 == v0 && continue
            vn1 = eq_vn(v1)
            @assert vn1 ≢ nothing
            union!(eq_classes0[vn0], eq_classes0[vn1])
            delete!(eq_classes0, vn1)
        end
    end

    # reduce the constraints and the interaction matrices
    spp[p0] = neq
    gconstr[p0] = gconstr[p0][repr_vers]
    for (j1, p1) in enumerate(gadj[p0])
        gmsk[p0][j1] = gmsk[p0][j1][:, repr_vers]

        j0 = adjdict[p0][p1]
        gmsk[p1][j0] = gmsk[p1][j0][repr_vers, :]
    end

    # reduce/rebuild version dictionaries
    pvers[p0] = pvers[p0][repr_vers[1:(end - 1)]]
    vdict[p0] = Dict(vn => i for (i, vn) in enumerate(pvers[p0]))

    # put a record in the log
    log_event_eq_classes!(graph, p0)

    return
end

function compute_eq_classes_soft!(graph::Graph; log_events::Bool = true)
    log_events && log_event_global!(graph, "computing version equivalence classes")

    np = graph.np

    np == 0 && return graph

    ignored = graph.ignored
    gconstr = graph.gconstr
    sumspp = sum(count(gconstr[p0]) for p0 in 1:np)
    for p0 in 1:np
        ignored[p0] && continue
        build_eq_classes_soft1!(graph, p0)
    end
    sumspp_new = sum(count(gconstr[p0]) for p0 in 1:np)

    log_events && log_event_global!(graph, "computed version equivalence classes, stats (total n. of states): before = $(sumspp) after = $(sumspp_new) diff = $(sumspp_new - sumspp)")

    @assert check_consistency(graph)

    return graph
end

function build_eq_classes_soft1!(graph::Graph, p0::Int)
    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    gmsk = graph.gmsk
    gconstr = graph.gconstr
    ignored = graph.ignored

    # concatenate all the constraints; the columns of the
    # result encode the behavior of each version
    gadj0 = gadj[p0]
    gmsk0 = gmsk[p0]
    gconstr0 = gconstr[p0]
    eff_spp0 = count(gconstr0)
    cvecs = BitVector[vcat(BitVector(), (gmsk0[j1][gconstr[gadj0[j1]], v0] for j1 in 1:length(gadj0) if !ignored[gadj0[j1]])...) for v0 in findall(gconstr0)]

    @assert length(cvecs) == eff_spp0

    # find unique behaviors
    repr_vecs = unique(cvecs)

    # number of equivalent classes
    neq = length(repr_vecs)

    neq == eff_spp0 && return # nothing to do here

    # group versions into sets that behave identically
    # each set is represented by its highest-valued member
    repr_vers = sort!(Int[findlast(isequal(repr_vecs[w0]), cvecs) for w0 in 1:neq])
    @assert all(>(0), repr_vers)
    @assert repr_vers[end] == eff_spp0

    # convert the version numbers into the original numbering
    repr_vers = findall(gconstr0)[repr_vers]

    @assert all(gconstr0[repr_vers])

    # disable the other versions by introducing additional constraints
    fill!(gconstr0, false)
    gconstr0[repr_vers] .= true

    return
end

function update_ignored!(graph::Graph)
    np = graph.np
    gconstr = graph.gconstr
    ignored = graph.ignored

    for p0 in 1:np
        ignored[p0] = (count(gconstr[p0]) == 1)
    end

    return graph
end

"""
Prune away fixed and unnecessary packages, and the
disallowed versions for the remaining packages.
"""
function prune_graph!(graph::Graph)
    np = graph.np
    spp = graph.spp
    gadj = graph.gadj
    gmsk = graph.gmsk
    gconstr = graph.gconstr
    adjdict = graph.adjdict
    req_inds = graph.req_inds
    fix_inds = graph.fix_inds
    ignored = graph.ignored
    data = graph.data
    pkgs = data.pkgs
    pdict = data.pdict
    pvers = data.pvers
    vdict = data.vdict
    pruned = data.pruned
    rlog = data.rlog

    # We will remove all packages that only have one allowed state
    # (includes fixed packages and forbidden packages)
    pkg_mask = BitVector(count(gconstr[p0]) ≠ 1 for p0 in 1:np)
    new_np = count(pkg_mask)

    # a map that translates the new index ∈ 1:new_np into its
    # corresponding old index ∈ 1:np
    old_idx = findall(pkg_mask)
    # the reverse of the above
    new_idx = Dict{Int, Int}()
    for new_p0 in 1:new_np
        new_idx[old_idx[new_p0]] = new_p0
    end

    # Update requirement indices
    new_req_inds = Set{Int}()
    for p0 in req_inds
        pkg_mask[p0] || continue
        push!(new_req_inds, new_idx[p0])
    end

    # Fixed packages will all be pruned
    new_fix_inds = Set{Int}()
    for p0 in fix_inds
        @assert !pkg_mask[p0]
    end

    # Record which packages we are going to prune
    for p0 in findall(.~(pkg_mask))
        # Find the version
        s0 = findfirst(gconstr[p0])
        # We don't record fixed packages
        p0 ∈ fix_inds && (@assert s0 ≠ spp[p0]; continue)
        p0 ∈ req_inds && @assert s0 ≠ spp[p0]
        log_event_pruned!(graph, p0, s0)
        # We don't record as pruned packages that are not going to be installed
        s0 == spp[p0] && continue
        @assert !haskey(pruned, pkgs[p0])
        pruned[pkgs[p0]] = pvers[p0][s0]
    end

    # Update packages records
    new_pkgs = pkgs[pkg_mask]
    new_pdict = Dict(new_pkgs[new_p0] => new_p0 for new_p0 in 1:new_np)
    new_ignored = ignored[pkg_mask]
    empty!(graph.solve_stack)

    # For each package (unless it's going to be pruned) we will remove all
    # versions that aren't allowed (but not the "uninstalled" state)
    function keep_vers(new_p0)
        p0 = old_idx[new_p0]
        return BitVector((v0 == spp[p0]) | gconstr[p0][v0] for v0 in 1:spp[p0])
    end
    vers_mask = [keep_vers(new_p0) for new_p0 in 1:new_np]

    # Update number of states per package
    new_spp = Int[count(vers_mask[new_p0]) for new_p0 in 1:new_np]

    # Update versions maps
    function compute_pvers(new_p0)
        p0 = old_idx[new_p0]
        pvers0 = pvers[p0]
        vmsk0 = vers_mask[new_p0]
        return pvers0[vmsk0[1:(end - 1)]]
    end
    new_pvers = [compute_pvers(new_p0) for new_p0 in 1:new_np]

    # explicitly writing out the following loop since the generator equivalent caused type inference failure
    new_vdict = Vector{Dict{VersionNumber, Int}}(undef, length(new_pvers))
    for new_p0 in eachindex(new_vdict)
        new_vdict[new_p0] = Dict(vn => v0 for (v0, vn) in enumerate(new_pvers[new_p0]))
    end

    # The new constraints are all going to be `true`, except possibly
    # for the "uninstalled" state, which we copy over from the old
    function compute_gconstr(new_p0)
        p0 = old_idx[new_p0]
        new_gconstr0 = trues(new_spp[new_p0])
        new_gconstr0[end] = gconstr[p0][end]
        return new_gconstr0
    end
    new_gconstr = [compute_gconstr(new_p0) for new_p0 in 1:new_np]

    # Recreate the graph adjacency list, skipping some packages
    new_gadj = [Int[] for new_p0 in 1:new_np]
    new_adjdict = [Dict{Int, Int}() for new_p0 in 1:new_np]

    for new_p0 in 1:new_np, (j1, p1) in enumerate(gadj[old_idx[new_p0]])
        pkg_mask[p1] || continue
        new_p1 = new_idx[p1]

        new_j0 = get(new_adjdict[new_p1], new_p0, length(new_gadj[new_p0]) + 1)
        new_j1 = get(new_adjdict[new_p0], new_p1, length(new_gadj[new_p1]) + 1)

        @assert (new_j0 > length(new_gadj[new_p0]) && new_j1 > length(new_gadj[new_p1])) ||
            (new_j0 ≤ length(new_gadj[new_p0]) && new_j1 ≤ length(new_gadj[new_p1]))

        new_j0 > length(new_gadj[new_p0]) || continue
        push!(new_gadj[new_p0], new_p1)
        push!(new_gadj[new_p1], new_p0)
        @assert new_j0 == length(new_gadj[new_p0])
        @assert new_j1 == length(new_gadj[new_p1])

        new_adjdict[new_p1][new_p0] = new_j0
        new_adjdict[new_p0][new_p1] = new_j1
    end

    # Recompute compatibility masks on the new adjacency list, and filtering out some versions
    function compute_gmsk(new_p0, new_j0)
        p0 = old_idx[new_p0]
        new_p1 = new_gadj[new_p0][new_j0]
        p1 = old_idx[new_p1]
        j0 = adjdict[p1][p0]
        return gmsk[p0][j0][vers_mask[new_p1], vers_mask[new_p0]]
    end
    new_gmsk = [[compute_gmsk(new_p0, new_j0) for new_j0 in 1:length(new_gadj[new_p0])] for new_p0 in 1:new_np]

    # Reduce log pool (the other items are still reachable through rlog.init)
    rlog.pool = Dict(p => rlog.pool[p] for p in new_pkgs)

    # Done

    log_event_global!(graph, "pruned graph — stats (n. of packages, mean connectivity): before = ($np,$(sum(spp) / length(spp))) after = ($new_np,$(sum(new_spp) / length(new_spp)))")

    # Replace old data with new
    data.pkgs = new_pkgs
    data.np = new_np
    data.spp = new_spp
    data.pdict = new_pdict
    data.pvers = new_pvers
    data.vdict = new_vdict
    # Notes:
    #   * uuid_to_name, eq_classes are unchanged
    #   * pruned and rlog were updated in-place

    # Replace old structures with new ones
    graph.gadj = new_gadj
    graph.gmsk = new_gmsk
    graph.gconstr = new_gconstr
    graph.adjdict = new_adjdict
    graph.req_inds = new_req_inds
    graph.fix_inds = new_fix_inds
    graph.ignored = new_ignored
    graph.spp = new_spp
    graph.np = new_np
    # Note: solve_stack was emptied in-place

    @assert check_consistency(graph)

    return graph
end

"""
Simplifies the graph by propagating constraints, disabling unreachable versions, pruning
and grouping versions into equivalence classes.
"""
function simplify_graph!(graph::Graph, sources::Set{Int} = Set{Int}(); validate_versions::Bool = true)
    propagate_constraints!(graph)
    disable_unreachable!(graph, sources)
    compute_eq_classes!(graph)
    prune_graph!(graph)
    if validate_versions
        _, changed = validate_versions!(graph, sources; skim = true)
        if changed
            compute_eq_classes!(graph)
            prune_graph!(graph)
        end
    end
    return graph
end

function simplify_graph_soft!(graph::Graph, sources::Set{Int} = Set{Int}(); log_events = true)
    propagate_constraints!(graph, sources, log_events = log_events)
    update_ignored!(graph)
    compute_eq_classes_soft!(graph, log_events = log_events)
    update_ignored!(graph)
    return graph
end
