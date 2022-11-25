@assert ARGS == ["a", "b"]
@assert Base.JLOptions().quiet == 1 # --quiet
@assert Base.JLOptions().check_bounds == 2 # overridden default when testing
@assert (Base.JLOptions().depwarn == 1) || (Base.JLOptions().depwarn == 2)
