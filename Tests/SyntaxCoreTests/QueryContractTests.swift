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
    ]

    private static func captureNames(in language: SyntaxLanguage) throws -> Set<String> {
        let directory = try #require(language.queryDirectoryName)
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Queries/\(directory)/highlights.scm")
        var text = try String(contentsOf: file, encoding: .utf8)

        // Strip `;` comments and then double-quoted literals BEFORE looking for
        // captures. The CSS query matches at-rules by their literal text --
        //
        //     "@media" @keyword
        //
        // -- so a scan that simply splits on "@" reports `media`, `import`,
        // `charset` and three more as capture names the grammar never emits.
        // The HTML query has no string literals, which is why this only showed
        // up with the second language.
        for pattern in [";[^\n]*", "\"[^\"]*\""] {
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

    /// Every capture a query emits must map to a kind. A name that maps to
    /// nothing is text that silently stays uncoloured.
    @Test("Every capture in every query maps to a token kind")
    func everyCaptureMaps() throws {
        for language in Self.expectedCaptures.keys {
            for name in try Self.captureNames(in: language) {
                #expect(
                    SyntaxTokenKind(captureName: name) != nil,
                    "unmapped capture: @\(name) in \(language.rawValue)"
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
                if let kind = SyntaxTokenKind(captureName: name) { produced.insert(kind) }
            }
        }
        #expect(produced == Set(SyntaxTokenKind.allCases))
    }
}
