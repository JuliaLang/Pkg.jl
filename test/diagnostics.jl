@testset "__diagnostics__()" begin
    # check that `Pkg.__diagnostics__(io)` doesn't error, produces some output
    buf = PipeBuffer()
    Pkg.__diagnostics__(buf)
    output = read(buf, String)
    @test occursin("Packages:", output)
    @test occursin("Registries:", output)
end
