# FastAhoCorasick.jl

A native-Julia [Aho–Corasick](https://en.wikipedia.org/wiki/Aho%E2%80%93Corasick_algorithm)
multi-pattern matcher with **zero heap allocations** in the match loop and a single-thread
**multi-stream ILP** kernel that runs **~4.8× faster than Rust's `aho-corasick` crate** on a
6 MB corpus (Apple M1 Max, single thread) while producing identical counts.

Matching operates on raw UTF-8 **bytes** and folds **ASCII case only** (mirroring
`aho_corasick`'s `.ascii_case_insensitive(true)`), so non-ASCII keywords match byte-for-byte.
Counts follow `MatchKind::Standard`: leftmost, non-overlapping — identical to Rust's
`find_iter().count()`.

## Installation

```julia
pkg> add https://github.com/D3MZ/FastAhoCorasick.jl
```

## Quick start

```julia
using FastAhoCorasick

a = build(["trading", "strategy", "финансы", "市场"])
count_matches(a, "TRADING Strategy on the 市场")          # => 3   (multi-stream, 0 alloc)
is_match(a, "no keywords here")                          # => false
findfirst_match(a, "xx trading")                         # => AcMatch(1, 4, 10)
collect_matches(a, "trading 市场")                       # => [AcMatch(1,1,7), AcMatch(4,9,14)]

w = build(["buy", "sell"]; weights = [1.0, -1.0])
sum_weights(w, "buy buy sell")                           # => 1.0

cs = build(["ABC"]; casesensitive = true)
count_matches(cs, "abc ABC")                             # => 1
```

## How it works

The match loop is a latency-bound pointer chase (`state = next[state + class(byte)]`), so the
implementation (1) shrinks the transition table with byte-class alphabet reduction and
premultiplied state ids to keep it L1-resident with no multiply on the critical path, (2) orders
match states first so a match is a compare rather than a second load, and (3) interleaves N
independent DFA chains in one loop so the out-of-order engine overlaps their load latencies —
instruction-level parallelism on a single thread, not multithreading. Exactness at the slice
seams is preserved by replaying each boundary from the true entering state.

See the [README](https://github.com/D3MZ/FastAhoCorasick.jl#how-it-works) for the full write-up
and benchmark plot, [Comparison](comparison.md) for how it stacks up against Rust's
`aho-corasick` and the registry's `AhoCorasick.jl`, and the [API reference](@ref) for the
functions.

## [API reference](@id api)

See [API](api.md) for full docstrings of [`build`](@ref), [`count_matches`](@ref),
[`count_matches_serial`](@ref), [`sum_weights`](@ref), and [`Automaton`](@ref).
