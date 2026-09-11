import Foundation
import Testing
@testable import SyntaxCore

/// Asserts on the *text* each token covers rather than raw offsets: an
/// off-by-one then reads as a visibly wrong word instead of a number nobody can
/// check by eye.
@Suite("Python parsing")
struct PythonParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .python, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source, budget: 30).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("Keywords, comments and numbers")
    func basics() throws {
        let found = try highlight("import os\n# note\nvalue = 3.14\nreturn")
        #expect(found.contains { $0 == ("import", .keyword) })
        #expect(found.contains { $0 == ("# note", .comment) })
        #expect(found.contains { $0 == ("3.14", .constant) })
    }

    /// Python's external scanner is what turns indentation into blocks. If it
    /// were missing -- the hazard the version pin avoids -- a def body would not
    /// parse and nothing after the first indented line would be recognised.
    @Test("Indented blocks parse, so the external scanner is present")
    func indentation() throws {
        let found = try highlight("def outer():\n    def inner():\n        return 1\n    return inner")
        #expect(found.filter { $0.0 == "def" }.count == 2)
        #expect(found.filter { $0.0 == "return" }.count == 2)
        #expect(found.contains { $0 == ("inner", .function) })
    }

    @Test("Definitions and calls are functions, builtins included")
    func functions() throws {
        let found = try highlight("def total(items):\n    return len(items) + compute(items)")
        #expect(found.contains { $0 == ("total", .function) })
        #expect(found.contains { $0 == ("len", .function) })
        #expect(found.contains { $0 == ("compute", .function) })
    }

    /// `@function.method` is co-captured with `@property` over the same range,
    /// and the shared table maps both to `.property`, so they agree.
    @Test("A method call is a property, and the object is plain")
    func methodCall() throws {
        let found = try highlight("obj.method()\nobj.attr")
        #expect(found.filter { $0.0 == "method" }.map(\.1) == [.property])
        #expect(found.contains { $0 == ("attr", .property) })
        #expect(!found.contains { $0.0 == "obj" })
    }

    @Test("A decorator is a function, as one token including the @")
    func decorator() throws {
        let found = try highlight("@dataclass\nclass Point:\n    pass")
        #expect(found.contains { $0 == ("@dataclass", .function) })
    }

    @Test("True, False and None are constants")
    func literals() throws {
        let found = try highlight("a = True\nb = False\nc = None")
        for word in ["True", "False", "None"] {
            #expect(found.contains { $0 == (word, .constant) }, "\(word)")
        }
    }

    /// The same trade JavaScript makes, pinned so it stays a known one: the
    /// grammar's only capture on a class name is the `^[A-Z]` naming guess,
    /// which collides with too much to colour.
    @Test("Plain identifiers and class names are deliberately uncoloured")
    func plainNames() throws {
        let found = try highlight("class Point:\n    pass\ncount = Point()")
        #expect(!found.contains { $0.0 == "count" })
        #expect(!found.contains { $0.0 == "Point" && $0.1 != .function })
    }

    @Test("An ALL_CAPS name is a constant")
    func screamingCaps() throws {
        let found = try highlight("MAX_SIZE = 10")
        #expect(found.filter { $0.0 == "MAX_SIZE" }.map(\.1) == [.constant])
    }

    /// The collision that forced a designed tie-break. `T` matches both the
    /// annotation pattern and the all-caps pattern, over the identical range,
    /// and the winner used to be whatever an unstable sort left first. The
    /// annotation is better evidence than a naming convention, so it is a type.
    @Test("A single-letter type variable in an annotation is a type, not a constant")
    func typeVariable() throws {
        let found = try highlight("def f(x: T) -> T:\n    return x")
        #expect(found.filter { $0.0 == "T" }.map(\.1) == [.type, .type])
    }

    @Test("Annotation names are types")
    func annotations() throws {
        let found = try highlight("def f(x: int, y: str) -> bool:\n    pass")
        #expect(found.filter { $0.1 == .type }.map(\.0) == ["int", "str", "bool"])
    }

    /// `(string)` covers the whole literal, and overlaps resolve outermost
    /// first, so an f-string's interpolation and escape sequences are inside
    /// the string token rather than separate ones.
    @Test("An f-string is one string, interpolation and escapes included")
    func fString() throws {
        let found = try highlight("name = f\"hi {user.name}!\\n\"")
        #expect(found.filter { $0.1 == .string }.map(\.0) == ["f\"hi {user.name}!\\n\""])
        #expect(!found.contains { $0.0 == "name" && $0.1 == .property })
    }

    /// Upstream captures word operators as `@operator`, and this app colours
    /// operators as punctuation. Pinned because `and` in grey looks like an
    /// oversight and is a consequence of the query.
    @Test("Word operators colour as punctuation, like symbolic ones")
    func wordOperators() throws {
        let found = try highlight("ok = a and not b or c in d")
        for word in ["and", "not", "or", "in"] {
            #expect(found.contains { $0 == (word, .punctuation) }, "\(word)")
        }
    }

    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("flag = \"🎉\"\ndef later():\n    return 2")
        #expect(found.contains { $0 == ("\"🎉\"", .string) })
        #expect(found.contains { $0 == ("later", .function) })
        #expect(found.contains { $0 == ("2", .constant) })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("def (((")
        _ = try highlight("    unexpected indent\nclass")
        _ = try highlight("f\"{{{")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }

    @Test("Tokens come out sorted and non-overlapping")
    func tokensAreDisjoint() throws {
        let source = """
        from typing import Generic, TypeVar
        T = TypeVar("T")

        @dataclass(frozen=True)
        class Box(Generic[T]):
            value: T
            def map(self, fn: Callable[[T], U]) -> "Box[U]":
                return Box(fn(self.value)) if self.value is not None else self
        """
        let parser = try #require(SyntaxParser(language: .python, queriesRoot: QueryLoadingTests.queriesRoot))
        let tokens = parser.tokens(for: source, budget: 30).tokens
        #expect(!tokens.isEmpty)
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }
}
