import AppKit

/// Makes Cmd+O able to open anything.
///
/// NSDocumentController's default typeForContents(of:) just returns the URL's
/// UTI, so a file with an unknown or absent extension (.env, .conf, a bare
/// LICENSE) resolves to a dynamic dyn.* type that matches nothing we declare in
/// CFBundleDocumentTypes, and the open fails with an unhelpful error.
final class EditorDocumentController: NSDocumentController {

    static let canonicalType = "public.text"

    override func typeForContents(of url: URL) throws -> String {
        Self.canonicalType
    }
}
