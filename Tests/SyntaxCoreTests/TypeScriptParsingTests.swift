import Foundation
import Testing
@testable import SyntaxCore

/// TypeScript is the first language whose query is composed from two files, so
/// these tests carry a second job beyond checking colours: several of them fail
/// if the concatenation silently stops happening and the fragment is loaded on
/// its own.
@Suite("TypeScript parsing")
struct TypeScriptParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .typescript, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    /// The canary for the concatenation. Strings, comments and numbers are
    /// captured only by JavaScript's half; the TypeScript fragment has none of
    /// them. If this passes, both files are loaded.
    @Test("JavaScript's half of the query is present")
    func javaScriptHalfIsLoaded() throws {
        let found = try highlight("// note\nconst n = 42; const s = \"hi\";")
        #expect(found.contains { $0 == ("// note", .comment) })
        #expect(found.contains { $0 == ("42", .constant) })
        #expect(found.contains { $0 == ("\"hi\"", .string) })
        #expect(found.contains { $0 == ("const", .keyword) })
    }

    /// And the mirror: the fragment's own captures. If only JavaScript's file
    /// were loaded this would fail, which is the other way the composition can
    /// break.
    @Test("TypeScript's half of the query is present")
    func typeScriptHalfIsLoaded() throws {
        let found = try highlight("interface User { name: string; }")
        #expect(found.contains { $0 == ("interface", .keyword) })
        #expect(found.contains { $0 == ("User", .type) })
        #expect(found.contains { $0 == ("string", .type) })
    }

    @Test("Type annotations and built-in types are types")
    func annotations() throws {
        let found = try highlight("const x: HttpResponse = load(id);")
        #expect(found.contains { $0 == ("HttpResponse", .type) })
        #expect(found.contains { $0 == ("load", .function) })
        // The argument is a plain identifier and stays uncoloured, as in .js.
        #expect(!found.contains { $0.0 == "id" })
    }

    /// A capitalised identifier is captured as `@type` by the fragment and
    /// `@constructor` by JavaScript's half, over the identical range. With
    /// `constructor` unmapped exactly one kind survives, so this is decided by
    /// the grammar rather than by a sort tie-break.
    @Test("A capitalised name resolves to exactly one kind")
    func capitalisedNamesAreTypes() throws {
        let found = try highlight("throw new HttpError(400);")
        #expect(found.filter { $0.0 == "HttpError" }.map(\.1) == [.type])
    }

    @Test("TypeScript-only keywords are keywords")
    func typeScriptKeywords() throws {
        let found = try highlight("export abstract class Repo implements Store { private id = 1; }")
        for word in ["export", "abstract", "class", "implements", "private"] {
            #expect(found.contains { $0 == (word, .keyword) }, "\(word) should be a keyword")
        }
        #expect(found.contains { $0 == ("Repo", .type) })
        #expect(found.contains { $0 == ("Store", .type) })
    }

    /// `type` is the one capture name that means something different in two
    /// grammars: the `px` in CSS's `10px`, and a type name here.
    @Test("The type keyword and a type name are told apart")
    func typeAlias() throws {
        let found = try highlight("type Id = string | number;")
        #expect(found.contains { $0 == ("type", .keyword) })
        #expect(found.contains { $0 == ("Id", .type) })
        #expect(found.contains { $0 == ("number", .type) })
    }

    /// Parameters inherit JavaScript's unmapped `variable`, so they stay plain
    /// while their annotations are coloured.
    @Test("Parameter names stay plain, their types do not")
    func parameters() throws {
        let found = try highlight("function greet(name: string, count?: number) { return 1; }")
        #expect(!found.contains { $0.0 == "name" })
        #expect(!found.contains { $0.0 == "count" })
        #expect(found.filter { $0.1 == .type }.map(\.0) == ["string", "number"])
    }

    @Test("Offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("const flag = \"🎉\";\ninterface Later { id: number; }")
        #expect(found.contains { $0 == ("Later", .type) })
        #expect(found.contains { $0 == ("number", .type) })
    }

    @Test("Malformed input parses without crashing")
    func malformed() throws {
        _ = try highlight("interface {{{")
        _ = try highlight("const x: = ;")
        _ = try highlight("<<>>")
    }

    @Test("An empty document has no tokens")
    func empty() throws {
        #expect(try highlight("").isEmpty)
    }

    @Test("Tokens come out sorted and non-overlapping")
    func tokensAreDisjoint() throws {
        let source = """
        import type { Store } from "./store";
        export interface Item { id: number; label?: string; }
        export class Repo<T extends Item> implements Store {
          private readonly items: T[] = [];
          add(item: T): void { this.items.push(item); }
        }
        """
        let parser = try #require(
            SyntaxParser(language: .typescript, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let tokens = parser.tokens(for: source).tokens
        #expect(!tokens.isEmpty)
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }
}
