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
    PkgREPLMode.__init__()
    PkgREPLMode.try_prompt_pkg_add(Symbol[:notapackage])
    PkgREPLMode.promptf()
    term = FakeTerminal()
    repl = REPL.LineEditREPL(term, true)
    REPL.run_repl(repl)
    PkgREPLMode.repl_init(repl)
end

if Base.generating_output()
    Base.Experimental.@force_compile
    pkgreplmode_precompile()
end

end # let
