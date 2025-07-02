@assert haskey(ENV, "EXPECTED_NUM_THREADS_DEFAULT")
@assert haskey(ENV, "EXPECTED_NUM_THREADS_INTERACTIVE")
EXPECTED_NUM_THREADS_DEFAULT = parse(Int, ENV["EXPECTED_NUM_THREADS_DEFAULT"])
EXPECTED_NUM_THREADS_INTERACTIVE = parse(Int, ENV["EXPECTED_NUM_THREADS_INTERACTIVE"])
@assert Threads.nthreads() == EXPECTED_NUM_THREADS_DEFAULT
@assert Threads.nthreads(:default) == EXPECTED_NUM_THREADS_DEFAULT
if Threads.nthreads() == 1
    @info "Convert me back to an assert once https://github.com/JuliaLang/julia/pull/57454 has landed" Threads.nthreads(:interactive) EXPECTED_NUM_THREADS_INTERACTIVE
else
    @assert Threads.nthreads(:interactive) == EXPECTED_NUM_THREADS_INTERACTIVE
end
