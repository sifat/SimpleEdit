import Foundation
import Testing
@testable import SyntaxCore

/// The vendored query file is the one part of this feature that fails at
/// RUNTIME with no build signal: a missing or renamed capture just means nothing
/// gets coloured. These tests move that failure to `swift test`.
@Suite("HTML query loading")
struct QueryLoadingTests {

    /// Repo root, derived from this file's own path rather than Bundle.main --
    /// under `swift test` Bundle.main is the xctest runner, not the app.
    private static var queriesRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/SyntaxCoreTests/QueryLoadingTests.swift
            .deletingLastPathComponent()          // .../Tests/SyntaxCoreTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Resources/Queries", isDirectory: true)
    }

    @Test("The vendored highlights.scm is present in the source tree")
    func queryFileExists() {
        let file = Self.queriesRoot
            .appendingPathComponent("html/highlights.scm")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("It compiles against the pinned grammar")
    func queryCompiles() throws {
        let configuration = try SyntaxCore.htmlConfiguration(queriesRoot: Self.queriesRoot)
        #expect(configuration.queries[.highlights] != nil)
    }
}
