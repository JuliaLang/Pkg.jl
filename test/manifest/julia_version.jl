# Manifests written by past Julia releases, kept in `julia_version.toml` next to this
# file. Each release wrote one when adding JSON 0.21.3 to the environment below, and
# another when adding JSON 0.21.4 after the compat edit in `update_project!`. The
# environment uses what a release's manifest format and project hash depend on: a
# compat range, a dependency also listed in [weakdeps], a [sources] path dependency
# (from 1.11) and a stdlib with an extension (Pkg, from 1.11).
#
# To add releases, pass their Julia executables:
#
#     julia julia_version.jl /path/to/julia-1.14.0/bin/julia

using TOML

const MANIFESTS_FILE = joinpath(@__DIR__, "julia_version.toml")
const LOCAL_PKG_UUID = "5e1b3a5c-5d0c-4c5e-9b8a-1f2d3c4b5a69"

manifests() = TOML.parsefile(MANIFESTS_FILE)

function project_toml(julia_version::VersionNumber)
    deps = [
        "JSON = \"682c06a0-de6a-54ab-a142-c8b1cf79cde6\"",
        "LinearAlgebra = \"37e2e46d-f89d-539d-b4ee-838fcccc9c8e\"",
        "Pkg = \"44cfe95a-1eb2-52ea-b672-e2afdf69b78f\"",
    ]
    sources = julia_version >= v"1.11"
    sources && push!(deps, "LocalPkg = \"$LOCAL_PKG_UUID\"")
    return """
    [deps]
    $(join(sort(deps), "\n"))

    [weakdeps]
    LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
    $(sources ? "\n[sources]\nLocalPkg = {path = \"LocalPkg\"}\n" : "")
    [compat]
    JSON = "0.21.3 - 0.21"
    LinearAlgebra = "1"
    julia = "1.10"
    """
end

# A new environment for `julia_version`, with `manifest` as its manifest if given
function environment(julia_version::VersionNumber, manifest::Union{Nothing, String} = nothing)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), project_toml(julia_version))
    if julia_version >= v"1.11"
        mkpath(joinpath(dir, "LocalPkg", "src"))
        write(joinpath(dir, "LocalPkg", "Project.toml"), "name = \"LocalPkg\"\nuuid = \"$LOCAL_PKG_UUID\"\nversion = \"0.1.0\"\n")
        write(joinpath(dir, "LocalPkg", "src", "LocalPkg.jl"), "module LocalPkg end\n")
    end
    manifest === nothing || write(joinpath(dir, "Manifest.toml"), manifest)
    return dir
end

function update_project!(dir::String)
    project_file = joinpath(dir, "Project.toml")
    return write(project_file, replace(read(project_file, String), "\"0.21.3 - 0.21\"" => "\"0.21.4 - 0.21\""))
end

function add_json(julia::String, dir::String, version::String)
    script = "import Pkg; Pkg.activate(ARGS[1]); Pkg.add(Pkg.PackageSpec(name = \"JSON\", version = v\"$version\"))"
    cmd = `$julia --startup-file=no --history-file=no -e $script $dir`
    run(addenv(cmd, "JULIA_PKG_PRECOMPILE_AUTO" => "0"))
    return read(joinpath(dir, "Manifest.toml"), String)
end

function generate(julias::Vector{String})
    all = isfile(MANIFESTS_FILE) ? manifests() : Dict{String, Any}()
    for julia in julias
        julia_version = VersionNumber(readchomp(`$julia --startup-file=no -e 'print(VERSION)'`))
        dir = environment(julia_version)
        manifest = add_json(julia, dir, "0.21.3")
        update_project!(dir)
        all[string(julia_version)] = Dict("manifest" => manifest, "expected" => add_json(julia, dir, "0.21.4"))
    end
    # Literal strings keep the manifests readable and their diffs small
    return open(MANIFESTS_FILE, "w") do io
        println(io, "# Written by julia_version.jl")
        for key in sort!(collect(keys(all)); by = VersionNumber)
            print(io, "\n[\"", key, "\"]\n")
            for field in ("manifest", "expected")
                text = all[key][field]
                @assert !occursin("'''", text)
                print(io, field, " = '''\n", text, "'''\n")
            end
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    generate(ARGS)
end
