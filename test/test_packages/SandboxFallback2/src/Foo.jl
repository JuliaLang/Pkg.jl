module Foo
import Random

greet() = println("Hello World! $(Random.rand(Int))")

end # module
