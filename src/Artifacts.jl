module PkgArtifacts

# The artifact download, installation and authoring code lives in the `ArtifactDownloads`
# stdlib. This module keeps the `Pkg.Artifacts` names that packages, JLLs and tooling have
# used since artifacts were introduced.

using Artifacts, Base.BinaryPlatforms, SHA
using ..MiniProgressBars, ..PlatformEngines
using Tar: can_symlink
using FileWatching: FileWatching
using ArtifactDownloads
import ArtifactDownloads: create_artifact, remove_artifact, verify_artifact, archive_artifact,
    ArtifactDownloadInfo, bind_artifact!, unbind_artifact!, download_artifact,
    ensure_artifact_installed, try_artifact_download_sources, extract_all_hashes,
    with_show_download_info, make_dict

# The names the implementation used to take from Pkg, kept for code that reaches into
# this module's internals
import ..set_readonly, ..GitTools, ..TOML, ..pkg_server, ..can_fancyprint,
    ..stderr_f, ..printpkgstyle, ..mv_temp_dir_retries, ..atomic_toml_write, ..create_cachedir_tag
import Base: get, SHA1
import Artifacts: artifact_names, ARTIFACTS_DIR_OVERRIDE, ARTIFACT_OVERRIDES, artifact_paths,
    artifacts_dirs, pack_platform!, unpack_platform, load_artifacts_toml,
    query_override, with_artifacts_directory, load_overrides
import ..Types: write_env_usage, parse_toml

const Artifacts = PkgArtifacts # This is to preserve compatability for folks who depend on the internals of this module
export Artifacts, create_artifact, artifact_exists, artifact_path, remove_artifact, verify_artifact,
    artifact_meta, artifact_hash, bind_artifact!, unbind_artifact!, download_artifact,
    find_artifacts_toml, ensure_artifact_installed, @artifact_str, archive_artifact,
    select_downloadable_artifacts, ArtifactDownloadInfo

"""
    ensure_all_artifacts_installed(artifacts_toml::String;
                                    platform = HostPlatform(),
                                    pkg_uuid = nothing,
                                    include_lazy = false,
                                    verbose = false,
                                    quiet_download = false,
                                    io::IO=stderr)

Installs all non-lazy artifacts from a given `(Julia)Artifacts.toml` file. `package_uuid` must
be provided to properly support overrides from `Overrides.toml` entries in depots.

If `include_lazy` is set to `true`, then lazy packages will be installed as well.

This function is deprecated and should be replaced with the following snippet:

    artifacts = select_downloadable_artifacts(artifacts_toml; platform, include_lazy)
    for name in keys(artifacts)
        ensure_artifact_installed(name, artifacts[name], artifacts_toml; platform=platform)
    end

!!! warning
    This function is deprecated in Julia 1.6 and will be removed in a future version.
    Use `select_downloadable_artifacts()` and `ensure_artifact_installed()` instead.
"""
function ensure_all_artifacts_installed(
        artifacts_toml::String;
        platform::AbstractPlatform = HostPlatform(),
        pkg_uuid::Union{Nothing, Base.UUID} = nothing,
        include_lazy::Bool = false,
        verbose::Bool = false,
        quiet_download::Bool = false,
        io::IO = stderr_f()
    )
    # This function should not be called anymore; use `select_downloadable_artifacts()` directly.
    Base.depwarn("`ensure_all_artifacts_installed()` is deprecated; iterate over `select_downloadable_artifacts()` output with `ensure_artifact_installed()`.", :ensure_all_artifacts_installed)
    # Collect all artifacts we're supposed to install
    artifacts = select_downloadable_artifacts(artifacts_toml; platform, include_lazy, pkg_uuid)
    for name in keys(artifacts)
        # Otherwise, let's try and install it!
        ensure_artifact_installed(
            name, artifacts[name], artifacts_toml; platform = platform,
            verbose = verbose, quiet_download = quiet_download, io = io
        )
    end
    return
end
ensure_all_artifacts_installed(artifacts_toml::AbstractString; kwargs...) =
    ensure_all_artifacts_installed(string(artifacts_toml)::String; kwargs...)

end # module PkgArtifacts
