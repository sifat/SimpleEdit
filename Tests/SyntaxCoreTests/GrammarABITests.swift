import Foundation
import Testing
import TreeSitter
@testable import SyntaxCore

/// Which tree-sitter ABI each grammar was generated for.
///
/// The number decides whether the pinned core loads the grammar at all --
/// `ts_parser_set_language` refuses one outside its range, and the document
/// then quietly opens plain -- and it is quoted in several SOURCE.md files as
/// a reason for choosing one tag over another. Pinning it here turns "every
/// other grammar is ABI 14", a sentence that rotted twice in one day, into a
/// test that fails the moment a bump changes it.
@Suite("Grammar ABI")
struct GrammarABITests {

    private static let expected: [SyntaxLanguage: UInt32] = [
        .html: 14, .css: 14, .javascript: 14, .typescript: 14,
        .python: 14, .shell: 14, .java: 14,
        .php: 15, .sql: 15,
    ]

    @Test("Every grammar's ABI version is the one its SOURCE.md claims")
    func abiVersions() throws {
        for language in SyntaxLanguage.allCases where language != .plain {
            let grammar = try #require(SyntaxParser.grammar(for: language))
            let version = ts_language_abi_version(grammar)
            #expect(
                version == Self.expected[language],
                "\(language.rawValue) is ABI \(version)"
            )
            // ...and one the pinned core will load.
            #expect(version >= UInt32(TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION))
            #expect(version <= UInt32(TREE_SITTER_LANGUAGE_VERSION))
        }
        #expect(Set(Self.expected.keys) == Set(SyntaxLanguage.allCases.filter { $0 != .plain }))
    }
}
