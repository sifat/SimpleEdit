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

    @Test("CSS is detected by extension")
    func cssExtensions() {
        #expect(SyntaxLanguage(fileExtension: "css") == .css)
        #expect(SyntaxLanguage(fileExtension: "CSS") == .css)
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
        #expect(SyntaxLanguage.css.queryDirectoryName == "css")
    }

    /// Two languages claiming the same extension would make detection depend on
    /// `allCases` order, which nothing guarantees and nobody would look at.
    @Test("No extension is claimed by two languages")
    func extensionsAreUnique() {
        var seen: Set<String> = []
        for language in SyntaxLanguage.allCases {
            for ext in language.fileExtensions {
                #expect(seen.insert(ext).inserted, "\(ext) is claimed twice")
            }
        }
    }

    /// Same argument, one level down: two languages sharing a queries directory
    /// would load one grammar's query against the other's parser.
    @Test("No queries directory is claimed by two languages")
    func queryDirectoriesAreUnique() {
        let directories = SyntaxLanguage.allCases.compactMap(\.queryDirectoryName)
        #expect(Set(directories).count == directories.count)
    }
}
