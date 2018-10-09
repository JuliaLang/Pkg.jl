# **2.** Getting Started

Pkg comes with its own REPL mode, which can be entered from the Julia REPL
by pressing `]`. To get back to the Julia REPL press backspace or ^C.

```
(v1.1) pkg>
```

The prompt displays the current active environment, which is the environment
that Pkg commands will modify. The default environment is based on the current
Julia version, `(v1.1)` in the example above, and is located in
`~/.julia/environments/`.

!!! note
    There are other ways of interacting with Pkg:
    1. The `pkg` string macro, which is available after `using Pkg`. The command
       `pkg"cmd"` is equivalent to executing `cmd` in the Pkg REPL.
    2. The API-mode, which is recommended for non-interactive
       environments. The API mode is documented in full in the API Reference section
       of the Pkg documentation.


