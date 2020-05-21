module Preferences
import ...Pkg, ..TOML
import ..API: get_uuid
import ..Types: parse_toml
import ..Scratch: get_scratch!, delete_scratch!
import Base: UUID

export load_preferences, @load_preferences,
       save_preferences!, @save_preferences!,
       modify_preferences!, @modify_preferences!,
       clear_preferences!, @clear_preferences!


"""
    depot_preferences_paths(uuid::UUID)

Return the possible paths of all preferences file for the given package `UUID` saved in
depot-wide `prefs` locations.
"""
function depot_preferences_paths(uuid::UUID)
    depots = reverse(Pkg.depots())
    return [joinpath(depot, "prefs", string(uuid, ".toml")) for depot in depots]
end

"""
    get_uuid_throw(m::Module)

Convert a `Module` to a `UUID`, throwing an `ArgumentError` if the given module does not
correspond to a loaded package.  This is expected for modules such as `Base`, `Main`,
anonymous modules, etc...
"""
function get_uuid_throw(m::Module)
    uuid = get_uuid(m)
    if uuid === nothing
        throw(ArgumentError("Module does not correspond to a loaded package!"))
    end
    return uuid
end

"""
    recursive_merge(base::Dict, overrides::Dict...)

Helper function to merge preference dicts recursively, honoring overrides in nested
dictionaries properly.
"""
function recursive_merge(base::Dict, overrides::Dict...)
    new_base = Base._typeddict(base, overrides...)
    for override in overrides
        for (k, v) in override
            if haskey(new_base, k) && isa(new_base[k], Dict) && isa(override[k], Dict)
                new_base[k] = recursive_merge(new_base[k], override[k])
            else
                new_base[k] = override[k]
            end
        end
    end
    return new_base
end

"""
    load_preferences(uuid::UUID)
    load_preferences(m::Module)

Load the preferences for the given package, returning them as a `Dict`.  Most users
should use the `@load_preferences()` macro which auto-determines the calling `Module`.
"""
function load_preferences(uuid::UUID)
    # First, load from depots, merging as we go:
    prefs = Dict{String,Any}()
    for path in depot_preferences_paths(uuid)
        if isfile(path)
            prefs = recursive_merge(prefs, parse_toml(path))
        end
    end

    # Finally, load from the currently-active project:
    proj_path = Base.active_project()
    if isfile(proj_path)
        project = parse_toml(proj_path)
        if haskey(project, "preferences") && isa(project["preferences"], Dict)
            proj_prefs = get(project["preferences"], string(uuid), Dict())
            prefs = recursive_merge(prefs, proj_prefs)
        end
    end
    return prefs
end
load_preferences(m::Module) = load_preferences(get_uuid_throw(m))

"""
    save_preferences!(uuid::UUID, prefs::Dict; depot::Union{String,Nothing} = nothing)
    save_preferences!(m::Module, prefs::Dict; depot::Union{String,Nothing} = nothing)

Save the preferences for the given package.  Most users should use the
`@save_preferences!()` macro which auto-determines the calling `Module`.  See also the
`modify_preferences!()` function (and the associated `@modifiy_preferences!()` macro) for
easy load/modify/save workflows.

The `depot` keyword argument allows saving of depot-wide preferences, as opposed to the
default of project-specific preferences.  Simply set the `depot` keyword argument to the
path of a depot (use `Pkg.depots1()` for the default depot) and the preferences will be
saved to that location.

Depot-wide preferences are overridden by preferences stored wtihin `Project.toml` files,
and all preferences (including those inherited from depot-wide preferences) are stored
concretely within `Project.toml` files.  This means that depot-wide preferences will
serve to provide default values for new projects/environments, but once a project has
saved its preferences at all, they are effectively decoupled.  This is an intentional
design choice to maximize reproducibility and to continue to support the `Project.toml`
as an independent archive.
"""
function save_preferences!(uuid::UUID, prefs::Dict;
                           depot::Union{AbstractString,Nothing} = nothing)
    if depot === nothing
        # Save to Project.toml
        proj_path = Base.active_project()
        mkpath(dirname(proj_path))
        project = Dict{String,Any}()
        if isfile(proj_path)
            project = parse_toml(proj_path)
        end
        if !haskey(project, "preferences")
            project["preferences"] = Dict{String,Any}()
        end
        if !isa(project["preferences"], Dict)
            error("$(proj_path) has conflicting `preferences` entry type: Not a Dict!")
        end
        project["preferences"][string(uuid)] = prefs
        open(proj_path, "w") do io
            TOML.print(io, project, sorted=true)
        end
    else
        path = joinpath(depot, "prefs", string(uuid, ".toml"))
        mkpath(dirname(path))
        open(path, "w") do io
            TOML.print(io, prefs, sorted=true)
        end
    end
    return nothing
end
function save_preferences!(m::Module, prefs::Dict;
                           depot::Union{AbstractString,Nothing} = nothing)
    return save_preferences!(get_uuid_throw(m), prefs; depot=depot)
end

"""
    modify_preferences!(f::Function, uuid::UUID)
    modify_preferences!(f::Function, m::Module)

Supports `do`-block modification of preferences.  Loads the preferences, passes them to a
user function, then writes the modified `Dict` back to the preferences file.  Example:

```julia
modify_preferences!(@__MODULE__) do prefs
    prefs["key"] = "value"
end
```

This function returns the full preferences object.  Most users should use the
`@modify_preferences!()` macro which auto-determines the calling `Module`.

Note that this method does not support modifying depot-wide preferences; modifications
always are saved to the active project.
"""
function modify_preferences!(f::Function, uuid::UUID)
    prefs = load_preferences(uuid)
    f(prefs)
    save_preferences!(uuid, prefs)
    return prefs
end
modify_preferences!(f::Function, m::Module) = modify_preferences!(f, get_uuid_throw(m))

"""
    clear_preferences!(uuid::UUID)
    clear_preferences!(m::Module)

Convenience method to remove all preferences for the given package.  Most users should
use the `@clear_preferences!()` macro, which auto-determines the calling `Module`.  This
method clears not only project-specific preferences, but also depot-wide preferences, if
the current user has the permissions to do so.
"""
function clear_preferences!(uuid::UUID)
    for path in depot_preferences_paths(uuid)
        try
            rm(path; force=true)
        catch
            @warn("Unable to remove preference path $(path)")
        end
    end

    # Clear the project preferences key, if it exists
    proj_path = Base.active_project()
    if isfile(proj_path)
        project = parse_toml(proj_path)
        if haskey(project, "preferences") && isa(project["preferences"], Dict)
            delete!(project["preferences"], string(uuid))
            open(proj_path, "w") do io
                TOML.print(io, project, sorted=true)
            end
        end
    end
end

"""
    @load_preferences()

Convenience macro to call `load_preferences()` for the current package.
"""
macro load_preferences()
    return quote
        load_preferences($(esc(get_uuid_throw(__module__))))
    end
end

"""
    @save_preferences!(prefs)

Convenience macro to call `save_preferences!()` for the current package.  Note that
saving to a depot path is not supported in this macro, use `save_preferences!()` if you
wish to do that.
"""
macro save_preferences!(prefs)
    return quote
        save_preferences!($(esc(get_uuid_throw(__module__))), $(esc(prefs)))
    end
end

"""
    @modify_preferences!(func)

Convenience macro to call `modify_preferences!()` for the current package.
"""
macro modify_preferences!(func)
    return quote
        modify_preferences!($(esc(func)), $(esc(get_uuid_throw(__module__))))
    end
end

"""
    @clear_preferences!()

Convenience macro to call `clear_preferences!()` for the current package.
"""
macro clear_preferences!()
    return quote
        preferences!($(esc(get_uuid_throw(__module__))))
    end
end

end # module Preferences