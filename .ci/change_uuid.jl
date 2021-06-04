using UUIDs

project_filename = joinpath(dirname(@__DIR__), "Project.toml")

write("Project.toml", replace(read("Project.toml", String), r"uuid = .*?\n" =>"uuid = \"$(uuid4())\"\n"))
