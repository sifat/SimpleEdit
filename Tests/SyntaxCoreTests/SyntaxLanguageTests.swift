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
        #expect(SyntaxLanguage.javascript.queryDirectoryName == "javascript")
    }

    @Test("JavaScript is detected by extension, module variants included")
    func javaScriptExtensions() {
        #expect(SyntaxLanguage(fileExtension: "js") == .javascript)
        #expect(SyntaxLanguage(fileExtension: "mjs") == .javascript)
        #expect(SyntaxLanguage(fileExtension: "cjs") == .javascript)
        #expect(SyntaxLanguage(fileExtension: "JS") == .javascript)
        // Not jsx: that needs the grammar's separate highlights-jsx.scm, which
        // this app does not vendor.
        #expect(SyntaxLanguage(fileExtension: "jsx") == nil)
    }

    /// The cap is a measured number, and a language that has a grammar but no
    /// cap would be highlighted at any size -- the failure the cap prevents.
    @Test("Every highlighted language caps its document size")
    func capsAreSet() {
        for language in SyntaxLanguage.allCases where language.queryDirectoryName != nil {
            #expect(language.maximumLength > 0, "\(language.rawValue) has no size cap")
        }
        #expect(SyntaxLanguage.plain.maximumLength == 0)
        // JavaScript is denser per KB than the markup languages, so its cap is
        // lower. If these ever match, one of them was changed without measuring.
        #expect(SyntaxLanguage.javascript.maximumLength < SyntaxLanguage.css.maximumLength)
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
