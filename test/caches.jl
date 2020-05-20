module CacheTests
# Ensure we are using the correct Pkg, and that we get our testing utils
import ..Pkg
using Pkg.Caches, Test
using ..Utils

@testset "Cache basics" begin
    # Run everything in a separate depot, so that we can test GC'ing and whatnot
    temp_pkg_dir() do project_path
        # Create a global cache, ensure it exists and is writable
        cache_dir = get_cache!("test")
        @test isdir(cache_dir)
        @test startswith(cache_dir, Pkg.Caches.caches_dir())
        touch(joinpath(cache_dir, "foo"))
        @test readdir(cache_dir) == ["foo"]

        # Delete the cache, ensure it's gone.
        delete_cache!("test")
        @test !isdir(cache_dir)
    end
end

@testset "Cache Namespacing" begin
    temp_pkg_dir() do project_path
        # Add this Pkg so that any usage of `Pkg` by a julia started in this
        # environment will use it.
        add_this_pkg()
        cu_uuid = "93485645-17f1-6f3b-45bc-419db53815ea"
        
        function run_cache_usage(project_path::String, version::VersionNumber)
            # Clear out any previously-installed CacheUsage versions
            rm(joinpath(project_path, "CacheUsage"); force=true, recursive=true)

            copy_test_package(project_path, "CacheUsage")
            fpath = joinpath(project_path, "CacheUsage", "Project.toml")
            write(fpath, replace(read(fpath, String), "1.2.3" => string(version)))
            Pkg.develop(path=joinpath(project_path, "CacheUsage"))
            Pkg.test("CacheUsage")
        end

        # Touch the caches of a CacheUsage v1.0.0
        run_cache_usage(project_path, v"1.0.0")

        # Ensure that the files were created for v1.0.0
        @test isfile(caches_dir(cu_uuid, "1.0.0", "CacheUsage-1.0.0"))
        @test length(readdir(caches_dir(cu_uuid, "1.0.0"))) == 1
        @test isfile(caches_dir(cu_uuid, "1", "CacheUsage-1.0.0"))
        @test length(readdir(caches_dir(cu_uuid, "1"))) == 1
        @test isfile(caches_dir("GlobalCache", "CacheUsage-1.0.0"))
        @test length(readdir(caches_dir("GlobalCache"))) == 1

        # Next, do the same but for more versions
        run_cache_usage(project_path, v"1.1.0")
        run_cache_usage(project_path, v"2.0.0")

        # Check the caches were shared when they should have been, and not when they shouldn't
        @test isfile(caches_dir(cu_uuid, "1.0.0", "CacheUsage-1.0.0"))
        @test length(readdir(caches_dir(cu_uuid, "1.0.0"))) == 1
        @test isfile(caches_dir(cu_uuid, "1.1.0", "CacheUsage-1.1.0"))
        @test length(readdir(caches_dir(cu_uuid, "1.1.0"))) == 1
        @test isfile(caches_dir(cu_uuid, "2.0.0", "CacheUsage-2.0.0"))
        @test length(readdir(caches_dir(cu_uuid, "2.0.0"))) == 1
        @test isfile(caches_dir(cu_uuid, "1", "CacheUsage-1.0.0"))
        @test isfile(caches_dir(cu_uuid, "1", "CacheUsage-1.1.0"))
        @test length(readdir(caches_dir(cu_uuid, "1"))) == 2
        @test isfile(caches_dir(cu_uuid, "2", "CacheUsage-2.0.0"))
        @test length(readdir(caches_dir(cu_uuid, "2"))) == 1
        @test isfile(caches_dir("GlobalCache", "CacheUsage-1.0.0"))
        @test isfile(caches_dir("GlobalCache", "CacheUsage-1.1.0"))
        @test isfile(caches_dir("GlobalCache", "CacheUsage-2.0.0"))
        @test length(readdir(caches_dir("GlobalCache"))) == 3
    end
end

end # module