import Foundation
import Testing
@testable import SyntaxCore

/// SQL.
///
/// Two things make this language different from the other seven, and most of
/// these tests are about one or the other. Its query is written for Neovim, so
/// its capture names are Neovim's vocabulary and its `#match?` patterns are Lua
/// patterns rather than regular expressions; and its grammar is ANSI and
/// Postgres leaning, so a mysqldump file parses badly.
@Suite("SQL")
struct SQLParsingTests {

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let parser = try #require(
            SyntaxParser(language: .sql, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let text = source as NSString
        return parser.tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    @Test("Keywords, strings and comments")
    func basics() throws {
        let found = try highlight("""
        -- Recent orders.
        SELECT name FROM users WHERE name = 'bob';
        """)
        #expect(found.contains { $0 == ("SELECT", .keyword) })
        #expect(found.contains { $0 == ("FROM", .keyword) })
        #expect(found.contains { $0 == ("WHERE", .keyword) })
        #expect(found.contains { $0 == ("'bob'", .string) })
        #expect(found.contains { $0 == ("-- Recent orders.", .comment) })
    }

    /// The reason `SyntaxParser.icuPattern(from:)` exists. Neovim's `#match?`
    /// takes a Lua pattern, so this query asks for `^[-+]?%d+$`. Read as ICU
    /// that matches a literal per cent sign, so `@number` would never fire --
    /// and because `(literal)` is captured as `@string` as well, every number
    /// in the file would silently colour as a string instead.
    @Test("Numbers are numbers, not strings")
    func numbersBeatStrings() throws {
        let found = try highlight("SELECT 42, 2.5 FROM t WHERE id = 7;")
        #expect(found.contains { $0 == ("42", .constant) })
        #expect(found.contains { $0 == ("7", .constant) })
        #expect(found.contains { $0 == ("2.5", .constant) })
        // ...and a real string is still a string.
        #expect(!found.contains { $0 == ("42", .string) })
    }

    @Test("A quoted literal stays a string")
    func stringsStayStrings() throws {
        let found = try highlight("SELECT 'abc', '42x' FROM t;")
        #expect(found.contains { $0 == ("'abc'", .string) })
        #expect(found.contains { $0 == ("'42x'", .string) })
    }

    @Test("Types, columns and table names")
    func schema() throws {
        let found = try highlight("""
        CREATE TABLE users (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL
        );
        """)
        #expect(found.contains { $0 == ("CREATE", .keyword) })
        #expect(found.contains { $0 == ("TABLE", .keyword) })
        #expect(found.contains { $0 == ("INTEGER", .type) })
        #expect(found.contains { $0 == ("TEXT", .type) })
        #expect(found.contains { $0 == ("users", .type) })
        // A column name in a DEFINITION is captured by nothing, so it stays
        // uncoloured; the query captures `@field` on a reference. Pinned so the
        // asymmetry is known rather than discovered.
        #expect(!found.contains { $0.0 == "id" })
    }

    @Test("A column reference is coloured, unlike a column definition")
    func columnReferences() throws {
        let found = try highlight("SELECT u.id, u.name FROM users u;")
        #expect(found.contains { $0 == ("id", .property) })
        #expect(found.contains { $0 == ("name", .property) })
    }

    @Test("CASE reads as a keyword, not as its own colour")
    func conditionals() throws {
        let found = try highlight("SELECT CASE WHEN a > 1 THEN 'hi' ELSE 'lo' END FROM t;")
        for word in ["CASE", "WHEN", "THEN", "ELSE"] {
            #expect(found.contains { $0 == (word, .keyword) }, "\(word) should be a keyword")
        }
    }

    @Test("Functions and aliases")
    func functionsAndAliases() throws {
        let found = try highlight("SELECT COUNT(*) AS n FROM users u GROUP BY u.id;")
        #expect(found.contains { $0 == ("COUNT", .function) })
        #expect(found.contains { $0 == ("AS", .keyword) })
    }

    /// `@spell` is Neovim's spell-check marker, captured over the same node as
    /// `@comment`. It must stay unmapped, or one range would carry two kinds.
    @Test("A comment carries exactly one token")
    func commentIsNotDoubled() throws {
        let found = try highlight("-- just a comment\nSELECT 1;")
        #expect(found.filter { $0.0 == "-- just a comment" }.count == 1)
    }

    @Test("Tokens stay disjoint and ordered")
    func tokensAreDisjoint() throws {
        let source = """
        SELECT u.id, COUNT(*) AS n, 3.5 AS rate
        FROM users u JOIN orders o ON o.user_id = u.id
        WHERE u.created_at > '2024-01-01' GROUP BY u.id ORDER BY n DESC LIMIT 10;
        """
        let parser = try #require(
            SyntaxParser(language: .sql, queriesRoot: QueryLoadingTests.queriesRoot)
        )
        let tokens = parser.tokens(for: source).tokens
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }

    /// What a mysqldump file does, pinned as KNOWN behaviour rather than
    /// discovered later: the dialect-specific parts do not parse, and what
    /// surrounds them still colours. Measured across 25 real dumps on the
    /// author's machine, 24 contained errors; see Resources/Queries/sql/SOURCE.md.
    @Test("A mysqldump file does not crash, and keeps what it can")
    func mysqldump() throws {
        let found = try highlight("""
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        DROP TABLE IF EXISTS `users`;
        CREATE TABLE `users` (
          `id` int(11) NOT NULL AUTO_INCREMENT,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        INSERT INTO `users` VALUES (1,'bob');
        """)
        #expect(found.contains { $0 == ("CREATE", .keyword) })
        #expect(found.contains { $0 == ("INSERT", .keyword) })
    }

    @Test("Malformed input does not crash")
    func adversarial() throws {
        for source in ["SELECT", "", ";;;", "SELECT * FROM", "'unterminated", "/* unterminated"] {
            _ = try highlight(source)
        }
    }
}
