var documenterSearchIndex = {"docs": [

{
    "location": "index.html#",
    "page": "Pkg3",
    "title": "Pkg3",
    "category": "page",
    "text": ""
},

{
    "location": "index.html#Pkg3.jl-1",
    "page": "Pkg3",
    "title": "Pkg3.jl",
    "category": "section",
    "text": "warning: Warning\nThis documentation is a work in progress and the information in it might be or become outdated.Sections:Pages = [\n    \"index.md\"]"
},

{
    "location": "index.html#Introduction-1",
    "page": "Pkg3",
    "title": "Introduction",
    "category": "section",
    "text": "Pkg3 is the package manager for Julia."
},

{
    "location": "index.html#Getting-Started-1",
    "page": "Pkg3",
    "title": "Getting Started",
    "category": "section",
    "text": "The Pkg REPL-mode is entered using from the Julia REPL using the key ]. To return to the julia> prompt, either press backspace when the input line is empty or press Ctrl+C. Help is available by calling pkg> help.To generate files for a new project, use pkg> generate.pkg> generate HelloWorldThis creates a new project HelloWorld with the following filesjulia> cd(\"HelloWorld\")\nshell> tree .\n.\n├── Project.toml\n└── src\n    └── HelloWorld.jl\n\n1 directory, 2 filesThe Project.toml file contains the name of the package, its unique UUID, its version, the author and eventual dependencies:name = \"HelloWorld\"\nuuid = \"b4cd1eb8-1e24-11e8-3319-93036a3eb9f3\"\nversion = \"0.1.0\"\nauthor = [\"Some One <someone@email.com>\"]\n\n[deps]The content of src/HelloWorld.jl is:module HelloWorld\n\ngreet() = print(\"Hello World!\")\n\nend # moduleWe can now load the project and use it:julia> import HelloWorld\n\njulia> HelloWorld.greet()\nHello World!"
},

{
    "location": "index.html#Adding-packages-to-the-project-1",
    "page": "Pkg3",
    "title": "Adding packages to the project",
    "category": "section",
    "text": "Let\'s say we want to use the standard library package Random and the registered package JSON in our project. We simply add these packages:pkg> add Random JSON\n Resolving package versions...\n  Updating \"~/Documents/HelloWorld/Project.toml\"\n [682c06a0] + JSON v0.17.1\n [9a3f8284] + Random\n  Updating \"~/Documents/HelloWorld/Manifest.toml\"\n [34da2185] + Compat v0.57.0\n [682c06a0] + JSON v0.17.1\n [4d1e1d77] + Nullables v0.0.4\n ...Both Random and JSON got added to the project\'s Project.toml file, and the resulting dependencies got added to the Manifest.toml file. The resolver has installed each package with the highest possible version, while still respecting the compatibility that each package enforce on its dependencies.We can now use both Random and JSON in our project. Changing src/HelloWorld.jl tomodule HelloWorld\n\nimport Random\nimport JSON\n\ngreet() = print(\"Hello World!\")\ngreet_alien() = print(\"Hello \", Random.randstring(8))\n\nend # moduleand reloading the package, the new greet_alien function that uses Random can be used:julia> HelloWorld.greet_alien()\nHello aT157rHVSometimes we might want to use the very latest, unreleased version of a package, or perhaps a specific branch in the package git repository. We can use e.g. the master branch of JSON by specifying the branch after a # when adding the package:pkg> add JSON#master\n   Cloning package from https://github.com/JuliaIO/JSON.jl.git\n Resolving package versions...\n  Updating \"~/Documents/HelloWorld/Project.toml\"\n [682c06a0] ~ JSON v0.17.1 ⇒ v0.17.1+ #master\n  Updating \"~/Documents/HelloWorld/Manifest.toml\"\n [682c06a0] ~ JSON v0.17.1 ⇒ v0.17.1+ #masterIf we want to use a package that has not been registered in a registry, we can add its git repository url:pkg> add https://github.com/fredrikekre/ImportMacros.jl\n  Cloning package from https://github.com/fredrikekre/ImportMacros.jl\n Resolving package versions...\nDownloaded MacroTools ─ v0.4.0\n  Updating \"~/Documents/HelloWorld/Project.toml\"\n [5adcef86] + ImportMacros v0.1.0 #master\n   Updating \"~/Documents/HelloWorld/Manifest.toml\"\n [5adcef86] + ImportMacros v0.1.0 #master\n [1914dd2f] + MacroTools v0.4.0The dependencies of the unregistered package (here MacroTools) got installed. For unregistered packages we could have given a branch (or commit SHA) to track using #, just like for registered packages."
},

{
    "location": "index.html#Developing-packages-1",
    "page": "Pkg3",
    "title": "Developing packages",
    "category": "section",
    "text": "Let\'s say we found a bug in JSON that we want to fix. We can get the full git-repo using the develop commandpkg> develop JSON\n    Cloning package from https://github.com/JuliaIO/JSON.jl.git\n  Resolving package versions...\n   Updating \"~/.julia/environments/v0.7/Project.toml\"\n [682c06a0] + JSON v0.17.1+ [~/.julia/dev/JSON]\n...By default, the package get cloned to the ~/.julia/dev folder but can also be set by the JULIA_PKG_DEVDIR environment variable. When we have fixed the bug and checked that JSON now works correctly with out project, we can make a PR to the JSON repository. When a new release of JSON is made, we can go back to using the versioned JSON using the command free and update (see next section):pkg> free JSON\n Resolving package versions...\n  Updating \"~/Documents/HelloWorld/Project.toml\"\n [682c06a0] ~ JSON v0.17.1+ #master ⇒ v0.17.1\n  Updating \"~/Documents/HelloWorld/Manifest.toml\"\n [682c06a0] ~ JSON v0.17.1+ #master ⇒ v0.17.1It is also possible to give a local path as the argument to develop which will not clone anything but simply use that directory for the package.Developing a non registered package is done by giving the git-repo url as an argument to develop."
},

{
    "location": "index.html#Updating-dependencies-1",
    "page": "Pkg3",
    "title": "Updating dependencies",
    "category": "section",
    "text": "When new versions of packages the project is using  are released, it is a good idea to update. Simply calling up will try to update all the dependencies of the project. Sometimes this is not what you want. You can specify a subset of the dependencies to upgrade by giving them as arguments to up, e.g:pkg> up JSONThe version of all other dependencies will stay the same. If you only want to update the minor version of packages, to reduce the risk that your project breaks, you can give the --minor flag, e.g:pkg> up --minor JSONPackages that track a branch are not updated when a minor upgrade is done. Developed packages are never touched by the package manager.If you just want install the packages that are given by the current Manifest.toml usepkg> up --manifest --fixed"
},

{
    "location": "index.html#Preview-mode-1",
    "page": "Pkg3",
    "title": "Preview mode",
    "category": "section",
    "text": "If you just want to see the effects of running a command, but not change your state you can preview a command. For example:pkg> preview add Plotorpkg> preview upwill show you the effects adding Plots, or doing a full upgrade, respectively, would have on your project. However, nothing would be installed and your Project.toml and Manfiest.toml are untouched."
},

{
    "location": "index.html#Using-someone-elses-project.-1",
    "page": "Pkg3",
    "title": "Using someone elses project.",
    "category": "section",
    "text": "Simple clone their project using e.g. git clone, cd to the project directory and callpkg> up --manifest --fixedThis will install the packages at the same state that the project you cloned was using."
},

]}
