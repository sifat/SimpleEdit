import Foundation
import Testing
@testable import SyntaxCore

/// The canary for a grammar bump.
///
/// If upstream renames or adds a capture, the symptom in the app is silent:
/// some category of text simply stops being coloured, with no error anywhere.
/// Pinning the capture set turns that into a test failure at the moment the
/// pin is moved, which is the only moment anyone is in a position to react.
@Suite("Vendored query contract")
struct QueryContractTests {

    /// Every capture name each vendored query is expected to emit. Adding a
    /// language means adding a row; `everyLanguageIsPinned` makes forgetting to
    /// a test failure rather than an unnoticed gap.
    private static let expectedCaptures: [SyntaxLanguage: Set<String>] = [
        .html: [
            "tag", "tag.error", "constant", "attribute",
            "string", "comment", "punctuation.bracket",
        ],
        .css: [
            "comment", "tag", "operator", "string", "string.special",
            "attribute", "property", "function", "variable", "keyword",
            "number", "type", "punctuation.delimiter",
        ],
        .javascript: [
            "comment", "constant", "constant.builtin", "constructor", "embedded",
            "function", "function.builtin", "function.method", "keyword", "number",
            "operator", "property", "punctuation.bracket", "punctuation.delimiter",
            "punctuation.special", "string", "string.special", "variable",
            "variable.builtin",
        ],
        // JavaScript's nineteen plus three the fragment adds. If this ever
        // equals JavaScript's set exactly, the concatenation silently stopped
        // happening and TypeScript is being highlighted as plain JavaScript.
        .typescript: [
            "comment", "constant", "constant.builtin", "constructor", "embedded",
            "function", "function.builtin", "function.method", "keyword", "number",
            "operator", "property", "punctuation.bracket", "punctuation.delimiter",
            "punctuation.special", "string", "string.special", "variable",
            "variable.builtin", "type", "type.builtin", "variable.parameter",
        ],
        .python: [
            "comment", "constant", "constant.builtin", "constructor", "embedded",
            "escape", "function", "function.builtin", "function.method", "keyword",
            "number", "operator", "property", "punctuation.special", "string",
            "type", "variable",
        ],
        .shell: [
            "comment", "constant", "embedded", "function", "keyword", "number",
            "operator", "property", "string",
        ],
        .java: [
            "attribute", "comment", "constant", "constant.builtin", "function.builtin",
            "function.method", "keyword", "number", "operator", "string",
            "string.escape", "type", "type.builtin", "variable", "variable.builtin",
        ],
        .php: [
            "comment", "constant", "constant.builtin", "constructor", "function",
            "function.builtin", "function.method", "keyword", "module", "module.builtin",
            "number", "operator", "property", "string", "tag", "type", "type.builtin",
            "variable", "variable.builtin",
        ],
    ]

    /// Captures a language emits and this app deliberately does not colour.
    /// Written down per language so that "unmapped" stays a decision with a
    /// reason -- `SyntaxTokenKind.overrides` carries the reasons -- while a
    /// capture that becomes unmapped by ACCIDENT still fails the suite.
    private static let deliberatelyUnmapped: [SyntaxLanguage: Set<String>] = [
        .javascript: ["variable", "variable.builtin", "constructor", "embedded"],
        .typescript: ["variable", "variable.builtin", "variable.parameter", "constructor", "embedded"],
        // `escape` is nested inside `(string)`, which covers it whole, so no
        // mapping could ever be seen; leaving it unmapped says so.
        .python: ["variable", "constructor", "embedded", "escape"],
        .shell: ["embedded"],
        .java: ["variable"],
    ]

    /// Reads every file the language composes its query from, not just its own
    /// directory -- TypeScript's set is its fragment plus JavaScript's whole
    /// query, and pinning only the fragment would pin five names out of
    /// twenty-two.
    private static func captureNames(in language: SyntaxLanguage) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Queries", isDirectory: true)
        #expect(!language.queryFiles.isEmpty)
        var text = try language.queryFiles
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        // Strip quoted literals FIRST, then `;` comments, before looking for
        // captures. Both strips are needed: the CSS query matches at-rules by
        // their literal text --
        //
        //     "@media" @keyword
        //
        // -- so a scan that simply splits on "@" reports `media`, `import`,
        // `charset` and three more as capture names the grammar never emits.
        //
        // The ORDER is what took a third language to expose. The JavaScript
        // query contains the literal `";"`, and stripping comments first eats
        // its closing quote; every later quote then pairs off by one and the
        // rest of the file is stripped as if it were one long string. That
        // silently pinned 14 of JavaScript's 19 captures -- losing @embedded,
        // @operator and all three @punctuation.* -- which is precisely the
        // "a capture stopped being coloured and nothing failed" outcome this
        // suite exists to prevent. Neither vendored query contains a quoted
        // `;`, so the HTML and CSS sets are bit-identical either way.
        for pattern in ["\"[^\"]*\"", ";[^\n]*"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        var names: Set<String> = []
        for match in text.split(separator: "@").dropFirst() {
            let name = match.prefix { $0.isLetter || $0 == "." || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    /// A language whose captures nobody has pinned is a language whose grammar
    /// can change under us in silence -- the exact failure this suite exists to
    /// prevent, reintroduced by omission.
    @Test("Every language with a query has its capture set pinned")
    func everyLanguageIsPinned() {
        for language in SyntaxLanguage.allCases where !language.queryFiles.isEmpty {
            #expect(
                Self.expectedCaptures[language] != nil,
                "no pinned capture set for \(language.rawValue)"
            )
        }
    }

    @Test("Each query captures exactly the names we expect", arguments: expectedCaptures.keys)
    func captureSet(language: SyntaxLanguage) throws {
        #expect(try Self.captureNames(in: language) == Self.expectedCaptures[language])
    }

    /// Every capture a query emits must either map to a kind or be listed as
    /// deliberately unmapped. A name that maps to nothing without being listed
    /// is text that silently stays uncoloured.
    @Test("Every capture in every query maps to a token kind, or is listed")
    func everyCaptureMaps() throws {
        for language in Self.expectedCaptures.keys {
            let allowed = Self.deliberatelyUnmapped[language] ?? []
            for name in try Self.captureNames(in: language) where !allowed.contains(name) {
                #expect(
                    SyntaxTokenKind(captureName: name, in: language) != nil,
                    "unmapped capture: @\(name) in \(language.rawValue)"
                )
            }
        }
    }

    /// The other half. A name listed as deliberately unmapped that has since
    /// GAINED a mapping means the list is lying, and the next reader would
    /// trust it.
    @Test("Every deliberately-unmapped capture really is unmapped")
    func unmappedListIsHonest() throws {
        for (language, names) in Self.deliberatelyUnmapped {
            let emitted = try Self.captureNames(in: language)
            for name in names {
                #expect(emitted.contains(name), "@\(name) is not emitted by \(language.rawValue)")
                #expect(
                    SyntaxTokenKind(captureName: name, in: language) == nil,
                    "@\(name) is listed as unmapped but maps in \(language.rawValue)"
                )
            }
        }
    }

    /// The mirror of the above: a kind nothing can produce is dead code, which
    /// is what a bump that *removes* a capture would leave behind. Taken across
    /// all languages at once, since a kind only one grammar produces is still
    /// reachable.
    @Test("Every token kind is reachable from some capture")
    func everyKindReachable() throws {
        var produced: Set<SyntaxTokenKind> = []
        for language in Self.expectedCaptures.keys {
            for name in try Self.captureNames(in: language) {
                if let kind = SyntaxTokenKind(captureName: name, in: language) {
                    produced.insert(kind)
                }
            }
        }
        #expect(produced == Set(SyntaxTokenKind.allCases))
    }
}
