# This file is a part of Julia. License is MIT: https://julialang.org/license

# Client side of the HyperLogLog Over RSA protocol: derive a per-server, per-
# resource-class encrypted HyperLogLog token and attach it as the
# `Julia-Pkg-HLL-RSA` header, letting the package server anonymously estimate
# unique-client counts. This is a self-contained port of the client half of the
# protocol (https://karpinski.org/HyperLogLogOverRSA.jl/); it must stay
# byte-compatible with that spec so the server can verify and decode tokens.
#
# Nothing here can break a request or bother the user: an error anywhere in the
# HLL stack is caught. Rather than going silent, a failure sends a
# `Julia-Pkg-HLL-RSA: error,<reason>` header, so the server can distinguish a
# client that hit an error from one that has opted out (which sends no header).

module HLL_RSA

using SHA, Random
import Downloads, TOML
import ..Pkg: atomic_toml_write
import ..PlatformEngines: is_secure_url, get_auth_header

export hll_header

const HLL_RNG = RandomDevice()

# client acceptance bounds (see the "Deployment in Julia's Pkg client" spec)
const HLL_B_MAX = 2^12
const HLL_M_MAX = 127
const HLL_L_MAX = 2^20
const HLL_ALPHA_MIN = exp2(112)

const HLL_RECHECK_SECONDS = 24 * 60 * 60 # recheck server's ring daily

## --- integer helpers (ported from the reference; must match the server) ---

# Low 2/3 bits of a nonnegative BigInt, read from the low limb via `% UInt8` so
# no BigInt is allocated (unlike `x & 3`, which allocates a BigInt).
@inline hll_mod4(x::BigInt) = Int((x % UInt8) & 0x03)
@inline hll_mod8(x::BigInt) = Int((x % UInt8) & 0x07)

# Jacobi symbol (x | N) for odd positive N; returns -1, 0, or 1. The loop runs on
# two private, mutable BigInts — shifting and reducing them in place, and swapping
# by rebinding — so it allocates only the two it starts with, not one per
# iteration. `N` is copied up front; the caller's argument is never mutated.
function hll_jacobi(x::BigInt, N::BigInt)::Int
    N > 0 || throw(ArgumentError("N must be positive"))
    isodd(N) || throw(ArgumentError("N must be odd"))
    x = mod(x, N) # owned, fresh (mod allocates); 0 ≤ x < N
    iszero(x) && return 0
    N = Base.GMP.MPZ.set(N) # private mutable copy; the caller's N is never touched
    s = 1
    while !iszero(x)
        z = trailing_zeros(x)
        if !iszero(z)
            isodd(z) && (hll_mod8(N) == 3 || hll_mod8(N) == 5) && (s = -s)
            Base.GMP.MPZ.fdiv_q_2exp!(x, z) # x >>= z, in place
        end
        (hll_mod4(x) == 3 && hll_mod4(N) == 3) && (s = -s)
        Base.GMP.MPZ.fdiv_r!(N, N, x) # N = N mod x, in place
        x, N = N, x # swap: x ← remainder, N ← old x
        iszero(x) && break
    end
    return isone(N) ? s : 0
end

hll_modmul(a::Integer, b::Integer, m::Integer) = mod(a * b, m)

# Hash `N` and `keys` into the ring ℤ_N (a value mod N), via SHA-512.
# If `untwist` is nonzero, any negative-Jacobi result is multiplied by it,
# mapping the value into the positive-Jacobi subgroup.
function hll_hash_into_ring(
        N::BigInt,
        keys::Union{Integer, AbstractString, Symbol}...;
        untwist::BigInt = big(0),
    )
    prefix = sprint() do io
        print(io, N)
        for key in keys
            tag =
                key isa Integer ? "int" :
                key isa AbstractString ? "str" :
                key isa Symbol ? "sym" :
                error("unexpected type")
            print(io, '\0', tag, string(key))
        end
    end
    L = Base.top_set_bit(N) + 1
    x = big(0)
    for i in 1:cld(L, 512)
        for b in sha512(string(prefix, '\0', i, '\0'))
            # accumulate big-endian (x = x<<8 | b) in place, mutating x's GMP
            # limbs rather than allocating a fresh BigInt per byte
            Base.GMP.MPZ.mul_2exp!(x, 8)
            Base.GMP.MPZ.add_ui!(x, b)
        end
    end
    x = mod(x, N)
    if !iszero(untwist) && hll_jacobi(x, N) == -1
        x = mod(untwist * x, N)
    end
    return x
end

# A per-client hash of the master key: SHA-256 of x₀'s bytes, computed once when
# the ring is adopted (see `HLLRing`) and reused to key the class hash below.
hll_client_hash(x0::BigInt) = sha256(digits(UInt8, x0; base = 256))

# Map a resource class to a 128-bit exponent (first 16 bytes, big-endian) via
# HMAC-SHA2-256 keyed by the client's `client_hash`. How classes are hashed is
# client-specific — the server never recomputes it — so any keyed hash of the
# class works; HMAC is a standard keyed MAC, so there is nothing to reason about
# regarding length extension or key size. It depends on the secret master key
# (via `client_hash`), so the client can't bias its own draw, and it stays
# independent across classes.
function hll_hash_resource_class(
        client_hash::Vector{UInt8},
        class::AbstractString,
    )
    bytes = hmac_sha2_256(client_hash, codeunits(class))
    h = zero(UInt128)
    for i in 1:sizeof(UInt128)
        h = (h << 8) | bytes[i]
    end
    return h
end

# Smallest τ ∈ [1, N) with Jacobi symbol -1 (the fixed twist used by the cert).
function hll_fixed_twist(N::BigInt)
    τ = big(1)
    while τ < N
        hll_jacobi(τ, N) == -1 && return τ
        τ += 1
    end
    error("no twist value found")
end

# Random master key x₀ ∈ ℤ_N with Jacobi symbol -1.
function hll_rand_jacobi_twist(N::BigInt)
    range = big(1):(N - 1)
    while true
        x = rand(HLL_RNG, range)
        hll_jacobi(x, N) == -1 && return x
    end
    return
end

## --- ring representation, hashing, and certificate verification ---

struct HLLRing
    B::Int
    m::Int
    N::BigInt
    g::BigInt
    x0::BigInt                 # this client's master key for the ring
    ring_id::String            # 8-char lowercase hex, sent in the header
    client_hash::Vector{UInt8} # sha256(x0), used to key the resource-class hash
    HLLRing(B::Int, m::Int, N::BigInt, g::BigInt, x0::BigInt, ring_id::AbstractString) =
        new(B, m, N, g, x0, ring_id, hll_client_hash(x0))
end

# Canonical ring identifier: SHA-256 of the decimal parameters joined by commas,
# truncated to its first four bytes as lowercase hex.
function hll_ring_id(B::Int, m::Int, N::BigInt, g::BigInt)
    digest = sha256(string(B, ',', m, ',', N, ',', g))
    return bytes2hex(@view digest[1:4])
end

# Verify a certificate is well-formed and fingerprint-free (the client's half of
# the protocol). Returns true only if every check passes.
function hll_verify_cert(
        B::Int,
        m::Int,
        N::BigInt,
        g::BigInt,
        sqrts::Vector{BigInt},
    )
    B ≤ HLL_B_MAX || return false
    isodd(B) || return false
    2 ≤ m ≤ HLL_M_MAX || return false
    Base.top_set_bit(N) ≤ HLL_L_MAX || return false
    hll_mod4(N) == 3 || return false
    gcd(B, N) == 1 || return false
    gcd(B, N - 1) == 1 || return false
    hll_jacobi(g, N) == 1 || return false
    (8 / 5)^length(sqrts) ≥ HLL_ALPHA_MIN || return false
    τ = hll_fixed_twist(N)
    for (i, r) in enumerate(sqrts)
        r² = powermod(r, 2, N)
        x = hll_hash_into_ring(N, :sqrt_x, i; untwist = τ)
        x == r² && continue
        y = hll_hash_into_ring(N, :sqrt_y, i; untwist = τ)
        y == r² && continue
        z = hll_modmul(x, y, N)
        z == r² && continue
        return false
    end
    return true
end

## --- token generation and encoding ---

# Produce a fresh, randomized encrypted token y = w·xᵗ for `class`. Repeated
# calls are unlinkable but all decode (by the ring holder) to the same value.
function hll_token(ring::HLLRing, class::AbstractString)
    B, m, N, g, x0 = ring.B, ring.m, ring.N, ring.g, ring.x0
    h = hll_hash_resource_class(ring.client_hash, class)
    x = hll_modmul(x0, powermod(g, big(h), N), N) # x = x₀ gʰ
    z = rand(HLL_RNG, big(1):(N - 1))
    w = powermod(z, big(B) << m, N) # w = z^(B·2^m)
    i = rand(HLL_RNG, big(0):((big(1) << (m - 1)) - 1))
    t = 2 * big(B) * i + 1 # t ≡ 1 (mod 2B)
    return hll_modmul(w, powermod(x, t, N), N) # y = w·xᵗ
end

# base64 (standard alphabet, padded) of the big-endian byte representation of y.
const HLL_B64 = ['A':'Z'; 'a':'z'; '0':'9'; '+'; '/']

function hll_encode_token(y::BigInt)
    bytes = reverse!(digits(UInt8, y; base = 256)) # big-endian
    isempty(bytes) && (bytes = UInt8[0x00])
    io = IOBuffer()
    n = length(bytes)
    i = 1
    while i ≤ n
        b0 = bytes[i]
        b1 = i + 1 ≤ n ? bytes[i + 1] : 0x00
        b2 = i + 2 ≤ n ? bytes[i + 2] : 0x00
        write(io, HLL_B64[(b0 >> 2) + 1])
        write(io, HLL_B64[(((b0 & 0x03) << 4) | (b1 >> 4)) + 1])
        write(io, i + 1 ≤ n ? HLL_B64[(((b1 & 0x0f) << 2) | (b2 >> 6)) + 1] : '=')
        write(io, i + 2 ≤ n ? HLL_B64[(b2 & 0x3f) + 1] : '=')
        i += 3
    end
    return String(take!(io))
end

## --- resource classes ---

# Map a request URL to its resource class (a prefix of the resource path), or
# `nothing` if the request should carry no HLL header. Mirrors the sharding
# scheme in the writeup.
function hll_resource_class(url::AbstractString, server::AbstractString)
    rest = chopprefix(url, server)
    startswith(rest, "/") || return nothing
    q = findfirst('?', rest)
    q === nothing || (rest = rest[1:prevind(rest, q)])
    segs = split(rest, '/'; keepempty = false)
    isempty(segs) && return nothing
    if segs[1] == "registries"
        return "/registries"
    elseif segs[1] == "registry" && length(segs) ≥ 2
        return "/registry/" * segs[2]
    elseif segs[1] == "package" && length(segs) ≥ 2
        return "/package/" * segs[2]
    elseif segs[1] == "artifact" && length(segs) ≥ 2
        return "/artifact/" * segs[2]
    end
    return nothing
end

## --- per-server ring state: load, fetch, verify, cache ---

const HLL_LOCK = ReentrantLock()
# map: server_dir => last check time
const HLL_CHECK = Dict{String, Float64}()
# map: server_dir => ring, or a Symbol error reason (:fetch, :verify, :internal)
const HLL_CACHE = Dict{String, Union{HLLRing, Symbol}}()

# On unless explicitly set to a recognized false value. `get_bool_env` returns
# `nothing` for a present-but-unrecognized value (e.g. "off"); `!== false` maps
# that to enabled and, importantly, keeps this a `Bool` so it is safe to use in
# boolean context.
hll_enabled() = Base.get_bool_env("JULIA_PKG_SERVER_HLL_RSA", true) !== false

hll_file(server_dir) = joinpath(server_dir, "hll_rsa.toml")

function hll_load_stored(server_dir::AbstractString)
    file = hll_file(server_dir)
    isfile(file) || return nothing
    data = try
        TOML.parsefile(file)
    catch
        return nothing
    end
    try
        B = Int(data["B"]::Integer)
        m = Int(data["m"]::Integer)
        N = BigInt(data["N"]::Integer)
        g = BigInt(data["g"]::Integer)
        x0 = BigInt(data["x0"]::Integer)
        return HLLRing(B, m, N, g, x0, hll_ring_id(B, m, N, g))
    catch
        return nothing
    end
end

function hll_save_stored(server_dir::AbstractString, ring::HLLRing)
    mkpath(server_dir)
    atomic_toml_write(
        hll_file(server_dir),
        Dict(
            "B" => ring.B,
            "m" => ring.m,
            "N" => ring.N,
            "g" => ring.g,
            "x0" => ring.x0,
        );
        sorted = true,
    )
    return nothing
end

# Fetch and parse the server's certificate
# returns (B, m, N, g, sqrts) or nothing
function hll_fetch_cert(server::AbstractString)
    cert_url = "$server/hll_rsa.toml"
    is_secure_url(cert_url) || return nothing
    tmp = tempname()
    try
        auth = get_auth_header(cert_url)
        headers = auth === nothing ? Pair{String, String}[] : [auth]
        Downloads.download(cert_url, tmp; headers, timeout = 10.0)
        data = TOML.parsefile(tmp)
        B = Int(data["B"]::Integer)
        m = Int(data["m"]::Integer)
        N = BigInt(data["N"]::Integer)
        g = BigInt(data["g"]::Integer)
        sqrts = BigInt[BigInt(s) for s in data["sqrts"]::AbstractVector]
        return (B, m, N, g, sqrts)
    catch e
        @debug "HLL-RSA: certificate fetch/parse failed" cert_url exception = e
        return nothing
    finally
        rm(tmp; force = true)
    end
end

# (Re)establish the ring for a server. Returns an `HLLRing`, or a Symbol naming
# what went wrong: `:fetch` (no certificate could be fetched or parsed) or
# `:verify` (a certificate was fetched but failed verification). A usable stored
# ring is preferred over reporting a transient failure.
function hll_refresh_ring(server::AbstractString, server_dir::AbstractString)
    stored = hll_load_stored(server_dir)
    cert = hll_fetch_cert(server)
    cert === nothing && return stored === nothing ? :fetch : stored
    B, m, N, g, sqrts = cert
    # Unchanged ring? Keep our master key. Compare the parameters exactly, rather
    # than the (truncated) ring-id, so no hash collision can hide a real change.
    stored !== nothing && (stored.B, stored.m, stored.N, stored.g) == (B, m, N, g) && return stored
    hll_verify_cert(B, m, N, g, sqrts) || return stored === nothing ? :verify : stored
    ring = HLLRing(B, m, N, g, hll_rand_jacobi_twist(N), hll_ring_id(B, m, N, g))
    hll_save_stored(server_dir, ring)
    return ring
end

# Return the ring for a server (or a Symbol error reason), using the in-memory
# cache and refreshing at most once per session and once per HLL_RECHECK_SECONDS
# thereafter.
function hll_get_ring(server::AbstractString, server_dir::AbstractString)
    t = time()
    cached = lock(HLL_LOCK) do
        if haskey(HLL_CHECK, server_dir) && t - HLL_CHECK[server_dir] < HLL_RECHECK_SECONDS
            return Some(HLL_CACHE[server_dir])
        end
        return nothing
    end
    cached === nothing || return something(cached)
    result = try
        hll_refresh_ring(server, server_dir)
    catch e
        @debug "HLL-RSA: ring refresh failed" server exception = (e, catch_backtrace())
        # reuse a previously cached ring if we have one, else report an internal error
        prev = lock(HLL_LOCK) do
            get(HLL_CACHE, server_dir, :internal)
        end
        prev isa HLLRing ? prev : :internal
    end
    lock(HLL_LOCK) do
        HLL_CACHE[server_dir] = result
        HLL_CHECK[server_dir] = t
    end
    return result
end

## --- header ---

# `reason` is always one of the fixed symbols `:fetch`, `:verify`, `:internal` —
# never anything derived from client state, so the header leaks nothing.
hll_error_header(reason::Symbol) = "Julia-Pkg-HLL-RSA" => "error,$reason"

# The `Julia-Pkg-HLL-RSA` header for a request. Returns `nothing` only when the
# client has opted out, so a *missing* header always and only means opt-out.
# Otherwise the value is one of:
#   `<ring-id>,<token>`  the token for a counted request (success)
#   `noclass`            the request is in no counted resource class
#   `error,<reason>`     a counted request failed (reason ∈ fetch/verify/internal)
# Every failure path yields a reason rather than going silent. Never throws.
function hll_header(
        url::AbstractString,
        server::AbstractString,
        server_dir::AbstractString,
    )
    hll_enabled() || return nothing
    class = try
        hll_resource_class(url, server)
    catch e
        @debug "HLL-RSA: resource class failed" url exception = (e, catch_backtrace())
        return hll_error_header(:internal)    # an unexpected failure, not a clean no-match
    end
    # A request in no counted class is normal and explicitly handled — not an
    # error — so it gets its own status rather than an `error,<reason>` marker.
    class === nothing && return "Julia-Pkg-HLL-RSA" => "noclass"
    ring = hll_get_ring(server, server_dir) # HLLRing or error reason
    ring isa HLLRing || return hll_error_header(ring)
    try
        token = hll_encode_token(hll_token(ring, class))
        return "Julia-Pkg-HLL-RSA" => string(ring.ring_id, ',', token)
    catch e
        @debug "HLL-RSA: token generation failed" exception = (e, catch_backtrace())
        return hll_error_header(:internal)
    end
end

end # module HLL_RSA
