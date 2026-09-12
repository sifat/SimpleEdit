import Foundation
import Testing
@testable import SyntaxCore

/// PHP, and the HTML that surrounds it.
///
/// A `.php` file is two documents interleaved: PHP between `<?php` and `?>`,
/// and HTML everywhere else. The HTML is a COMBINED injection -- one document
/// with holes in it rather than a series of fragments -- which is the only
/// place in this app where a child parser reads the whole buffer through
/// tree-sitter's included ranges. Most of these tests are about that.
@Suite("PHP")
struct PHPParsingTests {

    private func parser() throws -> SyntaxParser {
        try #require(SyntaxParser(language: .php, queriesRoot: QueryLoadingTests.queriesRoot))
    }

    private func highlight(_ source: String) throws -> [(String, SyntaxTokenKind)] {
        let text = source as NSString
        return try parser().tokens(for: source).tokens.map {
            (text.substring(with: $0.range), $0.kind)
        }
    }

    // MARK: - The language itself

    @Test("Keywords, strings, comments and numbers")
    func basics() throws {
        let found = try highlight("""
        <?php
        // a comment
        function greet(string $name): string {
            return "hello " . $name . 42;
        }
        """)
        #expect(found.contains { $0 == ("<?php", .tag) })
        #expect(found.contains { $0 == ("function", .keyword) })
        #expect(found.contains { $0 == ("return", .keyword) })
        #expect(found.contains { $0 == ("// a comment", .comment) })
        #expect(found.contains { $0 == ("42", .constant) })
        #expect(found.contains { $0.1 == .string && $0.0.contains("hello") })
        #expect(found.contains { $0 == ("greet", .function) })
    }

    /// `@variable` in PHP is not the blanket identifier capture it is in
    /// JavaScript and Python: the grammar captures exactly `$name`, sigil
    /// included, so unlike those languages it is coloured.
    @Test("Variables are coloured, sigil included")
    func variables() throws {
        let found = try highlight("<?php $total = $price * 2;")
        #expect(found.contains { $0 == ("$total", .property) })
        #expect(found.contains { $0 == ("$price", .property) })
        // The `$` is captured separately as an operator and sits inside the
        // variable that covers it, so outermost-wins must drop it.
        #expect(!found.contains { $0 == ("$", .punctuation) })
    }

    /// `$this` is captured twice: as `@variable` over the whole `$this`, and as
    /// `@variable.builtin` over the bare `this` inside it. Outermost wins, so
    /// what shows is the variable -- the builtin row can never be seen here.
    /// Where it IS seen is `self::`, `static::` and `parent::`, which are whole
    /// nodes of their own.
    @Test("$this is a variable; the scope keywords are keywords")
    func builtinVariables() throws {
        let found = try highlight("<?php class A { function f() { return $this->x; } }")
        #expect(found.contains { $0 == ("$this", .property) })
        #expect(found.contains { $0 == ("x", .property) })
        #expect(!found.contains { $0 == ("this", .keyword) })

        let scopes = try highlight("<?php echo self::MAX; static::go(); parent::init();")
        #expect(scopes.contains { $0 == ("self", .keyword) })
        #expect(scopes.contains { $0 == ("static", .keyword) })
        #expect(scopes.contains { $0 == ("parent", .keyword) })
        #expect(scopes.contains { $0 == ("MAX", .constant) })
        #expect(scopes.contains { $0 == ("go", .function) })
    }

    @Test("Types, constructors and namespaces read as types")
    func typesAndNamespaces() throws {
        let found = try highlight("""
        <?php
        namespace App\\Http;
        use App\\Models\\User;
        $u = new User();
        """)
        #expect(found.contains { $0 == ("App", .type) })
        #expect(found.contains { $0 == ("User", .type) })
        #expect(found.contains { $0 == ("namespace", .keyword) })
    }

    @Test("Constants and builtins")
    func constants() throws {
        let found = try highlight("<?php const MAX_SIZE = 10; $ok = true; $none = null;")
        #expect(found.contains { $0 == ("MAX_SIZE", .constant) })
        #expect(found.contains { $0 == ("true", .constant) })
        #expect(found.contains { $0 == ("null", .constant) })
    }

    /// An enum with a constant in it. This is the single construct that the
    /// newest ABI 14 grammar cannot parse, and the reason the pin is v0.24.2 --
    /// see `Resources/Queries/php/SOURCE.md`. If a later bump moves back to an
    /// ABI 14 tag, this fails rather than silently un-colouring such files.
    @Test("An enum that declares a constant parses cleanly")
    func enumWithConstant() throws {
        let parser = try parser()
        let found = parser.tokens(for: """
        <?php
        enum Suit: string {
            case Hearts = 'H';
            const Wild = self::Hearts;
        }
        """)
        #expect(!parser.hasSyntaxErrors)
        #expect(found.tokens.contains { $0.kind == .keyword })
    }

    // MARK: - The HTML around it

    @Test("Text outside the PHP tags is highlighted as HTML")
    func htmlAroundPHP() throws {
        let found = try highlight("<div class=\"card\"><?php echo $x; ?></div>")
        #expect(found.contains { $0 == ("div", .tag) })
        #expect(found.contains { $0 == ("class", .attribute) })
        #expect(found.contains { $0 == ("card", .string) })
        #expect(found.contains { $0 == ("echo", .keyword) })
        #expect(found.contains { $0 == ("$x", .property) })
    }

    /// The point of a COMBINED injection. The `<div>` opens in one HTML
    /// fragment and closes in another, three PHP blocks later; parsed
    /// fragment-by-fragment it would be an unclosed tag followed by a stray
    /// closing one.
    @Test("An element split across PHP blocks is still one element")
    func elementSplitAcrossBlocks() throws {
        let source = """
        <?php if ($a) { ?>
          <div class="on">
        <?php } else { ?>
          <div class="off">
        <?php } ?>
          <p>body</p>
        </div>
        """
        let parser = try parser()
        let text = source as NSString
        let tokens = parser.tokens(for: source).tokens
        let words = tokens.map { text.substring(with: $0.range) }
        #expect(words.filter { $0 == "div" }.count == 3)
        #expect(words.contains("p"))
        #expect(words.contains("else"))
    }

    /// A hole in the middle of an attribute value. HTML sees one node spanning
    /// the whole `"..."`, PHP sees the echo inside it, and outermost-wins would
    /// let the HTML node swallow the PHP if the child's tokens were not cut
    /// back to its own ranges.
    @Test("PHP inside an attribute value is not swallowed by the HTML node")
    func phpInsideAttributeValue() throws {
        let found = try highlight("<a href=\"<?php echo $url; ?>\">x</a>")
        #expect(found.contains { $0 == ("echo", .keyword) })
        #expect(found.contains { $0 == ("$url", .property) })
        #expect(found.contains { $0 == ("a", .tag) })
        #expect(found.contains { $0 == ("href", .attribute) })
    }

    /// Depth two: PHP, then its HTML, then that HTML's `<script>` and
    /// `<style>`. Nothing else in the app nests this far.
    @Test("Script and style inside a PHP template are highlighted")
    func nestedScriptAndStyle() throws {
        let found = try highlight("""
        <?php $title = 'x'; ?>
        <style>.btn { color: red; }</style>
        <script>const n = 42;</script>
        """)
        #expect(found.contains { $0 == ("color", .property) })
        #expect(found.contains { $0 == ("const", .keyword) })
        #expect(found.contains { $0 == ("42", .constant) })
        #expect(found.contains { $0 == ("$title", .property) })
    }

    @Test("Injected offsets survive astral characters")
    func astralCharacters() throws {
        let found = try highlight("<p>🎉</p><?php $flag = \"🎉\"; $after = 7; ?><b>x</b>")
        #expect(found.contains { $0 == ("$flag", .property) })
        #expect(found.contains { $0 == ("7", .constant) })
        #expect(found.contains { $0 == ("b", .tag) })
    }

    /// The merge rule is outermost-wins, which only works if the final list is
    /// disjoint -- across all three languages at once.
    @Test("Tokens from every level stay disjoint and ordered")
    func tokensAreDisjoint() throws {
        let source = """
        <?php foreach ($rows as $row) { ?>
          <li class="<?php echo $row['cls']; ?>"><?= $row['name'] ?></li>
        <?php } ?>
        <script>const x = 1;</script>
        """
        let tokens = try parser().tokens(for: source).tokens
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            #expect(NSMaxRange(left.range) <= right.range.location)
        }
    }

    // MARK: - Degenerate input

    @Test("Malformed and adversarial input does not crash")
    func adversarial() throws {
        for source in [
            "<?php",
            "?>",
            "<?php /* unterminated",
            "<div><?php echo '</div>'; ?>",
            "<?php ?><?php ?><?php ?>",
            "",
            "no php at all, just text",
        ] {
            _ = try highlight(source)
        }
    }

    /// A file that is only HTML still goes through the combined path, with one
    /// range covering everything.
    @Test("A .php file with no PHP in it is highlighted as HTML")
    func noPHPAtAll() throws {
        let found = try highlight("<div id=\"a\"><span>text</span></div>")
        #expect(found.contains { $0 == ("div", .tag) })
        #expect(found.contains { $0 == ("id", .attribute) })
        #expect(found.contains { $0 == ("span", .tag) })
    }
}
