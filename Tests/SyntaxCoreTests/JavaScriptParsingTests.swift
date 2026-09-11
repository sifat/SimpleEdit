import Foundation
import Testing
@testable import SyntaxCore

/// Asserts on the *text* each token covers rather than raw offsets: an
/// off-by-one then reads as a visibly wrong word instead of a number nobody can
/// check by eye.
@Suite("JavaScript parsing")
struct JavaScriptParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .javascript, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("Keywords, numbers and comments")
    func basics() throws {
        let found = try highlight("const x = 1; // note")
        #expect(found.contains { $0 == ("const", .keyword) })
        #expect(found.contains { $0 == ("1", .constant) })
        #expect(found.contains { $0 == ("// note", .comment) })
    }

    /// Pins the decision that makes JavaScript readable at all. The grammar
    /// captures every identifier as `@variable`; colouring that paints roughly a
    /// fifth of the file, and collides with `@function` on every called name.
    /// Unmapped, identifiers render like HTML body text and CSS plain values.
    @Test("Plain identifiers are not coloured")
    func identifiersStayPlain() throws {
        let found = try highlight("const total = subtotal + taxRate;")
        for name in ["total", "subtotal", "taxRate"] {
            #expect(!found.contains { $0.0 == name }, "\(name) should not be coloured")
        }
        #expect(found.contains { $0 == ("const", .keyword) })
    }

    /// `@function.method` and `@property` fire over the identical range here, so
    /// they are mapped to the same kind. If they ever disagree the winner would
    /// come from a sort tie-break rather than from a decision.
    @Test("A called method is a property, and the object is plain")
    func methodCall() throws {
        let found = try highlight("obj.doThing();")
        #expect(found.filter { $0.0 == "doThing" }.map(\.1) == [.property])
        #expect(!found.contains { $0.0 == "obj" })
    }

    @Test("A declared function keeps the function colour")
    func functionDeclaration() throws {
        let found = try highlight("function greet(name) { return 1; }")
        #expect(found.contains { $0 == ("greet", .function) })
        #expect(found.contains { $0 == ("return", .keyword) })
    }

    /// SCREAMING_CAPS is captured as both `@constant` and `@constructor` (the
    /// latter is just `^[A-Z]`). With `@constructor` unmapped, exactly one kind
    /// survives, so this is decided by the grammar rather than by the sort.
    @Test("A SCREAMING_CAPS name is a constant, unambiguously")
    func screamingCaps() throws {
        let found = try highlight("MAX_SIZE;")
        #expect(found.filter { $0.0 == "MAX_SIZE" }.map(\.1) == [.constant])
    }

    /// The cost of dropping `@constructor`, pinned so it is a known trade rather
    /// than a surprise: capitalised names carry no colour of their own.
    @Test("Class names and new targets are deliberately uncoloured")
    func capitalisedNamesArePlain() throws {
        let found = try highlight("class Foo extends Bar {}\nnew Thing();")
        for name in ["Foo", "Bar", "Thing"] {
            #expect(!found.contains { $0.0 == name })
        }
        #expect(found.contains { $0 == ("class", .keyword) })
        #expect(found.contains { $0 == ("new", .keyword) })
    }

    /// `@string` covers the whole template including its substitutions, and
    /// overlaps resolve outermost-first, so the interpolation is not separately
    /// coloured. Pinned because it looks like a missing feature and is actually
    /// a consequence of the merge rule.
    @Test("A template literal is one string, substitutions included")
    func templateLiteral() throws {
        let found = try highlight("const s = `hi ${name.first}!`;")
        #expect(found.filter { $0.1 == .string }.map(\.0) == ["`hi ${name.first}!`"])
        #expect(!found.contains { $0.0 == "first" })
    }

    @Test("A regex literal is a string")
    func regexLiteral() throws {
        let found = try highlight("const re = /ab+c/g;")
        #expect(found.contains { $0 == ("/ab+c/g", .string) })
    }

    /// The bug class this project has been bitten by twice. An emoji is one
    /// Character but two UTF-16 units; counting Characters anywhere in the
    /// pipeline would land every later token two units early.
    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("const flag = \"🎉\";\nfunction later() { return 2; }")
        #expect(found.contains { $0 == ("later", .function) })
        #expect(found.contains { $0 == ("\"🎉\"", .string) })
        #expect(found.contains { $0 == ("2", .constant) })
    }

    /// The grammar's `#match?` and `#eq?` predicates have to be evaluated for
    /// these to be distinguishable from ordinary identifiers at all.
    @Test("Builtin functions and constants are recognised")
    func builtins() throws {
        let found = try highlight("const ok = true; const missing = undefined;")
        #expect(found.contains { $0 == ("true", .constant) })
        #expect(found.contains { $0 == ("undefined", .constant) })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("function (((")
        _ = try highlight("const = = =;")
        _ = try highlight("}{)(")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }

    /// The invariant every consumer relies on: the validator binary-searches
    /// this list and clips against a fragment, which is only correct if the
    /// tokens are sorted and disjoint.
    @Test("Tokens come out sorted and non-overlapping")
    func tokensAreDisjoint() throws {
        let source = """
        // header
        import { thing } from "./mod.js";
        export default class Widget extends Base {
          constructor(options = {}) {
            super(options);
            this.items = [1, 2.5, 0x1f].map((n) => `v${n}`);
          }
          get size() { return this.items.length; }
        }
        """
        let parser = try #require(
            SyntaxParser(language: .javascript, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let tokens = parser.tokens(for: source).tokens
        #expect(!tokens.isEmpty)
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }
}
