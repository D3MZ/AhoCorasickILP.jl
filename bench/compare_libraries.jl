# Compares FastAhoCorasick against the registered pure-Julia `AhoCorasick.jl` (v0.1.1).
#
# `AhoCorasick.jl` is GPLv3, so it is intentionally NOT a dependency of this (MIT) package.
# To run this comparison, add it to your own environment first:
#
#     julia -e 'using Pkg; Pkg.add("FastAhoCorasick"); Pkg.add("AhoCorasick")'
#     julia bench/compare_libraries.jl
#
# The two libraries target different jobs — see the capability table in the README. This
# script measures raw match throughput on ASCII input (AhoCorasick.jl throws a
# StringIndexError on multibyte UTF-8, and is O(n^2), so it cannot use the multilingual
# 6 MB corpus used by bench/bench.jl).
using FastAhoCorasick
using Printf

const KEYWORDS = ["trading","strategy","finance","market","the","and","for","with","from","invest"]

hasaho = try
    @eval import AhoCorasick
    true
catch
    @info "AhoCorasick.jl not installed; showing FastAhoCorasick only. `Pkg.add(\"AhoCorasick\")` to compare."
    false
end

function bestns(f, runs)
    r = f()
    b = typemax(UInt64)
    for _ in 1:runs
        t = time_ns(); r = f(); d = time_ns() - t
        d < b && (b = d)
    end
    Base.donotdelete(r)     # keep the result live so the call isn't optimized away
    b
end

# ASCII-only corpus (the input AhoCorasick.jl can consume), sized so its O(n^2) scan finishes.
sizes = length(ARGS) >= 1 ? [parse(Int, ARGS[1])] : [8_000, 32_000, 128_000]

@printf("%-24s %9s %11s %10s %13s %10s\n", "impl", "bytes", "min ms", "MB/s", "allocs(B)", "matches")
println("-"^82)
for approx in sizes
    reps = max(1, approx ÷ 83)
    s = repeat("the quick brown fox and the trading market strategy for finance with invest returns ", reps)
    data = Vector{UInt8}(codeunits(s)); n = length(data)
    fa = build(KEYWORDS); p = pointer(data)
    GC.@preserve data begin
        fc = count_matches_serial(fa, p, n)
        ts = bestns(() -> count_matches_serial(fa, p, n), 200)
        ti = bestns(() -> count_matches(fa, p, n, Val(8)), 200)
        @printf("%-24s %9d %11.4f %10.1f %13d %10d\n", "FastAhoCorasick serial", n, ts/1e6, n/ts*1e3, 0, fc)
        @printf("%-24s %9d %11.4f %10.1f %13d %10d\n", "FastAhoCorasick ILP x8", n, ti/1e6, n/ti*1e3, 0, fc)
    end
    if hasaho
        ac = AhoCorasick.Automaton(false)
        for w in KEYWORDS; AhoCorasick.add(ac, w); end
        AhoCorasick.build(ac)
        ta = bestns(() -> AhoCorasick.search(ac, s), 3)
        aalloc = @allocated AhoCorasick.search(ac, s)
        acount = length(AhoCorasick.search(ac, s))
        @printf("%-24s %9d %11.4f %10.3f %13d %10d\n", "AhoCorasick.jl 0.1.1", n, ta/1e6, n/ta*1e3, aalloc, acount)
        @printf("  -> FastAhoCorasick ILP is %.0fx faster, %d fewer bytes allocated\n", ta/ti, aalloc)
    end
    println()
end
