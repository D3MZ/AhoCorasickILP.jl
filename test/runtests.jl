using AhoCorasickILP
using Test

# Reference: naive leftmost non-overlapping count over ASCII-folded bytes.
foldb(b::UInt8) = (0x41 <= b <= 0x5a) ? b + 0x20 : b
function naive_count(patterns, text)
    pats = [Vector{UInt8}(foldb.(codeunits(p))) for p in patterns]
    data = Vector{UInt8}(foldb.(codeunits(text)))
    i = 1; n = length(data); cnt = 0
    while i <= n
        best = 0  # end index of the earliest-ending match starting at i
        for p in pats
            lp = length(p)
            if lp > 0 && i + lp - 1 <= n && @views data[i:i+lp-1] == p
                if best == 0 || lp < best
                    best = lp
                end
            end
        end
        if best != 0
            cnt += 1
            i += best      # non-overlapping: resume after the match
        else
            i += 1
        end
    end
    cnt
end

@testset "correctness vs naive reference" begin
    sets = [
        ["trading", "strategy", "finance", "market", "the", "and"],
        ["he", "she", "his", "hers", "the", "there", "her"],
        ["a", "ab", "abc", "bc", "c"],
        ["aa", "aaa"],
        ["x"],
        ["финансы", "市场", "трейдинг", "TRADING"],   # multilingual + ASCII case
    ]
    texts = [
        "TRADING the Market with a Strategy and finance",
        "shethersheisthereherhersaaaabcabcabcxxxthethethe",
        repeat("theandforaaabcxyshehers ", 200),
        repeat("aaaaaa", 150) * "bcabcxx" * repeat("she", 60),
        "no matches here",
        "трейдинг on the 市场 with финансы and TRADING",
        "",
    ]
    for kw in sets, txt in texts
        a = build(kw)
        want = naive_count(kw, txt)
        @test count_matches_serial(a, txt) == want
        for N in (2, 3, 4, 5, 7, 8, 16)
            @test count_matches(a, txt; streams=N) == want
        end
    end
end

@testset "ascii case-insensitivity, non-ascii is case-sensitive" begin
    a = build(["ABC"])
    @test count_matches_serial(a, "xxabcXXAbC") == 2
    b = build(["Ω"])                    # U+03A9; lowercase ω is a different codepoint
    @test count_matches_serial(b, "Ω") == 1
    @test count_matches_serial(b, "ω") == 0
end

@testset "weights" begin
    a = build(["buy", "sell", "hold"]; weights=[1.0, -1.0, 0.5])
    @test sum_weights(a, "buy buy sell hold") ≈ 1.0 + 1.0 - 1.0 + 0.5
    @test sum_weights(a, "nothing") == 0.0
end

@testset "zero allocations in hot loop" begin
    a = build(["trading", "strategy", "finance", "market", "the", "and"])
    data = Vector{UInt8}(codeunits(repeat("the market strategy for trading and finance ", 5000)))
    function eachcount(auto, bytes)   # 0-alloc when the sink is a Ref (no boxed local)
        c = Ref(0)
        each_match((p, s, e) -> (c[] += 1), auto, bytes)
        c[]
    end
    GC.@preserve data begin
        p = pointer(data); n = length(data)
        # always exercise the kernels (coverage on every Julia version)
        count_matches_serial(a, p, n); count_matches(a, p, n, Val(8))
        is_match(a, p, n); findfirst_match(a, p, n); eachcount(a, data)
        # the exact 0-allocation guarantee is asserted on Julia >= 1.11, where codegen
        # reliably elides the frame; 1.10's @allocated leaves a few bytes on these micro-calls.
        if VERSION >= v"1.11"
            @test (@allocated count_matches_serial(a, p, n)) == 0
            @test (@allocated count_matches(a, p, n, Val(8))) == 0
            @test (@allocated is_match(a, p, n)) == 0
            @test (@allocated findfirst_match(a, p, n)) == 0
            @test (@allocated eachcount(a, data)) == 0
        end
    end
    @test count_matches_serial(a, data) == eachcount(a, data)
end

@testset "all public method forms and stream widths" begin
    a = build(["trading", "market", "the"])
    s = "the trading market and the market"
    want = count_matches_serial(a, s)
    bytes = Vector{UInt8}(codeunits(s))
    # string, byte-vector, and pointer forms of both counters
    @test count_matches_serial(a, bytes) == want
    @test count_matches(a, bytes) == want
    @test count_matches(a, s) == want
    GC.@preserve bytes begin
        @test count_matches_serial(a, pointer(bytes), length(bytes)) == want
        @test count_matches(a, pointer(bytes), length(bytes), Val(3)) == want
    end
    # every streams branch in the keyword dispatch (1 -> serial, listed values, and a fallback)
    for st in (1, 2, 3, 4, 6, 8, 12, 16, 5, 7, 9, 100)
        @test count_matches(a, s; streams=st) == want
    end
    # weighted byte-vector form
    w = build(["trading", "market"]; weights=[2.0, 3.0])
    @test sum_weights(w, bytes) == sum_weights(w, s)
end

@testset "match inspection: is_match / findfirst_match / each_match / collect_matches" begin
    a = build(["trading", "strategy", "финансы", "市场"])
    s = "trading 市场"
    @test is_match(a, s)
    @test !is_match(a, "nothing here")
    @test findfirst_match(a, "xx trading") == AcMatch(1, 4, 10)
    @test findfirst_match(a, "市场 first") == AcMatch(4, 1, 6)
    @test findfirst_match(a, "no keywords") === nothing
    ms = collect_matches(a, s)
    @test ms == [AcMatch(1, 1, 7), AcMatch(4, 9, 14)]
    # spans are exact byte ranges; verify against the source text
    for m in ms
        @test codeunits(s)[m.start:m.stop] == codeunits(["trading","strategy","финансы","市场"][m.pattern])
    end
    # each_match with a non-allocating accumulator, and the byte-vector form
    tot = Ref(0)
    each_match((p, st, en) -> (tot[] += p), a, Vector{UInt8}(codeunits(s)))
    @test tot[] == 1 + 4
    @test is_match(a, Vector{UInt8}(codeunits(s)))
    @test collect_matches(a, Vector{UInt8}(codeunits("市场"))) == [AcMatch(4, 1, 6)]
    # overlapping-suffix pattern: a match reported via a fail link keeps the right span
    b = build(["she", "he"])
    @test collect_matches(b, "ushers") == [AcMatch(1, 2, 4)]   # leftmost non-overlapping "she"
end

@testset "case-sensitive mode" begin
    ci = build(["ABC"])                       # default: ASCII case-insensitive
    cs = build(["ABC"]; casesensitive=true)
    @test count_matches_serial(ci, "xxabcABC") == 2
    @test count_matches_serial(cs, "xxabcABC") == 1          # only the exact-case "ABC"
    @test findfirst_match(cs, "abcABC") == AcMatch(1, 4, 6)
    @test count_matches(cs, "abcABCabc"; streams=4) == 1
    @test sum_weights(build(["ABC"]; weights=[2.0], casesensitive=true), "abcABC") == 2.0
end

@testset "empty / edge inputs" begin
    a = build(["ab"])
    @test count_matches_serial(a, "") == 0
    @test count_matches(a, ""; streams=8) == 0
    @test count_matches_serial(a, "a") == 0
    @test count_matches_serial(a, "ab") == 1
    @test_throws ArgumentError build(String[])
end
