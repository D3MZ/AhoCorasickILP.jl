// Native Rust reference benchmark for `aho-corasick` (no FFI — the fairest possible
// comparison). Reads a corpus file, builds the same automaton AhoCorasickILP uses,
// and reports the minimum wall time of `find_iter().count()` over many runs.
use aho_corasick::AhoCorasick;
use std::time::Instant;

const KEYWORDS: &[&str] = &[
    "trading", "strategy", "finance", "market", "the", "and", "for", "with", "from", "invest",
];

fn main() {
    let path = std::env::args().nth(1).expect("usage: ac_ref <corpus>");
    let runs: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2000);
    let data = std::fs::read(&path).expect("read corpus");

    let ac = AhoCorasick::builder()
        .ascii_case_insensitive(true)
        .build(KEYWORDS)
        .expect("build automaton");

    // warmup + capture count for cross-language correctness check
    let mut count = 0usize;
    for _ in 0..20 {
        count = ac.find_iter(&data).count();
    }

    let mut best = u128::MAX;
    for _ in 0..runs {
        let t = Instant::now();
        let c = ac.find_iter(&data).count();
        let ns = t.elapsed().as_nanos();
        std::hint::black_box(c);
        if ns < best {
            best = ns;
        }
    }

    // machine-readable line consumed by bench.jl
    println!("RUST_RESULT bytes={} count={} min_ns={}", data.len(), count, best);
}
