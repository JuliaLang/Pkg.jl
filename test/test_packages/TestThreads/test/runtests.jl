@assert haskey(ENV, "EXPECTED_NTHREADS")
@assert Threads.nthreads() == parse(Int, ENV["EXPECTED_NTHREADS"])
