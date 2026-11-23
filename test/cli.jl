module CLITests

import ..Pkg # ensure we are using the correct Pkg
using ..Utils
using Test
using Base.ScopedValues: @with

# Run the command-line interface in this process, started with the active project `project`
function pkg_cli(args...; project = nothing)
    Base.ACTIVE_PROJECT[] = project
    io = IOBuffer()
    code = @with Pkg.DEFAULT_IO => io Pkg.main(String[args...])
    return code, String(take!(io))
end

deps(project_dir) = keys(Pkg.Types.read_project(joinpath(project_dir, "Project.toml")).deps)

@testset "CLI" begin
    code, out = pkg_cli("--version")
    @test code == 0
    @test contains(out, string(pkgversion(Pkg)))

    code, help = pkg_cli("--help")
    @test code == 0
    @test contains(help, "registry add")
    @test pkg_cli() == (0, help)
    @test pkg_cli("help") == (0, help)
    code, out = pkg_cli("help", "add")
    @test code == 0
    @test contains(out, "Add package")

    code, out = pkg_cli("nosuchcommand")
    @test code == 1
    @test contains(out, "not a recognized command")
    @test pkg_cli("--nosuchoption", "status")[1] == 1

    isolate(loaded_depot = true) do
        mktempdir() do dir
            # arguments are passed on as they are, here a path with a space
            project = joinpath(dir, "my project")
            mkpath(joinpath(project, "sub"))
            touch(joinpath(project, "Project.toml"))
            other = joinpath(dir, "other")

            # the default is the project of the current directory or a parent of it
            cd(joinpath(project, "sub")) do
                @test pkg_cli("add", "Example")[1] == 0
            end
            @test deps(project) == Set(["Example"])

            # else the default environment
            cd(dir) do
                code, out = pkg_cli("status")
                @test code == 0
                @test contains(out, joinpath("environments", "v$(VERSION.major).$(VERSION.minor)"))

                code, out = pkg_cli("--project=$project", "status")
                @test code == 0
                @test contains(out, "Example")

                # several commands
                code, out = pkg_cli("activate", project, ";", "rm", "Example", ";", "activate", other, ";", "add", "Example")
                @test code == 0
                @test isempty(deps(project))
                @test deps(other) == Set(["Example"])
            end

            # a project set with `julia --project` or `JULIA_PROJECT` is kept
            cd(project) do
                @test pkg_cli("rm", "Example"; project = joinpath(other, "Project.toml"))[1] == 0
            end
            @test isempty(deps(other))
        end
    end

    # as run from a shell
    out = readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(Pkg)) -m Pkg --version`)
    @test out == "pkg $(pkgversion(Pkg)) (julia $VERSION)"
end

end # module
