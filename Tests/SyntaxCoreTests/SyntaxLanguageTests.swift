import Foundation
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
        #expect(SyntaxLanguage.python.queryDirectoryName == "python")
        // The case is named for what the user sees; the directory for the
        // grammar that actually parses it.
        #expect(SyntaxLanguage.shell.queryDirectoryName == "bash")
        #expect(SyntaxLanguage.java.queryDirectoryName == "java")
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

    @Test("Python is detected by extension, stubs and windowed scripts included")
    func pythonExtensions() {
        #expect(SyntaxLanguage(fileExtension: "py") == .python)
        #expect(SyntaxLanguage(fileExtension: "pyi") == .python)
        #expect(SyntaxLanguage(fileExtension: "pyw") == .python)
        #expect(SyntaxLanguage(fileExtension: "PY") == .python)
        // Compiled bytecode is not source.
        #expect(SyntaxLanguage(fileExtension: "pyc") == nil)
    }

    @Test("Shell scripts are detected by extension")
    func shellExtensions() {
        for ext in ["sh", "bash", "zsh", "command", "SH"] {
            #expect(SyntaxLanguage(fileExtension: ext) == .shell, "\(ext)")
        }
    }

    /// The reason `init?(fileName:)` exists. A dotfile's path extension is the
    /// empty string, so extension-only detection missed every one of these --
    /// the shell files a text editor is most likely to be pointed at.
    @Test("Shell dotfiles are detected by name, though they have no extension")
    func shellDotfiles() {
        for name in [".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile", ".zshenv"] {
            #expect((name as NSString).pathExtension.isEmpty, "\(name) unexpectedly has an extension")
            #expect(SyntaxLanguage(fileName: name) == .shell, "\(name)")
        }
        #expect(SyntaxLanguage(fileName: ".ZSHRC") == .shell)
    }

    @Test("Detection by name falls back to the extension")
    func fileNameFallsBackToExtension() {
        #expect(SyntaxLanguage(fileName: "deploy.sh") == .shell)
        #expect(SyntaxLanguage(fileName: "index.html") == .html)
        #expect(SyntaxLanguage(fileName: "types.d.ts") == .typescript)
        // Nothing to go on at all.
        #expect(SyntaxLanguage(fileName: "Makefile") == nil)
        #expect(SyntaxLanguage(fileName: ".gitignore") == nil)
        #expect(SyntaxLanguage(fileName: "") == nil)
        // A name that merely contains a dotfile's name is not that dotfile.
        #expect(SyntaxLanguage(fileName: "my.zshrc.backup") == nil)
    }

    @Test("No file name is claimed by two languages")
    func fileNamesAreUnique() {
        var seen: Set<String> = []
        for language in SyntaxLanguage.allCases {
            for name in language.fileNames {
                #expect(seen.insert(name).inserted, "\(name) is claimed twice")
            }
        }
    }

    @Test("Java is detected by extension")
    func javaExtensions() {
        #expect(SyntaxLanguage(fileExtension: "java") == .java)
        #expect(SyntaxLanguage(fileExtension: "JAVA") == .java)
        #expect(SyntaxLanguage(fileName: "Cart.java") == .java)
        // Compiled classes and archives are not source.
        #expect(SyntaxLanguage(fileExtension: "class") == nil)
        #expect(SyntaxLanguage(fileExtension: "jar") == nil)
    }

    /// The cap is a measured number, and a language that has a grammar but no
    /// cap would be highlighted at any size -- the failure the cap prevents.
    @Test("Every highlighted language caps its document size")
    func capsAreSet() {
        for language in SyntaxLanguage.allCases where language.queryDirectoryName != nil {
            #expect(language.maximumLength > 0, "\(language.rawValue) has no size cap")
        }
        #expect(SyntaxLanguage.plain.maximumLength == 0)
        // Real stylesheets produce about half the captures per KB that dense
        // markup or component JavaScript do, so CSS is the one language that
        // earns a larger cap. If these ever match, one was changed without
        // measuring.
        #expect(SyntaxLanguage.javascript.maximumLength < SyntaxLanguage.css.maximumLength)
        #expect(SyntaxLanguage.html.maximumLength < SyntaxLanguage.css.maximumLength)
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
