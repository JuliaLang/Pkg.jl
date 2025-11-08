let
    struct FakeTerminal <: REPL.Terminals.UnixTerminal
        in_stream::IOBuffer
        out_stream::IOBuffer
        err_stream::IOBuffer
        hascolor::Bool
        raw::Bool
        FakeTerminal() = new(IOBuffer(), IOBuffer(), IOBuffer(), false, true)
    end
    REPL.raw!(::FakeTerminal, raw::Bool) = raw

    function pkgreplmode_precompile()
        original_depot_path = copy(DEPOT_PATH)
        original_load_path = copy(LOAD_PATH)
        __init__()
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
        Pkg.DEFAULT_IO[] = Pkg.unstableio(devnull)
        withenv("JULIA_PKG_SERVER" => nothing, "JULIA_PKG_UNPACK_REGISTRY" => nothing) do
            tmp = Pkg._run_precompilation_script_setup()
            cd(tmp) do
                try_prompt_pkg_add(Symbol[:notapackage])
                promptf()
                term = FakeTerminal()
                repl = REPL.LineEditREPL(term, true)
                REPL.run_repl(repl)
                repl_init(repl)
            end
        end
        copy!(DEPOT_PATH, original_depot_path)
        copy!(LOAD_PATH, original_load_path)

        Base.precompile(Tuple{typeof(REPL.LineEdit.complete_line), REPLExt.PkgCompletionProvider, REPL.LineEdit.PromptState})
        Base.precompile(Tuple{typeof(REPL.REPLCompletions.completion_text), REPL.REPLCompletions.PackageCompletion})
        Base.precompile(Tuple{typeof(REPLExt.on_done), REPL.LineEdit.MIState, Base.GenericIOBuffer{Memory{UInt8}}, Bool, REPL.LineEditREPL})
        Base.precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:hint,), Tuple{Bool}}, typeof(REPL.LineEdit.complete_line), REPLExt.PkgCompletionProvider, REPL.LineEdit.PromptState})
    end

    if Base.generating_output()
        ccall(:jl_tag_newly_inferred_enable, Cvoid, ())
        try
            pkgreplmode_precompile()
        finally
            ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
        end
    end

end # let
