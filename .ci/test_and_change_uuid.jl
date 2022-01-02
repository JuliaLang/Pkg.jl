@static if Base.VERSION >= v"1.6"
    using TOML
    using Test
else
    using Pkg: TOML
    using Test
end

# To generate the new UUID, we simply modify the first character of the original UUID
const original_uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
const new_uuid      = "54cfe95a-1eb2-52ea-b672-e2afdf69b78f"

# `@__DIR__` is the `.ci/` folder.
# Therefore, `dirname(@__DIR__)` is the repository root.
const project_filename = joinpath(dirname(@__DIR__), "Project.toml")

@testset "Test that the UUID is unchanged" begin
    project_dict = TOML.parsefile(project_filename)
    @test project_dict["uuid"] == original_uuid
end

write(
    project_filename,
    replace(
        read(project_filename, String),
        r"uuid = .*?\n" => "uuid = \"$(new_uuid)\"\n",
    ),
)
