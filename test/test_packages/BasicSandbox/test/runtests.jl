module FooTests

using Test
import BasicSandbox

@test 2 == 2
BasicSandbox.greet()

end
