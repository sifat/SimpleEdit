import Foundation
import Testing
@testable import SyntaxCore

/// Asserts on the *text* each token covers rather than raw offsets: an
/// off-by-one then reads as a visibly wrong word instead of a number nobody can
/// check by eye.
@Suite("Java parsing")
struct JavaParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .java, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source, budget: 30).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("Keywords, comments, numbers and strings")
    func basics() throws {
        let found = try highlight("package app;\n// note\nclass A { double d = 0.5; String s = \"hi\"; char c = 'x'; }")
        #expect(found.contains { $0 == ("package", .keyword) })
        #expect(found.contains { $0 == ("class", .keyword) })
        #expect(found.contains { $0 == ("// note", .comment) })
        #expect(found.contains { $0 == ("0.5", .constant) })
        #expect(found.contains { $0 == ("\"hi\"", .string) })
        #expect(found.contains { $0 == ("'x'", .string) })
    }

    /// The reason for the Java-only `function.method` row. The shared table
    /// maps it to `.property` because JavaScript always co-captures it with
    /// `@property`; Java's query has no `@property`, so without the override
    /// every method name in a Java file would be blue.
    @Test("Method declarations and calls are functions, not properties")
    func methods() throws {
        let found = try highlight("class A { int total(int q) { return items.size() + q; } }")
        #expect(found.filter { $0.0 == "total" }.map(\.1) == [.function])
        #expect(found.filter { $0.0 == "size" }.map(\.1) == [.function])
    }

    /// Unlike JavaScript and Python, Java colours class names -- the grammar
    /// knows them from position, as `type_identifier` and declaration names,
    /// not from a capitalisation guess.
    @Test("Class names, generics and primitive types are types")
    func types() throws {
        let found = try highlight("class Cart<T> extends Base implements Store { List<String> items; int n; void run() {} }")
        for name in ["Cart", "T", "Base", "Store", "List", "String", "int", "void"] {
            #expect(found.contains { $0 == (name, .type) }, "\(name)")
        }
    }

    @Test("A capitalised object of a call or field access is a type")
    func staticAccess() throws {
        let found = try highlight("class A { void f() { System.out.println(1); Math.max(1, 2); } }")
        #expect(found.contains { $0 == ("System", .type) })
        #expect(found.contains { $0 == ("Math", .type) })
        #expect(found.contains { $0 == ("println", .function) })
        #expect(!found.contains { $0.0 == "out" })
    }

    /// `this` and `super` are keywords in Java. Upstream captures them as a
    /// builtin variable and a builtin function, which the shared table would
    /// leave plain and indigo respectively.
    @Test("this and super are keywords")
    func thisAndSuper() throws {
        let found = try highlight("class A extends B { int f() { return this.x + super.hashCode(); } }")
        #expect(found.contains { $0 == ("this", .keyword) })
        #expect(found.contains { $0 == ("super", .keyword) })
        #expect(found.contains { $0 == ("hashCode", .function) })
    }

    @Test("An annotation's name is an attribute and its @ is punctuation")
    func annotations() throws {
        let found = try highlight("class A { @Override public String toString() { return \"\"; } }")
        #expect(found.contains { $0 == ("Override", .attribute) })
        #expect(found.contains { $0 == ("@", .punctuation) })
    }

    @Test("ALL_CAPS names, booleans and null are constants")
    func constants() throws {
        let found = try highlight("class A { static final int MAX_SIZE = 10; boolean ok = true; Object o = null; }")
        #expect(found.contains { $0 == ("MAX_SIZE", .constant) })
        #expect(found.contains { $0 == ("true", .constant) })
        #expect(found.contains { $0 == ("null", .constant) })
    }

    /// Java's all-caps rule needs two or more characters, so a single-letter
    /// generic never collides with it the way Python's does -- and it is a
    /// type node regardless.
    @Test("A single-letter type parameter is a type")
    func typeParameter() throws {
        let found = try highlight("class Box<T> { T value; T get() { return value; } }")
        #expect(found.filter { $0.0 == "T" }.allSatisfy { $0.1 == .type })
        #expect(found.filter { $0.0 == "T" }.count == 3)
    }

    @Test("Local and parameter names are uncoloured")
    func plainNames() throws {
        let found = try highlight("class A { int f(int count) { int total = count; return total; } }")
        #expect(!found.contains { $0.0 == "count" })
        #expect(!found.contains { $0.0 == "total" })
    }

    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("class A { String s = \"🎉\"; int later() { return 2; } }")
        #expect(found.contains { $0 == ("\"🎉\"", .string) })
        #expect(found.contains { $0 == ("later", .function) })
        #expect(found.contains { $0 == ("2", .constant) })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("class {{{")
        _ = try highlight("public static void main(String[] args")
        _ = try highlight("\"unterminated")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }

    @Test("Tokens come out sorted and non-overlapping")
    func tokensAreDisjoint() throws {
        let source = """
        package com.sifat.cart;

        import java.util.*;

        /** A cart. */
        public final class Cart<T extends Item> implements Iterable<T> {
            private static final double TAX_RATE = 0.0825;
            private final List<T> items = new ArrayList<>();

            @Override
            public Iterator<T> iterator() { return items.iterator(); }

            public double total() {
                return items.stream().mapToDouble(i -> i.price() * (1 + TAX_RATE)).sum();
            }
        }
        """
        let parser = try #require(SyntaxParser(language: .java, queriesRoot: QueryLoadingTests.queriesRoot))
        let tokens = parser.tokens(for: source, budget: 30).tokens
        #expect(!tokens.isEmpty)
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }
}
