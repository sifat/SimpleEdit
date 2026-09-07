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
    ]

    /// Captures a language emits and this app deliberately does not colour.
    /// Written down per language so that "unmapped" stays a decision with a
    /// reason -- `SyntaxTokenKind.overrides` carries the reasons -- while a
    /// capture that becomes unmapped by ACCIDENT still fails the suite.
    private static let deliberatelyUnmapped: [SyntaxLanguage: Set<String>] = [
        .javascript: ["variable", "variable.builtin", "constructor", "embedded"],
    ]

    private static func captureNames(in language: SyntaxLanguage) throws -> Set<String> {
        let directory = try #require(language.queryDirectoryName)
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Queries/\(directory)/highlights.scm")
        var text = try String(contentsOf: file, encoding: .utf8)

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
        for language in SyntaxLanguage.allCases where language.queryDirectoryName != nil {
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
