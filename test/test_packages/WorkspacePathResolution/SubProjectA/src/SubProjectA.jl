module SubProjectA

using SubProjectB

greet() = "Hello from SubProjectA! " * SubProjectB.greet()

end