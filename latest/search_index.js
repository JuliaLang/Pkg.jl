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
    "text": "The Pkg REPL-mode is entered using from the Julia REPL using the key ]. To return to the julia> prompt, either press backspace when the input line is empty or press Ctrl+C. To generate the files for a new project, use pkg> generate.pkg> generate HelloWorldThis creates a new project HelloWorld with the following filesjulia> cd(\"HelloWorld\")\nshell> tree .\n.\n├── Project.toml\n└── src\n    └── HelloWorld.jl\n\n1 directory, 2 filesThe Project.toml file contains the name of the package, its unique UUID, its version, the author and eventual dependencies:name = \"HelloWorld\"\nuuid = \"b4cd1eb8-1e24-11e8-3319-93036a3eb9f3\"\nversion = \"0.1.0\"\nauthor = [\"Some One <someone@email.com>\"]\n\n[deps]The content of src/HelloWorld.jl is:module HelloWorld\n\ngreet() = print(\"Hello World!\")\n\nend # moduleWe can now load the project and use it:julia> import HelloWorld\n\njulia> HelloWorld.greet()\nHello World!"
},

]}
