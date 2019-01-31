module FooBuild

using Test
import Foo

@test 2 == 2
Foo.greet()

end
