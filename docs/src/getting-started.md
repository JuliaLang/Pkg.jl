# **2.** Getting Started

The Pkg REPL-mode is entered from the Julia REPL using the key `]`.

```
(v1.0) pkg>
```

The part inside the parenthesis of the prompt shows the name of the current project.
Since we haven't created our own project yet, we are in the default project, located at `~/.julia/environments/v1.0`
(or whatever version of Julia you happen to run).

To return to the `julia>` prompt, either press backspace when the input line is empty or press Ctrl+C.
Help is available by calling `pkg> help`.
If you are in an environment that does not have access to a REPL you can still use the REPL mode commands using
the string macro `pkg` available after `using Pkg`. The command `pkg"cmd"` would be equivalent to executing `cmd`
in the REPL mode.

The documentation here describes using Pkg from the REPL mode. Documentation of using
the Pkg API (by calling `Pkg.` functions) is in progress of being written.
