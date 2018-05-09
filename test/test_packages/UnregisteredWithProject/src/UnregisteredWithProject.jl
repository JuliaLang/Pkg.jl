module UnregisteredWithProject

using Example

export f
f(x) = x

# Check file permissions are preserved
file = joinpath(@__DIR__, "test.sh")
@assert isfile(file)
@assert uperm(file) == 0x07

end