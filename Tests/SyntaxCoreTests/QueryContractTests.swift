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

    private static var highlightsFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Queries/html/highlights.scm")
    }

    @Test("The HTML query captures exactly the seven names we map")
    func captureSet() throws {
        let text = try String(contentsOf: Self.highlightsFile, encoding: .utf8)

        var names: Set<String> = []
        for match in text.split(separator: "@").dropFirst() {
            let name = match.prefix { $0.isLetter || $0 == "." || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }

        #expect(names == [
            "tag", "tag.error", "constant", "attribute",
            "string", "comment", "punctuation.bracket",
        ])
    }

    /// Every capture the query emits must map to a kind. A name that maps to
    /// nothing is text that silently stays uncoloured.
    @Test("Every capture in the query maps to a token kind")
    func everyCaptureMaps() throws {
        let text = try String(contentsOf: Self.highlightsFile, encoding: .utf8)
        for match in text.split(separator: "@").dropFirst() {
            let name = String(match.prefix { $0.isLetter || $0 == "." || $0 == "_" })
            guard !name.isEmpty else { continue }
            #expect(SyntaxTokenKind(captureName: name) != nil, "unmapped capture: @\(name)")
        }
    }

    /// The mirror of the above: a kind nothing can produce is dead code, which
    /// is what a bump that *removes* a capture would leave behind.
    @Test("Every token kind is reachable from some capture")
    func everyKindReachable() throws {
        let text = try String(contentsOf: Self.highlightsFile, encoding: .utf8)
        var produced: Set<SyntaxTokenKind> = []
        for match in text.split(separator: "@").dropFirst() {
            let name = String(match.prefix { $0.isLetter || $0 == "." || $0 == "_" })
            if let kind = SyntaxTokenKind(captureName: name) { produced.insert(kind) }
        }
        #expect(produced == Set(SyntaxTokenKind.allCases))
    }
}
