using Base: UUID

const DictStdLibs = Dict{UUID,Tuple{String,Union{VersionNumber,Nothing}}}

# Julia standard libraries with duplicate entries removed so as to store only the
# first release in a set of releases that all contain the same set of stdlibs.
#
# This needs to be populated via HistoricalStdlibVersions.jl by consumers
# (e.g. BinaryBuilder) that want to use the "resolve things as if it were a
# different Julia version than what is currently running" feature.
const STDLIBS_BY_VERSION = Pair{VersionNumber, DictStdLibs}[]

# This is a list of stdlibs that must _always_ be treated as stdlibs,
# because they cannot be resolved in the registry; they have only ever existed within
# the Julia stdlib source tree, and because of that, trying to resolve them will fail.
const UNREGISTERED_STDLIBS = DictStdLibs(
    UUID("2a0f44e3-6c83-55bd-87e4-b1978d98bd5f") => ("Base64", nothing),
    UUID("8bf52ea8-c179-5cab-976a-9e18b702a9bc") => ("CRC32c", nothing),
    UUID("ade2ca70-3891-5945-98fb-dc099432e06a") => ("Dates", nothing),
    UUID("8ba89e20-285c-5b6f-9357-94700520ee1b") => ("Distributed", nothing),
    UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee") => ("FileWatching", nothing),
    UUID("9fa8497b-333b-5362-9e8d-4d0656e87820") => ("Future", nothing),
    UUID("b77e0a4c-d291-57a0-90e8-8db25a27a240") => ("InteractiveUtils", nothing),
    UUID("76f85450-5226-5b5a-8eaa-529ad045b433") => ("LibGit2", nothing),
    UUID("8f399da3-3557-5675-b5ff-fb832c97cbdb") => ("Libdl", nothing),
    UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e") => ("LinearAlgebra", nothing),
    UUID("56ddb016-857b-54e1-b83d-db4d58db5568") => ("Logging", nothing),
    UUID("d6f4376e-aef5-505a-96c1-9c027394607a") => ("Markdown", nothing),
    UUID("a63ad114-7e13-5084-954f-fe012c677804") => ("Mmap", nothing),
    UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f") => ("Pkg", nothing),
    UUID("de0858da-6303-5e67-8744-51eddeeeb8d7") => ("Printf", nothing),
    UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79") => ("Profile", nothing),
    UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb") => ("REPL", nothing),
    UUID("9a3f8284-a2c9-5f02-9a11-845980a1fd5c") => ("Random", nothing),
    UUID("9e88b42a-f829-5b0c-bbe9-9e923198166b") => ("Serialization", nothing),
    UUID("1a1011a3-84de-559e-8e89-a11a2f7dc383") => ("SharedArrays", nothing),
    UUID("6462fe0b-24de-5631-8697-dd941f90decc") => ("Sockets", nothing),
    UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf") => ("SparseArrays", nothing),
    UUID("10745b16-79ce-11e8-11f9-7d13ad32a3b2") => ("Statistics", nothing),
    UUID("4607b0f0-06f3-5cda-b6b1-a6196a1729e9") => ("SuiteSparse", nothing),
    UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40") => ("Test", nothing),
    UUID("cf7118a7-6976-5b1a-9a39-7adc72f591a4") => ("UUIDs", nothing),
    UUID("4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5") => ("Unicode", nothing),
)
