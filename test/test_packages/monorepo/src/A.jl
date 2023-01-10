module A
using B, C
test() = true
testC() = C.test()
end # module
