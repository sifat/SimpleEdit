import Foundation
import Testing
@testable import SyntaxCore

/// The time budget is what bounds the worst case. The size caps cannot: the
/// worst case is set by nesting depth and unbalanced brackets, which are
/// quadratic, and a byte count does not see them.
@Suite("Time budget")
struct TimeBudgetTests {

    private func parser(_ language: SyntaxLanguage) throws -> SyntaxParser {
        try #require(SyntaxParser(language: language, queriesRoot: QueryLoadingTests.queriesRoot))
    }

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
    }

    /// Parse-bound: unclosed tags nest, and the parse is quadratic in depth.
    /// Unbounded this is ~400 ms at the size cap in release, several seconds
    /// above it.
    @Test("A parse that runs out of time yields no tokens, promptly")
    func parseIsBounded() throws {
        let p = try parser(.html)
        let hostile = String(repeating: "<b>", count: 20_000)
        var result = SyntaxTokenList.empty
        let seconds = elapsed { result = p.tokens(for: hostile, budget: 0.005) }
        #expect(result.isEmpty)
        #expect(seconds < 0.5, "took \(seconds)s")
    }

    /// Query-bound: 64,000 unclosed parens parse in milliseconds and then take
    /// seconds inside the query cursor. A parse-only budget would not catch it.
    @Test("A query that runs out of time yields no tokens, promptly")
    func queryIsBounded() throws {
        let p = try parser(.javascript)
        let hostile = String(repeating: "(", count: 30_000)
        var result = SyntaxTokenList.empty
        let seconds = elapsed { result = p.tokens(for: hostile, budget: 0.005) }
        #expect(result.isEmpty)
        #expect(seconds < 0.5, "took \(seconds)s")
    }

    /// The bug that has to be prevented, not merely the feature. tree-sitter
    /// RESUMES a cancelled parse on the next call to the same parser unless it
    /// is reset -- and the next call is the next keystroke, on a document that
    /// may be entirely different. Without the reset, the returned tree is a
    /// fragment of the previous text with offsets past the end of the current
    /// one, and those offsets go straight to TextKit as token ranges.
    @Test("After a cancelled parse, the next parse starts from scratch")
    func cancelledParseIsReset() throws {
        let p = try parser(.html)
        let hostile = String(repeating: "<b>", count: 20_000)
        #expect(p.tokens(for: hostile, budget: 0.001).isEmpty)

        let ordinary = "<p class=\"x\">hello</p>"
        let tokens = p.tokens(for: ordinary).tokens
        let text = ordinary as NSString
        #expect(tokens.map { text.substring(with: $0.range) } == ["<", "p", "class", "x", ">", "</", "p", ">"])
        for token in tokens {
            #expect(NSMaxRange(token.range) <= text.length, "range \(token.range) is outside the document")
        }
    }

    /// The same thing on the query side: a cancelled cursor must not leave
    /// state that leaks into the next document.
    @Test("After a cancelled query, the next document is complete")
    func cancelledQueryLeavesNothingBehind() throws {
        let p = try parser(.javascript)
        #expect(p.tokens(for: String(repeating: "(", count: 30_000), budget: 0.001).isEmpty)
        let found = p.tokens(for: "const n = 1; // done").tokens
        #expect(found.count == 5)
    }

    /// The other half of the contract: an ordinary document is never cut. The
    /// budget is generous relative to a normal file at its cap, and this pins
    /// that an unlimited budget and the default one agree.
    ///
    /// The document is small on purpose. `swift test` builds debug, which is
    /// 4-5x slower than the release build the app ships, and runs suites in
    /// parallel on a loaded machine; a document that is ordinary for the app
    /// can still trip an 80 ms budget under those conditions and make this
    /// test flaky. What is being tested is the contract, not the constant.
    @Test("An ordinary document is not affected by the default budget")
    func ordinaryDocumentIsWhole() throws {
        let p = try parser(.javascript)
        let source = String(repeating: "function f(a, b) { return a.map((x) => x * 2 + b); }\n", count: 60)
        let unlimited = p.tokens(for: source, budget: 60)
        let normal = p.tokens(for: source)
        #expect(!normal.isEmpty)
        #expect(normal == unlimited)
    }

    /// A child that runs out of time leaves its own region plain and nothing
    /// else. The markup is tiny and finishes instantly; the script body is a
    /// query-bound pathology that cannot finish inside the budget.
    @Test("An injected region that runs out of time is left plain, the rest is not")
    func childRunsOutAlone() throws {
        let p = try parser(.html)
        let script = String(repeating: "(", count: 30_000)
        let source = "<p class=\"x\">hi</p><script>\(script)</script>"
        // The HTML around the script is cheap and would have parsed. It is
        // discarded anyway: a cut in any child is a cut of the whole call, so
        // the document is left plain and -- the part that matters -- the
        // highlighter is told it was cut and spaces out the next attempts.
        // Before this was so, the outer tokens came back as a success, the
        // backoff reset, and this document cost the whole budget on every
        // keystroke.
        #expect(p.tokens(for: source, budget: 0.02).isEmpty)
        #expect(p.lastCallWasCut)
    }

    /// The other child path. A combined injection parses through included
    /// ranges rather than a substring, and it is the only path that calls
    /// ts_parser_set_included_ranges under a deadline.
    @Test("A cut inside a combined child is a cut of the whole call")
    func combinedChildRunsOut() throws {
        let p = try parser(.php)
        let flood = String(repeating: "<b>", count: 30_000)
        let source = "<?php $a = 1; ?>\n\(flood)\n<?php echo $a; ?>"
        #expect(p.tokens(for: source, budget: 0.02).isEmpty)
        #expect(p.lastCallWasCut)
        // ...and the flag is not sticky: a document that fits is a success.
        #expect(!p.tokens(for: "<?php echo 1; ?>").isEmpty)
        #expect(!p.lastCallWasCut)
    }

    @Test("A zero budget still returns rather than looping")
    func zeroBudget() throws {
        let p = try parser(.css)
        _ = p.tokens(for: ".a { color: red; }", budget: 0)
        // ...and the parser is still usable afterwards.
        #expect(!p.tokens(for: ".a { color: red; }").isEmpty)
    }
}

@Suite("Time budget edge values")
struct TimeBudgetEdgeTests {
    /// `UInt64(Double)` traps on infinity and NaN. A caller passing `.infinity`
    /// to mean "no budget" is the obvious spelling, so it must not crash.
    @Test("Non-finite and negative budgets do not trap", arguments: [Double.infinity, .nan, -1, 0, 1e12])
    func unusualBudgets(budget: Double) throws {
        let p = try #require(SyntaxParser(language: .css, queriesRoot: QueryLoadingTests.queriesRoot))
        let source = ".a { color: red; }"
        _ = p.tokens(for: source, budget: budget)
        // ...and the parser still works afterwards with the default budget.
        #expect(!p.tokens(for: source).isEmpty)
    }
}

@Suite("Cut backoff")
struct CutBackoffTests {

    /// The decision table, written out: skips of 1, 3, 7, then 7 forever.
    @Test("Attempts are spaced 1, 3, 7, 7, ... keystrokes apart after cuts")
    func spacing() {
        var b = CutBackoff()
        var skipsBetweenAttempts: [Int] = []
        var skipped = 0
        for _ in 0..<60 {
            if b.shouldAttempt() {
                skipsBetweenAttempts.append(skipped)
                skipped = 0
                b.record(cut: true)
            } else {
                skipped += 1
            }
        }
        #expect(skipsBetweenAttempts.prefix(6) == [0, 1, 3, 7, 7, 7])
    }

    /// The property a user notices: one success resets everything, so colour
    /// is back on the very next keystroke once the text is parseable.
    @Test("A success resets the spacing to zero")
    func successResets() {
        var b = CutBackoff()
        for _ in 0..<3 { _ = b.shouldAttempt(); b.record(cut: true) }
        while !b.shouldAttempt() {}
        b.record(cut: false)
        let first = b.shouldAttempt()
        let second = b.shouldAttempt()
        #expect(first && second)
    }

    @Test("A fresh document has no history to back off from")
    func reset() {
        var b = CutBackoff()
        _ = b.shouldAttempt(); b.record(cut: true)
        let skipped = !b.shouldAttempt()
        #expect(skipped)
        b.reset()
        let attempted = b.shouldAttempt()
        #expect(attempted)
    }

    @Test("A never-cut document never skips")
    func neverCut() {
        var b = CutBackoff()
        for _ in 0..<20 {
            let attempt = b.shouldAttempt()
            #expect(attempt)
            b.record(cut: false)
        }
    }

    /// The parser reports whether it was cut, since an empty result cannot.
    @Test("The parser distinguishes a cut from an empty document")
    func parserReportsCuts() throws {
        let p = try #require(SyntaxParser(language: .html, queriesRoot: QueryLoadingTests.queriesRoot))
        _ = p.tokens(for: String(repeating: "<b>", count: 20_000), budget: 0)
        #expect(p.lastCallWasCut)
        _ = p.tokens(for: "")
        #expect(!p.lastCallWasCut)
        _ = p.tokens(for: "<p>x</p>")
        #expect(!p.lastCallWasCut)
    }
}
