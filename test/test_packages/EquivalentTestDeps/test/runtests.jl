module Runtests
import Example, EquivalentTestDeps
using  Test
@test EquivalentTestDeps.foo(0) == 1
end
