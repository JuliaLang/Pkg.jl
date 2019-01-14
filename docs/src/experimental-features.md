# **10.** Experimental features

!!! warning
    This chapter describe experimental features of Pkg.
    These features should *not* be considered stable, and may
    be subject to change at any time. However, feel free to use
    them and give feedback.


## Extending the Pkg REPL

It is possible for external code to extend the Pkg REPL with new commands.
This is achieved by calling [`Pkg.REPL.add_repl_command!`](@ref).


```@docs
Pkg.REPLMode.add_repl_command!
```
