# Pretty log-scale bar chart comparing all three implementations on one 64 KB input.
# Numbers are the documented measurements from bench/bench.jl (Rust ref) and
# bench/compare_libraries.jl (AhoCorasick.jl), Apple M1 Max, single thread.

# label, milliseconds, colour, sublabel
rows = [
    ("AhoCorasickILP — ×8 streams", 0.0269, "#159a56", "Julia · this package"),
    ("AhoCorasickILP — serial", 0.1530, "#8fd0ac", "Julia · this package"),
    ("Rust  aho-corasick 1.1",   0.2263, "#c46a3f", "Rust crate"),
    ("AhoCorasick.jl 0.1.1",     2200.0, "#9aa0a6", "Julia · registry (O(n²))"),
]

W, H = 940, 340
padL, padR, padT, padB = 250, 150, 70, 54
pw = W - padL - padR
n = length(rows)
gap = (H - padT - padB) / n
bh = gap * 0.56

# log10(ms) axis from 0.01 ms to 10000 ms
lo, hi = -2.0, 4.0
xof(ms) = padL + (log10(ms) - lo) / (hi - lo) * pw

io = IOBuffer()
println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" font-family="'Helvetica Neue',Helvetica,Arial,sans-serif">""")
println(io, """<rect width="$W" height="$H" fill="white"/>""")
println(io, """<text x="$(W÷2)" y="30" text-anchor="middle" font-size="18" font-weight="700" fill="#1a1a1a">Keyword scan time — 64 KB input, single thread, Apple M1 Max</text>""")
println(io, """<text x="$(W÷2)" y="49" text-anchor="middle" font-size="12.5" fill="#777">lower is better · log scale · all three find the same 7,900 matches</text>""")

# vertical gridlines + x labels at each decade
for e in Int(lo):Int(hi)
    x = padL + (e - lo) / (hi - lo) * pw
    println(io, """<line x1="$x" y1="$padT" x2="$x" y2="$(H-padB)" stroke="#ececec"/>""")
    lab = e < 0 ? string(round(10.0^e, digits=2)) : (e == 0 ? "1" : string(10^e))
    println(io, """<text x="$x" y="$(H-padB+18)" text-anchor="middle" font-size="10.5" fill="#999">$lab</text>""")
end
println(io, """<text x="$(padL + pw/2)" y="$(H-padB+38)" text-anchor="middle" font-size="11.5" fill="#666">milliseconds (log scale)</text>""")

fac_ilp = rows[1][2]
for (i, (label, ms, col, sub)) in enumerate(rows)
    y = padT + (i - 1) * gap + (gap - bh) / 2
    x1 = xof(0.01); x2 = xof(ms)
    println(io, """<rect x="$x1" y="$y" width="$(x2-x1)" height="$bh" rx="3" fill="$col"/>""")
    println(io, """<text x="$(padL-14)" y="$(y+bh/2-1)" text-anchor="end" font-size="13" font-weight="600" fill="#222">$label</text>""")
    println(io, """<text x="$(padL-14)" y="$(y+bh/2+14)" text-anchor="end" font-size="10.5" fill="#999">$sub</text>""")
    val = ms < 1 ? "$(round(ms, digits=3)) ms" : (ms < 10 ? "$(round(ms, digits=2)) ms" : "$(round(Int, ms)) ms")
    rel = i == 1 ? "baseline" : "$(round(ms/fac_ilp, digits=ms/fac_ilp < 100 ? 1 : 0))× slower"
    println(io, """<text x="$(x2+8)" y="$(y+bh/2+4)" font-size="12" font-weight="600" fill="#333">$val</text>""")
    println(io, """<text x="$(x2+8)" y="$(y+bh/2+18)" font-size="10" fill="#aaa">$rel</text>""")
end
println(io, "</svg>")
write(joinpath(@__DIR__, "benchmark.svg"), String(take!(io)))
println("wrote bench/benchmark.svg")
