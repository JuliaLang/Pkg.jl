module REPLUnitTests

using Pkg
import Pkg.Types.CommandError
using UUIDs
using Test

@testset "uint test `parse_package`" begin
    name = "FooBar"
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    url = "https://github.com/JuliaLang/Example.jl"
    path = "./Foobar"
    # valid input
    pkg = Pkg.REPLMode.parse_package(name)
    @test pkg.name == name
    pkg = Pkg.REPLMode.parse_package(uuid)
    @test pkg.uuid == UUID(uuid)
    pkg = Pkg.REPLMode.parse_package("$name=$uuid")
    @test (pkg.name == name) && (pkg.uuid == UUID(uuid))
    pkg = Pkg.REPLMode.parse_package(url; add_or_develop=true)
    @test (pkg.repo.url == url)
    pkg = Pkg.REPLMode.parse_package(path; add_or_develop=true)
    @test (pkg.repo.url == path)
    # errors
    @test_throws CommandError Pkg.REPLMode.parse_package(url)
    @test_throws CommandError Pkg.REPLMode.parse_package(path)
end

end #module
