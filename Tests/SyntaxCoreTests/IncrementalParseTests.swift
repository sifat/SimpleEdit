import Foundation
import Testing
import TreeSitter
@testable import SyntaxCore

/// The contract of incremental parsing, in three parts, each tested here:
///
/// 1. On text that parses without errors, a document parsed through a sequence
///    of reported edits tokenises IDENTICALLY to the same text parsed fresh.
/// 2. On text with syntax errors the two may legitimately differ -- tree-sitter
///    may recover from an error differently when reusing a tree than when
///    starting cold, and both are valid parses of broken text -- but the
///    result is always well-formed: in bounds, sorted, disjoint.
/// 3. Once the error is fixed, the incremental parse agrees with a fresh one
///    again. This is the property a user depends on: what they see after
///    correcting a typo is exactly what they would see reopening the file.
///
/// Every one of the random walks below also runs a THIRD parser given real
/// row/column points, and requires it to agree with the zero-point parser on
/// every edit -- broken text included. That is what lets `noteEdit` pass zeros.
@Suite("Incremental parse")
struct IncrementalParseTests {

    // Fixtures live here rather than on disk: a test that depends on a file
    // outside the repository is a test that passes on one machine.
    private static let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Cart</title>
      <style>
        /* Buttons. */
        :root { --brand: #ff0088; }
        .btn:hover { color: var(--brand); padding: 0 1.5rem; }
        @media (min-width: 48em) { .btn { display: block; } }
      </style>
    </head>
    <body class="page">
      <!-- The cart lives here. -->
      <div id="cart" data-total="0"></div>
      <script>
        // Wire it up.
        const TAX = 0.0825;
        function render(items) {
          const total = items.reduce((sum, it) => sum + it.price, 0);
          document.querySelector("#cart").textContent = `${total * (1 + TAX)}`;
          return true;
        }
      </script>
    </body>
    </html>
    """

    private static let javascript = """
    // Cart totals.
    import { formatMoney } from "./money.js";
    const TAX_RATE = 0.0825;
    export class Cart {
      constructor(items = []) { this.items = items; this.coupon = null; }
      get subtotal() { return this.items.reduce((sum, item) => sum + item.price * item.qty, 0); }
      applyCoupon(code) {
        if (typeof code !== "string" || !/^[A-Z]{4,}$/.test(code)) { throw new Error(`bad coupon: ${code}`); }
        this.coupon = code; return true;
      }
      total() { const taxed = this.subtotal * (1 + TAX_RATE); console.log("total", taxed); return formatMoney(taxed, "USD"); }
    }
    """

    private static let typescript = """
    // Cart totals, typed.
    import type { Money } from "./money";
    export interface CartItem { id: number; label?: string; price: Money; }
    type Coupon = string | null;
    export abstract class BaseCart<T extends CartItem> {
      protected readonly items: T[] = [];
      private coupon: Coupon = null;
      add(item: T): void { this.items.push(item); }
      apply(code: string): boolean {
        if (!/^[A-Z]{4,}$/.test(code)) { throw new RangeError(`bad coupon: ${code}`); }
        this.coupon = code; return true;
      }
      abstract total(): Money;
    }
    """

    private static let css = """
    /* Buttons and layout. */
    @import url("base.css");
    :root { --brand: #ff0088; --gap: 1.5rem; }
    .btn, #main > .card:hover {
      color: var(--brand); display: block; margin: 0 auto calc(var(--gap) * 2);
      border: 1px solid rgba(0, 0, 0, 0.25); content: "click me";
      transition: color 200ms ease-in-out !important;
    }
    input[type="text"]:not(.plain)::placeholder { font-family: "Helvetica Neue", sans-serif; opacity: 0.5; }
    @media screen and (min-width: 48em) { html { font-size: 18px; } }
    """

    private func parser(_ language: SyntaxLanguage) throws -> SyntaxParser {
        try #require(SyntaxParser(language: language, queriesRoot: QueryLoadingTests.queriesRoot))
    }

    /// Deterministic, so a failure is a reproducible seed rather than a rumour.
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    /// Pieces chosen to be maximally disruptive to a tree: every bracket and
    /// quote the grammars care about, both comment forms, astral characters,
    /// both newline styles, and the tags that open and close injections.
    private static let snippets: [String] = [
        "<b>", "</b>", "<div class=\"a\">", "</div>", "<!--", "-->", "<script>", "</script>",
        "<style>", "</style>", "(", ")", "{", "}", "[", "]", "\"", "'", "`", "${", "🎉", "é",
        "\n", "\r\n", " ", ";", "=", "<", ">", "/*", "*/", "//", "@media (", "--x", "#fff",
        "const x = 1;", "function f(a) { return a; }", ".a { color: red; }", "interface I { x: number }",
        "A_B_C", "abc", "1.5em", "!important", "var(--x)", "typeof",
    ]

    /// tree-sitter points: row is the number of newlines before the offset,
    /// column is in BYTES from the start of the line -- UTF-16 units times two.
    private func point(_ text: String, _ unitOffset: Int) -> TSPoint {
        var row: UInt32 = 0, lineStart = 0
        for (i, unit) in text.utf16.enumerated() where i < unitOffset && unit == 0x0A {
            row += 1
            lineStart = i + 1
        }
        return TSPoint(row: row, column: UInt32((unitOffset - lineStart) * 2))
    }

    private struct Edit {
        let edit: SyntaxParser.TextEdit
        let start: TSPoint, oldEnd: TSPoint, newEnd: TSPoint
        /// What the edit removed, so it can be undone exactly.
        let removed: String
        let inserted: String
    }

    /// Replaces `[start, oldEnd)` in UTF-16 units with `replacement` and
    /// describes the edit with real points.
    private func replace(
        _ text: inout String, start: Int, oldEnd: Int, with replacement: String
    ) -> Edit {
        let u16 = text.utf16
        let lower = u16.index(u16.startIndex, offsetBy: start)
        let upper = u16.index(u16.startIndex, offsetBy: oldEnd)
        let removed = String(text[lower..<upper])
        let startPoint = point(text, start), oldEndPoint = point(text, oldEnd)
        text.replaceSubrange(lower..<upper, with: replacement)
        let newEnd = start + replacement.utf16.count
        return Edit(
            edit: SyntaxParser.TextEdit(start: start, oldEnd: oldEnd, newEnd: newEnd),
            start: startPoint, oldEnd: oldEndPoint, newEnd: point(text, newEnd),
            removed: removed, inserted: replacement
        )
    }

    /// One random edit on Character boundaries -- the only kind a text view
    /// can make.
    private func mutate(_ text: inout String, using rng: inout Random) -> Edit {
        let count = text.count
        let a = rng.below(count + 1)
        let span = rng.below(min(8, count - a + 1))
        let lower = text.index(text.startIndex, offsetBy: a)
        let upper = text.index(lower, offsetBy: span)
        let start = text.utf16.distance(from: text.utf16.startIndex, to: lower)
        let oldEnd = text.utf16.distance(from: text.utf16.startIndex, to: upper)
        let replacement = rng.below(4) == 0 ? "" : Self.snippets[rng.below(Self.snippets.count)]
        return replace(&text, start: start, oldEnd: oldEnd, with: replacement)
    }

    /// The exact inverse of `edit`: puts back what it removed.
    private func undo(_ edit: Edit, in text: inout String) -> Edit {
        replace(&text, start: edit.edit.start, oldEnd: edit.edit.newEnd, with: edit.removed)
    }

    private func isWellFormed(_ list: SyntaxTokenList, in text: String) -> Bool {
        let length = (text as NSString).length
        var end = 0
        for token in list.tokens {
            guard token.range.location >= end, NSMaxRange(token.range) <= length else { return false }
            end = NSMaxRange(token.range)
        }
        return true
    }

    private func runDifferential(
        _ language: SyntaxLanguage, seed: UInt64, initial: String, edits: Int,
        cancelEvery: Int = 0
    ) throws {
        let incremental = try parser(language)
        let withPoints = try parser(language)
        let fresh = try parser(language)
        var text = initial
        var rng = Random(state: seed)
        _ = incremental.tokens(for: text)
        _ = withPoints.tokens(for: text)
        var cleanChecks = 0
        // A random walk that only ever inserts brackets and quotes almost
        // never returns to clean text on its own, so it moves in bursts: a
        // few random edits, then every one of them undone in reverse, which
        // lands exactly back on the clean text it started from. Identity with
        // a fresh parse is required at every clean state on the way, and each
        // unwind is a break-then-fix, so convergence is exercised continuously.
        var history: [Edit] = []
        var burstRemaining = 0

        for i in 1...edits {
            let e: Edit
            if burstRemaining == 0, !history.isEmpty {
                e = undo(history.removeLast(), in: &text)
            } else {
                if burstRemaining == 0 { burstRemaining = 3 + rng.below(6) }
                burstRemaining -= 1
                e = mutate(&text, using: &rng)
                history.append(e)
            }
            incremental.noteEdit(e.edit)
            withPoints.noteEdit(e.edit, start: e.start, oldEnd: e.oldEnd, newEnd: e.newEnd)
            if cancelEvery > 0, i % cancelEvery == 0 {
                // Force a cancellation, then require the NEXT parse to recover.
                _ = incremental.tokens(for: text, budget: 0)
                _ = withPoints.tokens(for: text, budget: 0)
                continue
            }
            let got = incremental.tokens(for: text)
            let pointed = withPoints.tokens(for: text)
            let want = fresh.tokens(for: text)

            // Points never change the outcome, errors or not.
            #expect(got == pointed, "seed \(seed) edit \(i): real points changed the tokens")
            // Always well-formed.
            #expect(isWellFormed(got, in: text), "seed \(seed) edit \(i): malformed token list")
            // Identical to fresh whenever the text is clean.
            if !fresh.hasSyntaxErrors {
                cleanChecks += 1
                #expect(
                    got == want,
                    "seed \(seed) edit \(i) \(e.edit): clean text, incremental produced \(got.count) tokens, fresh \(want.count)"
                )
                if got != want { return }
            }
        }
        // A walk that never landed on clean text would prove nothing.
        #expect(cleanChecks >= 8, "seed \(seed): only \(cleanChecks) clean states were checked")
    }

    @Test("HTML with injections survives random edits", arguments: [1, 2, 3, 4, 5] as [UInt64])
    func html(seed: UInt64) throws {
        try runDifferential(.html, seed: seed, initial: Self.html, edits: 150)
    }

    @Test("JavaScript survives random edits", arguments: [11, 12, 13, 14, 15] as [UInt64])
    func javascript(seed: UInt64) throws {
        try runDifferential(.javascript, seed: seed, initial: Self.javascript, edits: 150)
    }

    @Test("TypeScript survives random edits", arguments: [21, 22, 23] as [UInt64])
    func typescript(seed: UInt64) throws {
        try runDifferential(.typescript, seed: seed, initial: Self.typescript, edits: 150)
    }

    @Test("CSS survives random edits", arguments: [31, 32, 33] as [UInt64])
    func css(seed: UInt64) throws {
        try runDifferential(.css, seed: seed, initial: Self.css, edits: 150)
    }

    /// A cancelled parse keeps the edited tree, and the edits reported after
    /// the cancellation are applied on top. The next successful parse must
    /// still be exact.
    @Test("Edits across a cancelled parse accumulate correctly", arguments: [41, 42, 43] as [UInt64])
    func acrossCancellation(seed: UInt64) throws {
        try runDifferential(.html, seed: seed, initial: Self.html, edits: 120, cancelEvery: 7)
    }

    /// Starting from nothing and growing a document one edit at a time is the
    /// shape of actually typing one.
    @Test("A document typed from empty matches a fresh parse", arguments: [51, 52] as [UInt64])
    func fromEmpty(seed: UInt64) throws {
        try runDifferential(.html, seed: seed, initial: "", edits: 200)
    }

    /// A large document, edited at random places: the fixtures above
    /// concatenated until they are the size of a real file.
    @Test("A large document survives random edits", arguments: [61, 62] as [UInt64])
    func largeDocument(seed: UInt64) throws {
        let initial = String(repeating: Self.css + "\n", count: 40)
        try runDifferential(.css, seed: seed, initial: initial, edits: 60)
    }

    /// Property 3, directly. Break the document, parse it broken -- where the
    /// incremental and fresh parses are allowed to disagree -- then undo the
    /// break and require them to agree again. Several kinds of break, because
    /// each exercises a different recovery path in the grammar.
    @Test("Fixing an error converges on the fresh parse", arguments: [
        ("(", 40), ("<!--", 100), ("`", 200), ("\"", 300), ("{", 500), ("</script>", 620),
    ] as [(String, Int)])
    func convergence(snippet: String, at offset: Int) throws {
        for language in [SyntaxLanguage.html, .javascript] {
            let original = language == .html ? Self.html : Self.javascript
            let ns = original as NSString
            let at = min(offset, ns.length)
            let p = try parser(language)
            let fresh = try parser(language)
            _ = p.tokens(for: original)

            let broken = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: snippet)
            p.noteEdit(SyntaxParser.TextEdit(start: at, oldEnd: at, newEnd: at + snippet.utf16.count))
            #expect(isWellFormed(p.tokens(for: broken), in: broken))

            p.noteEdit(SyntaxParser.TextEdit(start: at, oldEnd: at + snippet.utf16.count, newEnd: at))
            #expect(
                p.tokens(for: original) == fresh.tokens(for: original),
                "\(language.rawValue): after inserting and removing \(snippet) at \(at), the parses disagree"
            )
        }
    }

    /// The footgun the differential test found in its own reference parser:
    /// two texts of the SAME length, no edit reported. A parser that reused
    /// its tree on length alone tokenised `<!--` as a tag, because the tree
    /// still described the `<met` that used to be there. Reuse requires a
    /// reported edit, so `tokens(for:)` stays a pure function for any caller
    /// that never calls `noteEdit`.
    @Test("An unreported same-length change is still parsed correctly")
    func unreportedSameLengthChange() throws {
        let p = try parser(.html)
        let fresh = try parser(.html)
        _ = p.tokens(for: "<meta charset=\"utf-8\"> --> <p>x</p>")
        let changed = "<!--a charset=\"utf-8\"> --> <p>x</p>"   // same length, no noteEdit
        let got = p.tokens(for: changed)
        #expect(got == fresh.tokens(for: changed))
        // The stale tree would have said "tag"; the text says "comment".
        #expect(got.tokens.first?.kind == .comment)
        #expect(!got.tokens.contains { $0.kind == .tag && $0.range.location < 5 })
    }

    /// Reuse must not survive a successful parse: the next call without a
    /// reported edit is a full parse even though the tree is present and the
    /// length matches.
    @Test("After a successful parse, reuse needs a fresh edit report")
    func reuseIsArmedByEdits() throws {
        let p = try parser(.javascript)
        let fresh = try parser(.javascript)
        var text = "const a = 1;"
        _ = p.tokens(for: text)
        p.noteEdit(SyntaxParser.TextEdit(start: 6, oldEnd: 7, newEnd: 7)); text = "const b = 1;"
        #expect(p.tokens(for: text) == fresh.tokens(for: text))
        // Same length again, this time unreported.
        text = "const c = 2;"
        #expect(p.tokens(for: text) == fresh.tokens(for: text))
    }

    /// The guard against an unreported edit. If the text changed length and
    /// nobody said so, the tree is discarded and the parse starts fresh.
    @Test("An unreported edit that changes length falls back to a full parse")
    func unreportedEditIsCaught() throws {
        let p = try parser(.html)
        let fresh = try parser(.html)
        _ = p.tokens(for: "<p class=\"a\">one</p>")
        let changed = "<p class=\"a\">one</p><b>two</b>"
        // No noteEdit on purpose.
        #expect(p.tokens(for: changed) == fresh.tokens(for: changed))
    }

    /// A nonsensical edit -- one that cannot describe the tree's text -- must
    /// not be applied. It discards the tree instead.
    @Test("An impossible edit discards the tree rather than corrupting it")
    func impossibleEdit() throws {
        let p = try parser(.javascript)
        let fresh = try parser(.javascript)
        _ = p.tokens(for: "const a = 1;")
        p.noteEdit(SyntaxParser.TextEdit(start: 5, oldEnd: 4, newEnd: 9))       // start > oldEnd
        p.noteEdit(SyntaxParser.TextEdit(start: 0, oldEnd: 500, newEnd: 500))   // beyond the text
        let next = "const b = 2;"
        #expect(p.tokens(for: next) == fresh.tokens(for: next))
    }

    /// Edits reported to a parser that has no tree are simply ignored.
    @Test("Edits before any parse are harmless")
    func editsBeforeParse() throws {
        let p = try parser(.css)
        p.noteEdit(SyntaxParser.TextEdit(start: 0, oldEnd: 0, newEnd: 3))
        p.invalidate()
        #expect(!p.tokens(for: ".a { color: red; }").isEmpty)
    }

    /// Astral characters are two UTF-16 units and the edit is expressed in
    /// units, so an edit after an emoji lands two units later than a Character
    /// count would put it.
    @Test("Edits after astral characters are positioned in UTF-16 units")
    func astralEdit() throws {
        let p = try parser(.javascript)
        let fresh = try parser(.javascript)
        var text = "const s = \"🎉🎉\"; let a = 1;"
        _ = p.tokens(for: text)
        // Replace `a` with `bb`: locate in UTF-16 units, not Characters.
        let ns = text as NSString
        let r = ns.range(of: "a = 1")
        text = ns.replacingCharacters(in: NSRange(location: r.location, length: 1), with: "bb")
        p.noteEdit(SyntaxParser.TextEdit(start: r.location, oldEnd: r.location + 1, newEnd: r.location + 2))
        #expect(p.tokens(for: text) == fresh.tokens(for: text))
    }
}
