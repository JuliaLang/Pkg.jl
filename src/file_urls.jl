# TODO remove these imports once this code is actually linked installed
using Pkg
using LibGit2





"""
    get_url

Makes a best attempt at generating a URL from version control,
Falls back to providing a local file URL.
"""
function get_url(_file, _module)
    try
        return giturl_dev(_file)
    catch err1
        @debug "Handling as dev'd package failed. Falling back." exception=err1
        try
            return giturl_release(_file, _module)
        catch err2
            @debug "Handling as added package failed. Falling back. Again." exception=err2
            return Base.fileurl(_file)
        end
    end
end


function get_url(method::Method)
    _file, _line = functionloc(method)
    _module = method.module
    url = get_url(_file, _module)
    if !startswith(url, "file:")
        url *= string("#L", _line)
    end
    return url
end



function giturl_dev(_file)
    _dir = dirname(_file)
    LibGit2.with(LibGit2.GitRepoExt(_dir)) do repo
        LibGit2.with(LibGit2.GitConfig(repo)) do cfg
            #TODO should this be hard coded to origin?
            # Or can we find the current targetted remote branch?
            remote_url_str = LibGit2.get(cfg, "remote.origin.url", "")
            commit = string(LibGit2.head_oid(repo))

            repo_root = LibGit2.path(repo)
            git_url(_file, repo_root, remote_url_str, commit)
            #TODO do something smart here for if this commit does not exist
            # on the remote. Like have an alternative secondary URL that points to
            # the nearest existant ancenstor that does exist on the remote
        end
    end
end

function giturl_release(_file, _module)
    pkg_module = Base.moduleroot(_module)
    pkg_name = string(nameof(pkg_module))
    pkg_version = Pkg.installed()[pkg_name]

    tag = string(pkg_version)

    spec = Pkg.PackageSpec(pkg_name)

    env = Pkg.Types.Context().env
    if !Pkg.Types.has_uuid(spec)
        Pkg.Types.registry_resolve!(env, [spec])
        Pkg.Types.ensure_resolved(env, [spec]; registry=true)
    end
    repo_remote_url_str = Pkg.Types.registered_info(env, spec.uuid, "repo")[1][2]


    pkg_module_loc = Base.locate_package(Base.PkgId(spec.uuid, pkg_name))
    package_loc = dirname(dirname(pkg_module_loc))

    return git_url(_file, package_loc, repo_remote_url_str, tag)
end



function git_url(_file, repo_root, remote_url_str, branch)
    r_url = match(LibGit2.URL_REGEX, remote_url_str)
    repo_name = replace(r_url[:path], r"\.git$"=>"")

    abs_file = if startswith(_file, repo_root)
        _file
    elseif startswith(realpath(_file), repo_root)
        realpath(_file)
    else
        error("Could not determine file location ($_file) within repo ($root)")
    end

    rel_file = abs_file[length(repo_root)+1:end]
    rel_file[1] == '/' && (rel_file = rel_file[2:end])
    url = join(["https:/", r_url[:host], repo_name, "tree", branch, rel_file], "/")
    return url
end

