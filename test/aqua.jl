using Aqua, Test
# Unbound type parameters are not checked in vendored code, which is kept as
# upstream has it.
Aqua.test_all(Pkg; unbound_args = false)
in_vendored(mod) = mod === Pkg.Resolver || (mod !== Pkg && in_vendored(parentmodule(mod)))
@test isempty(filter(m -> !in_vendored(m.module), Test.detect_unbound_args(Pkg; recursive = true)))
