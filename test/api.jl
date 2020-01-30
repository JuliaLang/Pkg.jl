# This file is a part of Julia. License is MIT: https://julialang.org/license

module APITests
import ..Pkg # ensure we are using the correct Pkg

using Pkg, Test, REPL
import Pkg.Types.PkgError, Pkg.Resolve.ResolverError
using UUIDs

using ..Utils

@testset "Pkg.activate" begin
    temp_pkg_dir() do project_path
        cd_tempdir() do tmp
            path = pwd()
            Pkg.activate(".")
            mkdir("Foo")
            cd(mkdir("modules")) do
                Pkg.generate("Foo")
            end
            Pkg.develop(Pkg.PackageSpec(path="modules/Foo")) # to avoid issue #542
            Pkg.activate("Foo") # activate path Foo over deps Foo
            @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
            Pkg.activate(".")
            rm("Foo"; force=true, recursive=true)
            Pkg.activate("Foo") # activate path from developed Foo
            @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
            Pkg.activate(".")
            Pkg.activate("./Foo") # activate empty directory Foo (sidestep the developed Foo)
            @test Base.active_project() == joinpath(path, "Foo", "Project.toml")
            Pkg.activate(".")
            Pkg.activate("Bar") # activate empty directory Bar
            @test Base.active_project() == joinpath(path, "Bar", "Project.toml")
            Pkg.activate(".")
            Pkg.add("Example") # non-deved deps should not be activated
            Pkg.activate("Example")
            @test Base.active_project() == joinpath(path, "Example", "Project.toml")
            Pkg.activate(".")
            cd(mkdir("tests"))
            Pkg.activate("Foo") # activate developed Foo from another directory
            @test Base.active_project() == joinpath(path, "modules", "Foo", "Project.toml")
            Pkg.activate() # activate home project
            @test Base.ACTIVE_PROJECT[] === nothing
        end
    end
end

@testset "Pkg.test" begin
    temp_pkg_dir() do tmp
        copy_test_package(tmp, "TestArguments")
        Pkg.activate(joinpath(tmp, "TestArguments"))
        # test the old code path (no test/Project.toml)
        Pkg.test("TestArguments"; test_args=`a b`, julia_args=`--quiet --check-bounds=no`)
        Pkg.test("TestArguments"; test_args=["a", "b"], julia_args=["--quiet", "--check-bounds=no"])
        # test new code path
        touch(joinpath(tmp, "TestArguments", "test", "Project.toml"))
        Pkg.test("TestArguments"; test_args=`a b`, julia_args=`--quiet --check-bounds=no`)
        Pkg.test("TestArguments"; test_args=["a", "b"], julia_args=["--quiet", "--check-bounds=no"])
    end
end


include("FakeTerminals.jl")
import .FakeTerminals.FakeTerminal

@testset "Pkg.precompile_script" begin
    function fake_repl(@nospecialize(f); options::REPL.Options=REPL.Options(confirm_exit=false))
        # Use pipes so we can easily do blocking reads
        # In the future if we want we can add a test that the right object
        # gets displayed by intercepting the display
        input = Pipe()
        output = Pipe()
        err = Pipe()
        Base.link_pipe!(input, reader_supports_async=true, writer_supports_async=true)
        Base.link_pipe!(output, reader_supports_async=true, writer_supports_async=true)
        Base.link_pipe!(err, reader_supports_async=true, writer_supports_async=true)

        repl = REPL.LineEditREPL(FakeTerminal(input.out, output.in, err.in), true)
        repl.options = options

        f(input.in, output.out, repl)
        t = @async begin
            close(input.in)
            close(output.in)
            close(err.in)
        end
        @test read(err.out, String) == ""
        #display(read(output.out, String))
        Base.wait(t)
        nothing
    end

    fake_repl() do stdin_write, stdout_read, repl
        repltask = @async REPL.run_repl(repl)

        for line in split(Pkg.precompile_script, "\n"; keepempty=false)
            sleep(0.1)
            # Consume any extra output
            if bytesavailable(stdout_read) > 0
                copyback = readavailable(stdout_read)
                #@info(copyback)
            end

            # Write the line
            write(stdin_write, line, "\n")

            # Read until some kind of prompt
            readuntil(stdout_read, "\n")
            readuntil(stdout_read, ">")
            #@info(line)
        end

        write(stdin_write, "\x04")
        wait(repltask)
    end
end

end # module APITests
