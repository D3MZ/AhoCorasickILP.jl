# AhoCorasickILP.jl

[![CI](https://github.com/D3MZ/AhoCorasickILP.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/D3MZ/AhoCorasickILP.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/D3MZ/AhoCorasickILP.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/D3MZ/AhoCorasickILP.jl)
[![docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://D3MZ.github.io/AhoCorasickILP.jl/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Native-Julia [Aho–Corasick](https://en.wikipedia.org/wiki/Aho%E2%80%93Corasick_algorithm) multi-pattern search: **allocation-free**, and faster than both Rust's [`aho-corasick`](https://crates.io/crates/aho-corasick) crate and the other Julia package — on a single thread via **multi-stream ILP**. It counts, weight-scores, and locates matches over raw UTF-8 bytes.

**What the name means.** Aho–Corasick scanning is a *latency-bound pointer chase*: each byte does `state = next[state + class(byte)]`, and every lookup's address depends on the previous lookup's result, so a naive loop stalls on memory one dependent load at a time. This package hides that stall with **ILP — instruction-level parallelism**: it advances `N` independent DFA chains over `N` slices of the input *in one loop on one thread*, so the CPU's out-of-order engine keeps several of those loads in flight at once. That's the whole edge — **`AhoCorasick` + `ILP`** — and it's why the single-thread `×N streams` kernel beats an otherwise-identical serial DFA (and Rust's). It is **not** multithreading and uses no SIMD.

<p align="center"><img src="bench/benchmark.png" width="820" alt="benchmark"></p>

| 64 KB input, M1 Max, single thread | time | throughput | allocations |
|---|---:|---:|---:|
| **AhoCorasickILP — ×8 streams** | **0.027 ms** | **2,465 MB/s** | **0** |
| AhoCorasickILP — serial | 0.153 ms | 434 MB/s | 0 |
| Rust `aho-corasick` 1.1 (native) | 0.226 ms | 293 MB/s | 0 |
| `AhoCorasick.jl` 0.1.1 (registry) | 2,200 ms | 0.03 MB/s | 2.1 GB |

<sub>All find the same 7,900 matches. On a 6 MB corpus the ILP kernel is 4.8× faster than Rust (`AhoCorasick.jl` can't complete it). Reproduce: `bench/run.sh`, `bench/compare_libraries.jl`.</sub>

## Install

```julia
pkg> add https://github.com/D3MZ/AhoCorasickILP.jl
```

## Usage

```julia
using AhoCorasickILP

a = build(["trading", "strategy", "финансы", "市场"])   # ASCII case-insensitive

count_matches(a, "TRADING Strategy on the 市场")         # 3   — multi-stream, 0 alloc
is_match(a, "no keywords")                               # false
findfirst_match(a, "xx trading")                         # AcMatch(1, 4, 10)  (pattern, start, stop)
collect_matches(a, "trading 市场")                       # [AcMatch(1,1,7), AcMatch(4,9,14)]

hits = Ref(0)                                            # zero-alloc streaming callback
each_match((pattern, start, stop) -> (hits[] += 1), a, "trading and trading")

sum_weights(build(["buy","sell"]; weights=[1.0,-1.0]), "buy buy sell")   # 1.0  — relevance score
count_matches(build(["ABC"]; casesensitive=true), "abc ABC")             # 1    — exact case
```

Matching is on raw **UTF-8 bytes**, folding **ASCII** case only (like the crate's `.ascii_case_insensitive(true)`), so Cyrillic/CJK/Arabic keywords match byte-for-byte. Counts follow `MatchKind::Standard` — leftmost, non-overlapping — identical to Rust's `find_iter().count()`.

## Features vs. the alternatives

| | Rust `aho-corasick` | `AhoCorasick.jl` 0.1.1 | **AhoCorasickILP** |
|---|:---:|:---:|:---:|
| Count non-overlapping · match spans + which pattern | ✓ · ✓ | ✓ · ✓ | ✓ · ✓ |
| `is_match` / first match | ✓ | – | ✓ |
| Overlapping enumeration · per-pattern keys | ✓ · – | ✓ · ✓ | ✗ · ✗ |
| Weighted score (`sum_weights`) | – | – | ✓ |
| Case-insensitive · case-sensitive | ✓ ASCII · ✓ | ✓ Unicode · ✓ | ✓ ASCII · ✓ |
| Replace / streaming I/O | ✓ | ✗ | ✗ |
| Multibyte-UTF-8 safe | ✓ | ✗ (`StringIndexError`) | ✓ |
| Allocation-free · complexity | ✗ FFI · O(n) | ✗ · **O(n²)** | ✓ · O(n) |
| Language · license | Rust · MIT/Unlicense | Julia · GPLv3 | Julia · MIT |

AhoCorasickILP trades overlapping enumeration, per-pattern keys, and replace/streaming for being the only **allocation-free** option, adding weighted scoring, and running far faster. `AhoCorasick.jl` is O(n²) (it recopies `text[2:end]` each character) and throws on multibyte input. Details: [docs → Comparison](https://D3MZ.github.io/AhoCorasickILP.jl/).

## How it works

Matching is a **latency-bound pointer chase** — `state = next[state + class(byte)]`, each load's address depending on the last. AhoCorasickILP minimizes that load with a **cache-resident DFA** (byte-class alphabet reduction + premultiplied state ids + match-states-first, the same layout as Rust's), then hides its latency with **multi-stream ILP**: `N` independent DFA chains run in one loop over `N` slices so the out-of-order engine keeps several loads in flight — one thread, no SIMD. Splitting stays exact by replaying each seam from the true entering state (verified against a naive reference, even for periodic patterns). The serial kernel is on par with the crate's DFA; the ILP win is a single-thread trick the crate could also adopt.

## License

MIT © Demetrius Michael · `bench/run.sh` and `bench/compare_libraries.jl` reproduce the numbers.
