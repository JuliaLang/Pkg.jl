module Status

import ..Pkg
import ..Utils
const isolate = Utils.isolate
using Test

@testset "Pkg.status" begin
    isolate() do
        @test_throws Pkg.Types.PkgError Pkg.status(; format = :invalid)

        ctx = Pkg.Types.Context()
        ctx.io = Base.devnull

        withenv("CI" => "true") do
            Pkg.status(ctx; io = ctx.io)
            Pkg.status(ctx; io = ctx.io, format = :autodetect)
            Pkg.status(ctx; io = ctx.io, format = :compact)
            Pkg.status(ctx; io = ctx.io, format = :toml)

            Pkg.pkg"status"
            Pkg.pkg"status --format=autodetect"
            Pkg.pkg"status --format=compact"
            Pkg.pkg"status --format=toml"
        end

        withenv("CI" => "false") do
            Pkg.status(ctx; io = ctx.io)
            Pkg.status(ctx; io = ctx.io, format = :autodetect)
            Pkg.status(ctx; io = ctx.io, format = :compact)
            Pkg.status(ctx; io = ctx.io, format = :toml)

            Pkg.pkg"status"
            Pkg.pkg"status --format=autodetect"
            Pkg.pkg"status --format=compact"
            Pkg.pkg"status --format=toml"
        end
    end
end

end
