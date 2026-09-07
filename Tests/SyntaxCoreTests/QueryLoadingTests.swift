import Foundation
import Testing
@testable import SyntaxCore

/// The vendored query files are the one part of this feature that fails at
/// RUNTIME with no build signal: a missing or renamed capture just means nothing
/// gets coloured. These tests move that failure to `swift test`.
@Suite("Query loading")
struct QueryLoadingTests {

    /// Repo root, derived from this file's own path rather than Bundle.main --
    /// under `swift test` Bundle.main is the xctest runner, not the app.
    static var queriesRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/SyntaxCoreTests/QueryLoadingTests.swift
            .deletingLastPathComponent()          // .../Tests/SyntaxCoreTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Resources/Queries", isDirectory: true)
    }

    /// Every case that claims a queries directory, so a new language is covered
    /// by these two tests the moment its enum case exists.
    private static var highlightedLanguages: [SyntaxLanguage] {
        SyntaxLanguage.allCases.filter { $0.queryDirectoryName != nil }
    }

    @Test("The vendored highlights.scm is present in the source tree", arguments: highlightedLanguages)
    func queryFileExists(language: SyntaxLanguage) throws {
        let directory = try #require(language.queryDirectoryName)
        let file = Self.queriesRoot.appendingPathComponent("\(directory)/highlights.scm")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("It compiles against the pinned grammar", arguments: highlightedLanguages)
    func queryCompiles(language: SyntaxLanguage) {
        #expect(SyntaxParser(language: language, queriesRoot: Self.queriesRoot) != nil)
    }

    /// `.plain` is not a grammar and must not pretend to be one -- a parser for
    /// it would mean the app tried to highlight every plain-text document.
    @Test("Plain text has no parser")
    func plainHasNoParser() {
        #expect(SyntaxParser(language: .plain, queriesRoot: Self.queriesRoot) == nil)
    }
}
