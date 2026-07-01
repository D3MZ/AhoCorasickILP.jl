"""
    AhoCorasickILP

A native-Julia Aho-Corasick multi-pattern string matcher with **zero heap allocations**
in the match hot loop and a single-thread **multi-stream ILP** kernel that outperforms
Rust's `aho-corasick` crate on this latency-bound workload.

The name is the algorithm plus its edge: **Aho-Corasick** matching accelerated by
**instruction-level parallelism** (ILP) — several independent DFA chains advanced in one
loop on a single thread so the CPU keeps multiple dependent loads in flight, hiding the
memory latency that bounds a naive scan. Not multithreading.

Matching operates on raw UTF-8 **bytes** and folds **ASCII** case only, mirroring
`aho_corasick`'s `.ascii_case_insensitive(true)` — so non-ASCII (Cyrillic/CJK/Arabic)
keywords match identically byte-for-byte.

The count/iteration semantics match `AhoCorasick::find_iter()` in the crate's default
`MatchKind::Standard`: leftmost, non-overlapping matches.

Besides counting and weighted scoring, the automaton supports [`is_match`](@ref),
[`findfirst_match`](@ref), a zero-allocation callback iterator [`each_match`](@ref), and a
collecting [`collect_matches`](@ref) that returns match spans and which pattern hit. Case
folding is ASCII-only by default and can be disabled with `build(...; casesensitive=true)`.

# Example
```julia
a = build(["trading", "strategy", "финансы", "市场"])
count_matches(a, "trading strategy on the 市场")          # => 3
collect_matches(a, "trading 市场")                        # => [AcMatch(1,1,7), AcMatch(4,9,14)]
```
"""
module AhoCorasickILP

export Automaton, AcMatch, build, count_matches, count_matches_serial, sum_weights,
    is_match, findfirst_match, each_match, collect_matches

using Base.Cartesian: @nexprs

# ASCII case-insensitive fold: A-Z -> a-z
@inline fold(b::UInt8) = (b - 0x41 < 0x1a) ? (b + 0x20) : b

"""
    Automaton

A compiled Aho-Corasick automaton laid out as a byte-class, premultiplied DFA:

  * `classof[byte+1]` maps each byte to an equivalence class `0..k`. Every byte absent
    from the pattern alphabet shares class `0` (their transition columns are identical),
    shrinking the table so it stays L1-resident.
  * State ids are **premultiplied**: a state's row begins at index `state`, and stored
    successors are themselves premultiplied — so the hot loop is `next[state + class + 1]`
    with no multiply on the dependent-load critical path.
  * States are ordered so every match state has id `< thresh`; a match is the compare
    `state < thresh`, avoiding a second dependent load per byte.
"""
struct Automaton
    classof::Vector{UInt8}
    next::Vector{UInt32}      # premultiplied transition table
    weightp::Vector{Float64}  # weight indexed by (premultiplied state) + 1
    patid::Vector{UInt32}     # 1-based pattern id at a match state (indexed by premult state + 1)
    patlen::Vector{UInt32}    # matched pattern length in bytes, same indexing
    width::Int                # number of byte classes
    thresh::UInt32            # state < thresh  <=>  match state
    root::UInt32              # premultiplied root id
    nstates::Int
    casesensitive::Bool
end

"""
    AcMatch(pattern, start, stop)

A single match: `pattern` is the 1-based index into the pattern list passed to [`build`](@ref),
and `start:stop` is the inclusive 1-based byte range of the occurrence in the haystack.
"""
struct AcMatch
    pattern::Int
    start::Int
    stop::Int
end

"""
    build(patterns; weights=nothing, casesensitive=false) -> Automaton

Compile `patterns` (a vector of strings) into an [`Automaton`]. Matching is
ASCII-case-insensitive unless `casesensitive=true`. If `weights` is given (one `Float64`
per pattern), the automaton can be used with [`sum_weights`](@ref).
"""
function build(patterns::Vector{<:AbstractString}; weights::Union{Nothing,Vector{Float64}}=nothing,
               casesensitive::Bool=false)
    isempty(patterns) && throw(ArgumentError("patterns must be non-empty"))
    weights === nothing || length(weights) == length(patterns) ||
        throw(ArgumentError("weights must have one entry per pattern"))

    foldb(b::UInt8) = casesensitive ? b : fold(b)

    # --- alphabet reduction: one class per distinct (folded) pattern byte ---
    classof = zeros(UInt8, 256)
    k = 0
    for pat in patterns, ch in codeunits(pat)
        b = foldb(ch)
        if classof[Int(b)+1] == 0
            k += 1
            classof[Int(b)+1] = UInt8(k)
        end
    end
    if !casesensitive
        for b in 0x61:0x7a                  # mirror uppercase onto lowercase class
            c = classof[Int(b)+1]
            c != 0 && (classof[Int(b)-0x20+1] = c)
        end
    end
    W = k + 1

    @inline classix(b::UInt8) = Int(classof[Int(b)+1])

    # --- trie (goto) keyed by class ---
    goto = [Dict{Int,Int}()]                # state 1 = root
    outpat = [0]
    addstate!() = (push!(goto, Dict{Int,Int}()); push!(outpat, 0); length(goto))
    plen = UInt32[ncodeunits(pat) for pat in patterns]   # pattern byte lengths
    for (pid, pat) in enumerate(patterns)
        s = 1
        for ch in codeunits(pat)
            c = classix(foldb(ch))
            nxt = get(goto[s], c, 0)
            if nxt == 0
                nxt = addstate!()
                goto[s][c] = nxt
            end
            s = nxt
        end
        outpat[s] == 0 && (outpat[s] = pid)  # first (highest priority) pattern wins
    end

    n = length(goto)
    fail = fill(1, n)
    trans = Vector{Int}(undef, n * W)       # transitions over classes, original ids
    out = zeros(Int, n)

    # BFS: compute fail links and bake DFA transitions
    queue = Int[]
    for c in 0:k
        s = get(goto[1], c, 0)
        if s == 0
            trans[c + 1] = 1
        else
            trans[c + 1] = s
            fail[s] = 1
            push!(queue, s)
        end
    end
    head = 1
    while head <= length(queue)
        s = queue[head]; head += 1
        fbase = (fail[s]-1)*W
        sbase = (s-1)*W
        for c in 0:k
            t = get(goto[s], c, 0)
            if t == 0
                trans[sbase + c + 1] = trans[fbase + c + 1]
            else
                fail[t] = trans[fbase + c + 1]
                trans[sbase + c + 1] = t
                push!(queue, t)
            end
        end
    end

    out[1] = outpat[1]
    for s in queue
        out[s] = outpat[s] == 0 ? out[fail[s]] : outpat[s]
    end

    # --- reorder so all match states get the smallest ids ---
    remap = Vector{Int}(undef, n)
    m = 0
    for s in 1:n
        out[s] != 0 && (m += 1; remap[s] = m)
    end
    nxtid = m
    for s in 1:n
        out[s] == 0 && (nxtid += 1; remap[s] = nxtid)
    end

    next = Vector{UInt32}(undef, n * W)
    weightp = zeros(Float64, n * W)
    patid = zeros(UInt32, n * W)
    patlen = zeros(UInt32, n * W)
    for s in 1:n
        prem = (remap[s] - 1) * W
        for c in 0:k
            next[prem + c + 1] = UInt32((remap[trans[(s-1)*W + c + 1]] - 1) * W)
        end
        if out[s] != 0
            patid[prem + 1] = UInt32(out[s])
            patlen[prem + 1] = plen[out[s]]
            weights !== nothing && (weightp[prem + 1] = weights[out[s]])
        end
    end

    Automaton(classof, next, weightp, patid, patlen, W, UInt32(m * W),
              UInt32((remap[1] - 1) * W), n, casesensitive)
end

# ---------------------------------------------------------------------------
# Serial kernel: one dependent load per byte.
# ---------------------------------------------------------------------------

"""
    count_matches_serial(a::Automaton, ptr::Ptr{UInt8}, n::Integer) -> Int
    count_matches_serial(a::Automaton, data) -> Int

Count leftmost non-overlapping matches with a single DFA stream. Zero allocations.
This is the direct analogue of Rust's `find_iter().count()`.
"""
function count_matches_serial(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
    state = root; cnt = 0
    @inbounds for i in 1:n
        b = unsafe_load(ptr, i)
        state = next[Int(state) + Int(classof[Int(b)+1]) + 1]
        if state < thresh
            cnt += 1; state = root
        end
    end
    cnt
end

# ---------------------------------------------------------------------------
# Multi-stream ILP kernel (single thread): interleave N independent DFA chains so the
# out-of-order engine overlaps their (otherwise serial) load latencies. Exactness under
# non-overlapping semantics is preserved by a seam fixup that replays each internal
# boundary from the TRUE entering state, threaded forward via `carry` so it stays exact
# even for periodic/self-overlapping patterns.
# ---------------------------------------------------------------------------

@generated function _count_ilp(a::Automaton, ptr::Ptr{UInt8}, n::Integer, ::Val{N}) where {N}
    quote
        classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
        n = Int(n)
        n < 64 * N && return count_matches_serial(a, ptr, n)
        seg = n ÷ N
        cnt = 0
        @nexprs $N k -> (s_k = root)
        @inbounds for t in 1:seg
            @nexprs $N k -> begin
                b_k = unsafe_load(ptr, (k - 1) * seg + t)
                s_k = next[Int(s_k) + Int(classof[Int(b_k) + 1]) + 1]
                if s_k < thresh
                    cnt += 1
                    s_k = root
                end
            end
        end
        @inbounds for i in ($N * seg + 1):n     # tail continues on the last stream
            b = unsafe_load(ptr, i)
            $(Symbol("s_", N)) = next[Int($(Symbol("s_", N))) + Int(classof[Int(b) + 1]) + 1]
            if $(Symbol("s_", N)) < thresh
                cnt += 1
                $(Symbol("s_", N)) = root
            end
        end
        carry = s_1                             # true state entering segment 2
        @nexprs $(N - 1) k -> begin
            @inbounds begin
                strue = carry; sfake = root; j = k * seg + 1
                limit = k == $(N - 1) ? n : (k + 1) * seg     # last seam absorbs the tail
                while j <= limit && strue != sfake
                    b = unsafe_load(ptr, j)
                    c = Int(classof[Int(b) + 1])
                    strue = next[Int(strue) + c + 1]
                    if strue < thresh
                        cnt += 1
                        strue = root
                    end
                    sfake = next[Int(sfake) + c + 1]
                    if sfake < thresh
                        cnt -= 1
                        sfake = root
                    end
                    j += 1
                end
                carry = (strue == sfake) ? s_{k + 1} : strue
            end
        end
        cnt
    end
end

"""
    count_matches(a::Automaton, data; streams::Integer=8) -> Int

Count leftmost non-overlapping matches of `data` (an `AbstractString`, `Ptr{UInt8}`
with a length, or byte vector). Uses a single-thread multi-stream ILP kernel with
`streams` interleaved DFA chains (default 8), falling back to the serial kernel for
short inputs. Zero allocations. Result is identical to [`count_matches_serial`](@ref).

For a call-site-constant, allocation-free `streams`, pass a `Val`:
`count_matches(a, ptr, n, Val(8))`.
"""
count_matches(a::Automaton, ptr::Ptr{UInt8}, n::Integer, ::Val{N}) where {N} = _count_ilp(a, ptr, n, Val(N))

@inline function count_matches(a::Automaton, ptr::Ptr{UInt8}, n::Integer; streams::Integer=8)
    s = Int(streams)
    s <= 1 && return count_matches_serial(a, ptr, n)
    s == 2 && return _count_ilp(a, ptr, n, Val(2))
    s == 3 && return _count_ilp(a, ptr, n, Val(3))
    s == 4 && return _count_ilp(a, ptr, n, Val(4))
    s == 6 && return _count_ilp(a, ptr, n, Val(6))
    s == 8 && return _count_ilp(a, ptr, n, Val(8))
    s == 12 && return _count_ilp(a, ptr, n, Val(12))
    s == 16 && return _count_ilp(a, ptr, n, Val(16))
    _count_ilp(a, ptr, n, Val(8))   # nearest supported
end

# --- convenience methods over strings / byte vectors ---
for f in (:count_matches, :count_matches_serial)
    @eval function $f(a::Automaton, data::AbstractString; kw...)
        GC.@preserve data $f(a, pointer(data), ncodeunits(data); kw...)
    end
    @eval function $f(a::Automaton, data::AbstractVector{UInt8}; kw...)
        GC.@preserve data $f(a, pointer(data), length(data); kw...)
    end
end

"""
    sum_weights(a::Automaton, data) -> Float64

Sum the weights (supplied to [`build`](@ref)) of every leftmost non-overlapping match.
Zero allocations. Single stream.
"""
function sum_weights(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    classof = a.classof; next = a.next; weightp = a.weightp; thresh = a.thresh; root = a.root
    state = root; acc = 0.0
    @inbounds for i in 1:n
        b = unsafe_load(ptr, i)
        state = next[Int(state) + Int(classof[Int(b)+1]) + 1]
        if state < thresh
            acc += weightp[Int(state) + 1]; state = root
        end
    end
    acc
end
sum_weights(a::Automaton, data::AbstractString) = GC.@preserve data sum_weights(a, pointer(data), ncodeunits(data))
sum_weights(a::Automaton, data::AbstractVector{UInt8}) = GC.@preserve data sum_weights(a, pointer(data), length(data))

# ---------------------------------------------------------------------------
# Match inspection: is_match / first match / iterate spans. All share the single
# dependent-load hot loop; only the rare match branch differs.
# ---------------------------------------------------------------------------

"""
    is_match(a::Automaton, data) -> Bool

Return `true` as soon as any pattern matches, scanning left to right. Zero allocations.
"""
function is_match(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
    state = root
    @inbounds for i in 1:n
        state = next[Int(state) + Int(classof[Int(unsafe_load(ptr, i))+1]) + 1]
        state < thresh && return true
    end
    false
end

"""
    findfirst_match(a::Automaton, data) -> Union{AcMatch,Nothing}

Return the first (leftmost-ending) match as an [`AcMatch`](@ref), or `nothing`. Zero allocations.
"""
function findfirst_match(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
    patid = a.patid; patlen = a.patlen
    state = root
    @inbounds for i in 1:n
        state = next[Int(state) + Int(classof[Int(unsafe_load(ptr, i))+1]) + 1]
        if state < thresh
            idx = Int(state) + 1
            return AcMatch(Int(patid[idx]), i - Int(patlen[idx]) + 1, i)
        end
    end
    nothing
end

"""
    each_match(f, a::Automaton, data)

Call `f(pattern, start, stop)` for every leftmost non-overlapping match, in order, where
`pattern` is the 1-based pattern index and `start:stop` the inclusive 1-based byte span.
The building block for [`collect_matches`](@ref).

The scan is allocation-free; to keep the whole call zero-allocation, have `f` accumulate into
a `Ref` (or array) rather than reassigning a captured local (which Julia boxes):

```julia
hits = Ref(0)
each_match((p, s, e) -> (hits[] += 1), a, data)   # 0 allocations
```
"""
function each_match(f::F, a::Automaton, ptr::Ptr{UInt8}, n::Integer) where {F}
    classof = a.classof; next = a.next; thresh = a.thresh; root = a.root
    patid = a.patid; patlen = a.patlen
    state = root
    @inbounds for i in 1:n
        state = next[Int(state) + Int(classof[Int(unsafe_load(ptr, i))+1]) + 1]
        if state < thresh
            idx = Int(state) + 1
            f(Int(patid[idx]), i - Int(patlen[idx]) + 1, i)
            state = root
        end
    end
    nothing
end

"""
    collect_matches(a::Automaton, data) -> Vector{AcMatch}

Collect every leftmost non-overlapping match with its pattern index and byte span. Allocates
the result vector; the scan itself uses the same zero-allocation kernel as [`each_match`](@ref).
"""
function collect_matches(a::Automaton, ptr::Ptr{UInt8}, n::Integer)
    out = AcMatch[]
    each_match((p, s, e) -> push!(out, AcMatch(p, s, e)), a, ptr, n)
    out
end

# --- convenience methods over strings / byte vectors ---
for f in (:is_match, :findfirst_match, :collect_matches)
    @eval $f(a::Automaton, data::AbstractString) = GC.@preserve data $f(a, pointer(data), ncodeunits(data))
    @eval $f(a::Automaton, data::AbstractVector{UInt8}) = GC.@preserve data $f(a, pointer(data), length(data))
end
each_match(f, a::Automaton, data::AbstractString) = GC.@preserve data each_match(f, a, pointer(data), ncodeunits(data))
each_match(f, a::Automaton, data::AbstractVector{UInt8}) = GC.@preserve data each_match(f, a, pointer(data), length(data))

end # module
