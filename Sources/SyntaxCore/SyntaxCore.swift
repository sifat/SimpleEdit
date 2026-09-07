import Foundation
import SwiftTreeSitter
import TreeSitterHTML

/// Skeleton for the HTML tokeniser. The types land in the next commit; this one
/// exists to prove the dependency graph, the C cross-compilation and the
/// vendored query file before any behaviour depends on them.
public enum SyntaxCore {

    /// Loads the HTML grammar's highlight query from a queries root laid out as
    /// `<root>/html/highlights.scm`.
    ///
    /// The root is a parameter rather than a `Bundle.main` lookup on purpose:
    /// the app passes its own `Contents/Resources/Queries`, and the tests pass a
    /// path derived from `#filePath`. One code path, two roots -- otherwise the
    /// tests would be exercising a parallel implementation of the thing most
    /// likely to break.
    public static func htmlConfiguration(queriesRoot: URL) throws -> LanguageConfiguration {
        try LanguageConfiguration(
            Language(tree_sitter_html()),
            name: "html",
            queriesURL: queriesRoot.appendingPathComponent("html", isDirectory: true)
        )
    }
}
