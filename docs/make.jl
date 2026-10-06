using Documenter, OpenBCI

makedocs(
    sitename = "OpenBCI Module Documentation",
    format = Documenter.HTML(prettyurls = false),
)

deploydocs(
    repo = "github.com/wherrera10/OpenBCI.jl.git",
    devbranch = "master",  
)
