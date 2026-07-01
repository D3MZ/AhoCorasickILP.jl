using Documenter
using FastAhoCorasick

makedocs(
    sitename = "FastAhoCorasick.jl",
    modules = [FastAhoCorasick],
    authors = "Demetrius Michael",
    repo = Documenter.Remotes.GitHub("D3MZ", "FastAhoCorasick.jl"),
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://D3MZ.github.io/FastAhoCorasick.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Comparison" => "comparison.md",
        "API" => "api.md",
    ],
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/D3MZ/FastAhoCorasick.jl",
    devbranch = "main",
    push_preview = false,
)
