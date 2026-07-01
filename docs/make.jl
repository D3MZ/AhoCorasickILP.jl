using Documenter
using AhoCorasickILP

makedocs(
    sitename = "AhoCorasickILP.jl",
    modules = [AhoCorasickILP],
    authors = "Demetrius Michael",
    repo = Documenter.Remotes.GitHub("D3MZ", "AhoCorasickILP.jl"),
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://D3MZ.github.io/AhoCorasickILP.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Comparison" => "comparison.md",
        "API" => "api.md",
    ],
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/D3MZ/AhoCorasickILP.jl",
    devbranch = "main",
    push_preview = false,
)
