# Comparison with other Aho-Corasick implementations

This page records how AhoCorasickILP relates to the two other Aho-Corasick implementations
it is most often weighed against: Rust's `aho-corasick` crate and the registered pure-Julia
`AhoCorasick.jl`.

## Feature matrix

| Capability | Rust `aho-corasick` | `AhoCorasick.jl` 0.1.1 | AhoCorasickILP |
|---|:---:|:---:|:---:|
| Count non-overlapping | ✓ | ✓ | ✓ |
| Match spans + which pattern | ✓ | ✓ | ✓ (`findfirst_match`, `each_match`, `collect_matches`) |
| `is_match` / first match | ✓ | – | ✓ |
| Overlapping enumeration | ✓ | ✓ | ✗ |
| Per-pattern attached keys | – | ✓ | ✗ |
| Weighted score | – | – | ✓ (`sum_weights`) |
| Case-insensitive | ✓ ASCII | ✓ Unicode | ✓ ASCII |
| Case-sensitive | ✓ | ✓ | ✓ (`casesensitive=true`) |
| Replace / streaming I/O | ✓ | ✗ | ✗ |
| Multibyte-UTF-8 safe | ✓ | ✗ | ✓ |
| Allocation-free matching | ✗ (FFI 3/call) | ✗ | ✓ |
| Time complexity | O(n) | O(n²) | O(n) |
| Language · license | Rust · MIT/Unlicense | Julia · GPLv3 | Julia · MIT |

## vs. Rust `aho-corasick`

AhoCorasickILP's serial kernel is a like-for-like port of the crate's DFA (byte-class
alphabet reduction, premultiplied state ids, match-state-first ordering), so on the raw
single-stream loop the two sit within ~1.15× of each other — both are bounded by the same
one-dependent-load-per-byte L1 latency. The single-thread multi-stream ILP kernel then
interleaves independent DFA chains to hide that latency, pulling ahead of the crate while
staying on one thread and allocation-free. On a 6 MB corpus (Apple M1 Max):

| implementation | min time | throughput | allocations |
|---|---:|---:|---:|
| Rust `aho-corasick` 1.1 (native, LTO) | 11.25 ms | 0.53 GB/s | 3 |
| Julia serial (same algorithm) | 13.02 ms | 0.46 GB/s | **0** |
| **Julia ILP ×8** | **2.33 ms** | **2.57 GB/s** | **0** |

The ILP technique is not exclusive to Julia — the crate could adopt it too. This is a win for
the native matcher *as it exists*, not a claim that Julia's compiler beats LLVM on the
identical loop. Both fold ASCII case only and match raw UTF-8 bytes, so multilingual keywords
behave identically.

## vs. `AhoCorasick.jl` (registry package)

[`AhoCorasick.jl`](https://github.com/Wilfridovich17/AhoCorasick.jl) (v0.1.1, GPLv3) is the
other Aho-Corasick package in the General registry. It solves a **different** problem, so the
two are not at feature parity:

| | AhoCorasickILP | AhoCorasick.jl 0.1.1 |
|---|---|---|
| Match model | leftmost **non-overlapping** | all **overlapping** occurrences |
| Returns | match **count** / weighted **score** | `Vector{Match}` with **positions** + optional **keys** |
| Match positions & per-pattern metadata | ✗ | ✓ |
| Case folding | ASCII (matches Rust's crate) | Unicode `lowercase` |
| Non-ASCII / multibyte input | ✓ (byte-level) | ✗ — throws `StringIndexError` (indexes `text[2:end]`) |
| Time complexity | **O(n)** | **O(n²)** (copies `text[2:end]` every char) |
| Allocations | **0** | `Vector{Match}` + O(n²) string copies |
| Precompiles cleanly | ✓ | ✗ (duplicate `include`) |
| License | MIT | GPLv3 |

**What `AhoCorasick.jl` offers that this package does not:** match *positions* (`start`,
`length`), an arbitrary *key* attached to each pattern and returned per match, *overlapping*
enumeration, and case folding beyond ASCII. If you need spans or per-pattern metadata, it has
features AhoCorasickILP omits by design.

**What this package offers that it does not:** zero allocations, O(n) scaling, multibyte-safe
byte-level matching, weighted scoring, and orders-of-magnitude more throughput.

### Throughput (ASCII input, Apple M1 Max, 64 KB)

`AhoCorasick.jl` throws on the multilingual corpus, so this measures ASCII text it can consume
(64 KB, all four implementations on the same bytes):

| implementation | min time | throughput | allocations | matches |
|---|---:|---:|---:|---:|
| **AhoCorasickILP ×8 streams** | **0.027 ms** | **2,465 MB/s** | **0** | 7,900 |
| AhoCorasickILP serial | 0.153 ms | 434 MB/s | 0 | 7,900 |
| Rust `aho-corasick` 1.1 | 0.226 ms | 293 MB/s | 0 | 7,900 |
| AhoCorasick.jl 0.1.1 | 2,200 ms | 0.03 MB/s | 2.1 GB | 7,900 |

That is roughly **80,000× faster and allocation-free**. The counts agree here only because
these keywords do not physically overlap; they diverge when matches overlap (AhoCorasick.jl
counts every overlapping occurrence, AhoCorasickILP counts non-overlapping like Rust's
`find_iter`).

### Why the quadratic blow-up

`AhoCorasick.jl`'s search loop does `text = text[2:end]` on every character, allocating a fresh
copy of the remaining input each step. Cost therefore grows with the square of the input:

| input size | AhoCorasick.jl 0.1.1 | AhoCorasickILP (O(n), flat throughput) |
|---:|---:|---:|
| 2 KB | 1.5 ms | <0.01 ms |
| 8 KB | 27 ms | <0.01 ms |
| 32 KB | 367 ms | ~0.07 ms |

The same `text[2:end]` byte-indexing is what makes it unsafe on multibyte UTF-8: indexing into
the middle of a multi-byte character raises `StringIndexError`.

### Reproduce

```julia
julia> using Pkg; Pkg.add("AhoCorasick")   # GPLv3; not a dependency of this package
```

```bash
julia bench/compare_libraries.jl
```
