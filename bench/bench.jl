# Head-to-head benchmark: AhoCorasickILP (native Julia) vs the `aho-corasick` Rust crate.
# Runs the native Rust reference binary (built separately) and the Julia kernels on the
# SAME byte-identical corpus, using @allocated + a min-of-many-runs timer to reduce noise.
#
#   julia --project=. bench/bench.jl [corpus_path] [rust_min_ns]
#
# If rust_min_ns is omitted, bench.jl runs bench/rust_ref/target/release/ac_ref itself.
using AhoCorasickILP
using Printf

const KEYWORDS = ["trading","strategy","finance","market","the","and","for","with","from","invest"]

corpuspath = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "corpus.txt")
isfile(corpuspath) || error("corpus not found: $corpuspath (run: julia bench/make_corpus.jl)")
data = read(corpuspath)                     # Vector{UInt8}
nb = length(data)

# --- min-of-many-runs timer (BenchmarkTools-free so bench has no extra deps) ---
function bestns(f, runs)
    f()                                     # warmup / compile
    best = typemax(UInt64)
    for _ in 1:runs
        t = time_ns()
        f()
        d = time_ns() - t
        d < best && (best = d)
    end
    best
end

a = build(KEYWORDS)
p = pointer(data)

results = Tuple{String,Float64,Int}[]       # (label, min_ns, allocs)
GC.@preserve data begin
    refcount = count_matches_serial(a, p, nb)
    # Rust reference
    rustns = if length(ARGS) >= 2
        parse(Float64, ARGS[2])
    else
        bin = joinpath(@__DIR__, "rust_ref", "target", "release", "ac_ref")
        if isfile(bin)
            out = read(`$bin $corpuspath 2000`, String)
            m = match(r"count=(\d+) min_ns=(\d+)", out)
            rc = parse(Int, m.captures[1])
            rc == refcount || @warn "Rust/Julia count mismatch" rust=rc julia=refcount
            parse(Float64, m.captures[2])
        else
            @warn "Rust binary not built; skipping (build in bench/rust_ref)."
            NaN
        end
    end
    isnan(rustns) || push!(results, ("Rust aho-corasick 1.1", rustns, 3))

    runs = 3000
    push!(results, ("Julia serial (1 stream)", Float64(bestns(() -> count_matches_serial(a, p, nb), runs)), 0))
    for N in (2, 3, 4, 6, 8)
        push!(results, ("Julia ILP ($N streams)", Float64(bestns(() -> count_matches(a, p, nb, Val(N)), runs)), 0))
    end
end

# --- report ---
@printf("\nCorpus: %s  (%.2f MB, %d keywords, %d matches)\n\n", basename(corpuspath), nb/1e6, length(KEYWORDS), count_matches_serial(a, p, nb))
@printf("%-26s %10s %10s %8s %8s\n", "implementation", "min (ms)", "GB/s", "allocs", "vs Rust")
println("-"^68)
rustns = isempty(results) ? NaN : (results[1][1] == "Rust aho-corasick 1.1" ? results[1][2] : NaN)
for (label, ns, allocs) in results
    ratio = isnan(rustns) ? "" : @sprintf("%.2fx", rustns/ns)
    @printf("%-26s %10.3f %10.2f %8d %8s\n", label, ns/1e6, nb/ns, allocs, ratio)
end

# CSV for plotting
open(joinpath(@__DIR__, "results.csv"), "w") do io
    println(io, "label,min_ns,gbps,allocs")
    for (label, ns, allocs) in results
        @printf(io, "%s,%.1f,%.4f,%d\n", label, ns, nb/ns, allocs)
    end
end
println("\nwrote bench/results.csv")
