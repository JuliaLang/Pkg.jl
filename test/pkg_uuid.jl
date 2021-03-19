using Pkg
using Test

@testset "Pkg UUID" begin 
    project_filename = joinpath(dirname(@__DIR__), "Project.toml")
    project = Pkg.TOML.parsefile(project_filename)
    uuid = project["uuid"]
    correct_uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
    @test uuid == correct_uuid
end
