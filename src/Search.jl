export pkgsearch

# recursive function for applying search criteria
function keycheck(data::Dict{<:Any,<:Any},str::Array{String,1},mode::Array{Symbol,1})
    found = false
    for key in keys(data)
        if :deps in mode
            for s in str
                (key == s) && (found = true)
            end
        end
        if (((:search in mode) && (typeof(data[key]) == String)) ||
            ((:name in mode) && (key == "name")) ||
            ((:keywords in mode) && (key == "keywords")) ||
            ((:desc in mode) && (key == "description")))
            for s in lowercase.(str)
                contains(lowercase(data[key]),s) && (found = true)
            end
        end
        if typeof(data[key]) <: Dict{<:Any,<:Any}
            keycheck(data[key],str,mode) && (found = true)
        end
    end
    return found
end

# directory search for package toml
function pkgsearch(mode::Array{Symbol,1},str::Array{String,1})
    m = mode
    (:search in m) && push!(m,:deps,:name)
    pkglist = String[]
    path = joinpath(homedir(),".julia/registries")
    for depot in readdir(path)
        data = nothing
        for (root, dirs, files) in walkdir(joinpath(path,depot))
            for dir in dirs
                found = false
                for file in readdir(joinpath(root,dir))
                    if endswith(file, ".toml")
                        (file == "Deps.toml") && (:deps ∉ m) && continue
                        (file == "Package.toml") && (:name ∉ m) && continue
                        (file != "Project.toml") && (:deps ∉ m) && (:name ∉ m) && continue
                        data = TOML.parsefile(joinpath(root,dir,file))
                        keycheck(data,str,m) && (found = true)
                    end
                end
                found && push!(pkglist,dir)
            end
        end
    end
    return pkglist
end
pkgsearch(mode::Symbol,str::String...) = pkgsearch([mode],collect(str))
pkgsearch(str::String,mode::Symbol...) = pkgsearch(collect(mode),[str])

# recursively lists needed pkgs from dependency tree
function findreqs(token)
    list = String[]
    data = nothing
    p = Pkg.dir(token)
    t = "Project.toml"
    try
        (t in readdir(p)) ? (data = Pkg3.TOML.parsefile(joinpath(p,t))) : (return list)
    catch
        return list
    end
    for key in keys(data["deps"])
        key ∉ list && push!(list,key)
        for x in findreqs(key)
            x ∉ list && push!(list,x)
        end
    end
    return list
end

# reports pkg info as an Array
function pkginfo(token,data)
    dat = Array{Any,1}(uninitialized,7)
    dat[1] = data["name"]
    dat[2] = data["desc"]
    dat[3] = data["license"]
    dat[4] = data["keywords"]
    dat[5] = keys(data["deps"])
    ns = String[]
    for key in dat[5]
        for x in findreqs(key)
            (x ∉ dat[5]) && (x ∉ ns) && push!(ns,x)
        end
    end
    dat[6] = ns
    dat[7] = pkgsearch(:deps,token)
    return dat
end
