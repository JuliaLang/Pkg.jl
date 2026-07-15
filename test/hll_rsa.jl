# This file is a part of Julia. License is MIT: https://julialang.org/license

module HLLRSATests
import ..Pkg # ensure we are using the correct Pkg
using Test, TOML, Random, Sockets

const HLL = Pkg.HLL_RSA

# Fixtures generated offline by the reference implementation
# (https://karpinski.org/HyperLogLogOverRSA.jl/): a small (B=33, m=8, 256-bit)
# fingerprint-free ring, its published certificate, and — for the test-only
# decoder below — the secret factorization plus the value each (x₀, class) pair
# must decode to. `secret.toml` is test scaffolding, not something a real client
# ever sees.
const FIX = joinpath(@__DIR__, "hll_rsa_fixtures")
const cert = TOML.parsefile(joinpath(FIX, "cert.toml"))
const secret = TOML.parsefile(joinpath(FIX, "secret.toml"))
const B = Int(cert["B"]::Integer)
const m = Int(cert["m"]::Integer)
const N = BigInt(cert["N"]::Integer)
const g = BigInt(cert["g"]::Integer)
const sqrts = BigInt[BigInt(s) for s in cert["sqrts"]]
const P = BigInt(secret["P"]::Integer)
const Q = BigInt(secret["Q"]::Integer)
const p = BigInt(secret["p"]::Integer)
const q = BigInt(secret["q"]::Integer)
const gB = BigInt(secret["gB"]::Integer)
const x0 = BigInt(secret["x0"]::Integer)
const classes = secret["classes"]
const expected = secret["expected"]

# Server-side decoder, using the secret factors — the counterpart the real
# server runs offline. A client token y decodes to (bucket, geometric).
const bmap = Dict(powermod(gB, 2p * b, P) => b for b in 0:(B - 1))
function decode(y::BigInt)
    b = bmap[powermod(y, 2p, P)]
    yq = powermod(y, q, Q)
    k = m
    while yq != 1
        yq = powermod(yq, 2, Q)
        k -= 1
    end
    return (b, k)
end

# base64 (standard alphabet) → big-endian integer, to check the token encoding
const B64REV = Dict(c => i - 1 for (i, c) in enumerate(['A':'Z'; 'a':'z'; '0':'9'; '+'; '/']))
function b64_to_int(s::AbstractString)
    bytes = UInt8[]
    acc = 0
    nbits = 0
    for c in s
        c == '=' && break
        acc = (acc << 6) | B64REV[c]
        nbits += 6
        if nbits ≥ 8
            nbits -= 8
            push!(bytes, UInt8((acc >> nbits) & 0xff))
        end
    end
    return foldl((a, b) -> a * 256 + b, bytes; init = big(0))
end

# Minimal one-shot HTTP server (same shape as test/platformengines.jl's
# auth_refresh_server): serve `body` to the first request, then close. Lets a
# test drive the real certificate fetch/verify/adopt path over http://127.0.0.1.
function serve_once(body::AbstractString)
    server = listen(Sockets.localhost, 0)
    base_url = "http://$(Sockets.localhost):$(Int(last(getsockname(server))))"
    task = @async begin
        try
            sock = accept(server)
            readline(sock) # request line
            while !isempty(rstrip(readline(sock))) # drain headers
            end
            write(sock, "HTTP/1.1 200 OK\r\n")
            write(sock, "Content-Type: application/toml\r\n")
            write(sock, "Content-Length: $(ncodeunits(body))\r\n")
            write(sock, "Connection: close\r\n\r\n")
            write(sock, body)
            flush(sock)
            close(sock)
        catch
        finally
            close(server)
        end
    end
    return (; server, task, base_url)
end

@testset "HLL Over RSA" begin
    @testset "resource classes" begin
        s = "https://pkg.julialang.org"
        @test HLL.resource_class("$s/registries", s) == "/registries"
        @test HLL.resource_class("$s/registry/UU/HH", s) == "/registry/UU"
        @test HLL.resource_class("$s/package/UU/HH", s) == "/package/UU"
        @test HLL.resource_class("$s/artifact/HH", s) == "/artifact/HH"
        @test HLL.resource_class("$s/package/UU/HH?foo=bar", s) == "/package/UU"
        @test HLL.resource_class("$s/meta", s) === nothing # not a counted class
        @test HLL.resource_class("$s/hll_rsa.toml", s) === nothing # exempt, no circularity
        @test HLL.resource_class("https://other.host/package/UU/HH", s) === nothing
    end

    @testset "opt-out" begin
        withenv("JULIA_PKG_SERVER_HLL_RSA" => nothing) do
            @test HLL.enabled() # on by default
        end
        for v in ("false", "0", "no", "f")
            withenv("JULIA_PKG_SERVER_HLL_RSA" => v) do
                @test !HLL.enabled()
            end
        end
        for v in ("true", "1", "yes")
            withenv("JULIA_PKG_SERVER_HLL_RSA" => v) do
                @test HLL.enabled()
            end
        end
    end

    @testset "master key and ring id" begin
        @test HLL.jacobi(x0, N) == -1 # master key in J_N^-
        rid = HLL.ring_id(B, m, N, g)
        @test length(rid) == 8 && all(∈("0123456789abcdef"), rid) # 8-char lowercase hex
    end

    @testset "token round-trips: $c" for (c, ek) in zip(classes, expected)
        ring = HLL.Ring(B, m, N, g, x0, HLL.ring_id(B, m, N, g))
        want = (ek[1], ek[2])
        y1 = HLL.token(ring, c)
        y2 = HLL.token(ring, c)
        @test HLL.jacobi(y1, N) == -1 # server accepts it
        @test decode(y1) == want # decodes to reference value
        @test decode(y2) == want # repeats collapse
        @test y1 != y2 # yet unlinkable
        y3 = b64_to_int(HLL.encode_token(y1)) # base64(big-endian)
        @test y3 == y1 # round-trip equality
    end

    @testset "persistence round-trip" begin
        mktempdir() do dir
            rid = HLL.ring_id(B, m, N, g)
            ring = HLL.Ring(B, m, N, g, x0, rid)
            @test HLL.load_stored(dir) === nothing # nothing stored yet
            HLL.save_stored(dir, ring)
            loaded = HLL.load_stored(dir)
            @test loaded !== nothing
            @test (loaded.B, loaded.m, loaded.N, loaded.g, loaded.x0, loaded.ring_id) ==
                (B, m, N, g, x0, rid)
        end
    end

    @testset "error header vs opt-out" begin
        # An insecure, non-localhost server makes the certificate fetch
        # short-circuit (no network), so these are deterministic.
        srv = "http://example.com"
        withenv("JULIA_PKG_SERVER_HLL_RSA" => "false") do # opted out: no header at all
            @test HLL.hll_header("$srv/registries", srv, mktempdir()) === nothing
        end
        # request in no counted class: its own status, distinct from opt-out
        @test HLL.hll_header("$srv/meta", srv, mktempdir()) == ("Julia-Pkg-HLL-RSA" => "noclass")
        # counted request, no reachable certificate: an error marker, not silence
        @test HLL.hll_header("$srv/registries", srv, mktempdir()) ==
            ("Julia-Pkg-HLL-RSA" => "error,fetch")
        @test HLL.error_header(:verify) == ("Julia-Pkg-HLL-RSA" => "error,verify")
    end

    # A deeper dive: perturb a valid certificate one way at a time and confirm
    # verification rejects each, and accepts the exact boundary that should pass.
    @testset "certificate verification" begin
        @test HLL.verify_cert(B, m, N, g, sqrts) # valid cert accepted

        # shape / parameter gates
        @test !HLL.verify_cert(HLL.B_MAX + 1, m, N, g, sqrts) # B exceeds B_max
        @test !HLL.verify_cert(B + 1, m, N, g, sqrts) # B even (valid B is odd)
        @test !HLL.verify_cert(B, HLL.M_MAX + 1, N, g, sqrts) # m exceeds m_max
        @test !HLL.verify_cert(B, 1, N, g, sqrts) # m < 2
        @test !HLL.verify_cert(B, m, big(2)^HLL.L_MAX, g, sqrts) # N exceeds L_max bits
        @test !HLL.verify_cert(B, m, N + 2, g, sqrts) # N ≢ 3 (mod 4)

        # g must have Jacobi symbol +1; a twist (−1) is rejected
        @test HLL.jacobi(x0, N) == -1
        @test !HLL.verify_cert(B, m, N, x0, sqrts) # g replaced by a twist

        # square-root list: enough of them, and each one actually valid
        nmin = findfirst(n -> (8 / 5)^n ≥ HLL.ALPHA_MIN, 1:length(sqrts))
        @test nmin !== nothing
        @test !HLL.verify_cert(B, m, N, g, sqrts[1:(nmin - 1)]) # one below the α threshold
        @test HLL.verify_cert(B, m, N, g, sqrts[1:nmin]) # exactly enough, all valid
        let bad = copy(sqrts)
            bad[1] += 1
            @test !HLL.verify_cert(B, m, N, g, bad) # a root perturbed by 1
        end
        let bad = copy(sqrts)
            bad[nmin] = rand(MersenneTwister(1), big(2):(N - 2))
            @test !HLL.verify_cert(B, m, N, g, bad) # a root replaced at random
        end

        # wrong modulus, right shape (N+4 ≡ 3 mod 4): caught by the fingerprint-free proof
        @test !HLL.verify_cert(B, m, N + 4, g, sqrts)
    end

    # End to end: a localhost server publishes the fixture certificate; the client
    # fetches it, verifies it, generates a fresh master key, and stores the ring.
    @testset "fetch, verify, and adopt a ring" begin
        srv = serve_once(read(joinpath(FIX, "cert.toml"), String))
        try
            mktempdir() do dir
                ring = HLL.refresh_ring(srv.base_url, dir)
                @test ring isa HLL.Ring # fetched, verified, adopted
                if ring isa HLL.Ring
                    @test (ring.B, ring.m, ring.N, ring.g) == (B, m, N, g)
                    @test ring.ring_id == HLL.ring_id(B, m, N, g)
                    @test HLL.jacobi(ring.x0, N) == -1 # freshly generated master key
                    @test HLL.load_stored(dir) !== nothing # persisted
                    b, k = decode(HLL.token(ring, "/registries")) # token from the fresh key
                    @test 0 ≤ b < B
                    @test 0 ≤ k ≤ m
                end
            end
        finally
            istaskdone(srv.task) || (close(srv.server); wait(srv.task))
        end
    end
end

end # module
