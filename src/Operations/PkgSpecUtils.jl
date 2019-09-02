module PkgSpecUtils

export source_path, is_tracking_registered_version, is_tracking_unregistered

import Base: SHA1
using  UUIDs
import ..depots, ..depots1, ..Projects
using  ..PackageSpecs, ..Utils

###
### Depot
###

# TODO refactor
function source_path(pkg::PackageSpec)
    return is_stdlib(pkg.uuid)    ? stdlib_path(pkg.name) :
        pkg.path      !== nothing ? pkg.path :
        pkg.repo.url  !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        pkg.tree_hash !== nothing ? find_installed(pkg.name, pkg.uuid, pkg.tree_hash) :
        nothing
end

###
### Adjectives
###

# more accurate name is: is tracking _potentially_ unregistered package
# a package can track either directly track a path or track a repo
is_tracking_unregistered(pkg::PackageSpec) = pkg.path !== nothing || pkg.repo.url !== nothing

# more accurate name is `should_be_tracking_registered_version`
# the only way to know for sure is to key into the registries
is_tracking_registered_version(pkg::PackageSpec) =
    !is_stdlib(pkg.uuid) && !is_tracking_unregistered(pkg)


###
### Utils
###

function find_installed(name::String, uuid::UUID, sha1::SHA1)
    slug_default = Base.version_slug(uuid, sha1)
    # 4 used to be the default so look there first
    for slug in (Base.version_slug(uuid, sha1, 4), slug_default)
        for depot in depots()
            path = abspath(depot, "packages", name, slug)
            ispath(path) && return path
        end
    end
    return abspath(depots1(), "packages", name, slug_default)
end

end
