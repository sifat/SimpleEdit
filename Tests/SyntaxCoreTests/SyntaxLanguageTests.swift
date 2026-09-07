import Testing
@testable import SyntaxCore

@Suite("Language detection")
struct SyntaxLanguageTests {

    @Test("HTML is detected by extension, case-insensitively")
    func htmlExtensions() {
        #expect(SyntaxLanguage(fileExtension: "html") == .html)
        #expect(SyntaxLanguage(fileExtension: "htm") == .html)
        #expect(SyntaxLanguage(fileExtension: "HTML") == .html)
        #expect(SyntaxLanguage(fileExtension: "Htm") == .html)
    }

    @Test("Anything else is not a language we know")
    func otherExtensions() {
        #expect(SyntaxLanguage(fileExtension: "txt") == nil)
        #expect(SyntaxLanguage(fileExtension: "json") == nil)
        // An untitled document has no extension at all.
        #expect(SyntaxLanguage(fileExtension: "") == nil)
    }

    @Test("Menu tags round-trip for every case")
    func tagRoundTrip() {
        for language in SyntaxLanguage.allCases {
            #expect(SyntaxLanguage(tag: language.tag) == language)
        }
    }

    @Test("Only real languages have a queries directory")
    func queryDirectories() {
        #expect(SyntaxLanguage.plain.queryDirectoryName == nil)
        #expect(SyntaxLanguage.html.queryDirectoryName == "html")
    }
}
