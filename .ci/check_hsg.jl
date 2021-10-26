function check_hsg()
    assert_clean_working_directory()
    run_hsg()
    assert_clean_working_directory()
    return nothing
end

function assert_clean_working_directory()
    if !isempty(strip(read(`git status --short`, String)))
        msg = "The working directory is dirty"
        @error msg

        println("Output of `git status`:")
        println(strip(read(`git status`, String)))

        run(`git add -A`)

        println("Output of `git diff HEAD`:")
        println(strip(read(`git diff HEAD`, String)))

        run(`git reset`)

        throw(ErrorException(msg))
    else
        @info "The working directory is clean"
        return nothing
    end
end

function run_hsg()
    env2 = copy(ENV)
    delete!(env2, "JULIA_DEPOT_PATH")
    delete!(env2, "JULIA_LOAD_PATH")
    delete!(env2, "JULIA_PROJECT")
    env2["JULIA_DEPOT_PATH"] = mktempdir(; cleanup = true)
    julia_binary = Base.julia_cmd().exec[1]
    hsg_directory = joinpath("ext", "HistoricaStdlibGenerator")
    hsg_generate_file = joinpath(hsg_directory, "generate_historical_stdlibs.jl")

    cmd_1 = `$(julia_binary) --project=$(hsg_directory) -e 'import Pkg; Pkg.instantiate()'`
    cmd_2 = `$(julia_binary) --project=$(hsg_directory) $(hsg_generate_file)`

    run(setenv(cmd_1, env2))
    run(setenv(cmd_2, env2))

    return nothing
end

check_hsg()
