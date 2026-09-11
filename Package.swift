// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode, deliberately. NSDocument is @MainActor at the class level
// but read(from:ofType:) / write(to:ofType:) are NS_SWIFT_NONISOLATED while
// data(ofType:) is not; under Swift 6 mode every read override needs an
// assumeIsolated dance to touch document state. v5 surfaces the same warnings
// without the ceremony.
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SimpleEdit",
    platforms: [.macOS(.v14)],
    dependencies: [
        // tree-sitter itself, and nothing on top of it. The Swift binding
        // (swift-tree-sitter) was dropped once the query loop moved to the C
        // API: it built a QueryCapture object per capture, which was most of
        // the cost of highlighting -- see SyntaxParser. Nothing imports it any
        // more, so carrying it would mean resolving and building a package the
        // app does not use.
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        // 0.23.2 rather than the newer 0.25.0 on purpose: 0.25.0's manifest
        // decides whether to compile the external scanner with a RELATIVE
        // FileManager.fileExists("src/scanner.c"), which is not resolved against
        // the dependency's own checkout. See Resources/Queries/css/SOURCE.md.
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        // 0.23.1 is the newest JavaScript tag that is not booby-trapped. There
        // is no 0.23.2 -- the grammars version independently. 0.25.0 carries the
        // relative-path scanner hazard described above, and 0.23.0 is worse
        // still: its manifest never filled in the generator's "add your external
        // scanner here" comment, so it drops scanner.c unconditionally rather
        // than only sometimes. highlights.scm is byte-identical between 0.23.1
        // and 0.25.0, so the newer tag buys nothing here anyway.
        //
        // Note the capital S: 0.23.0 spelled the product TreeSitterJavascript.
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        // One product, two grammars (typescript and tsx). No 0.25 tag exists for
        // this repo, so the scanner hazard above does not arise; both targets
        // list their scanner.c unconditionally.
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        // 0.23.6, not 0.25.0: the same relative-path scanner hazard as the
        // grammars above, and Python's external scanner is what handles
        // indentation, so losing it would break nearly every file.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        // 0.23.3, deliberately not 0.25.1 -- and not for the scanner reason the
        // others give: Bash's 0.25 manifests list scanner.c unconditionally, so
        // that hazard does not arise. highlights.scm is byte-identical between
        // the two tags, so the only difference is the parser, and 0.25.1's is
        // ABI 15 where every other grammar here is ABI 14. A new compatibility
        // surface bought for no highlighting difference. Its manifest also asks
        // for swift-tree-sitter `from: "0.25.0"`, the tag that is older than
        // 0.10.0; test-only and pruned, but not a thing to invite.
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.23.3"),
        // 0.23.5 is the newest tag there is. Java has no external scanner, so
        // the scanner hazard the other pins guard against cannot arise here.
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
    ],
    targets: [
        // Foundation only, no AppKit — so `swift test` can cover the parts where a
        // bug is silent and destroys the user's file, without launching an app.
        .target(
            name: "EditorCore",
            swiftSettings: swiftSettings
        ),
        // Deliberately NOT part of EditorCore. EditorCore exists so `swift test`
        // can cover the code where a bug silently destroys the user's file;
        // dragging a generated C parser in there would make those tests build
        // tens of MB of grammar and would let a dependency-resolution failure
        // take the file-integrity tests down with it. This target keeps the
        // property that actually matters -- no AppKit, so it stays headlessly
        // testable.
        .target(
            name: "SyntaxCore",
            dependencies: [
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "SimpleEdit",
            dependencies: ["EditorCore", "SyntaxCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SyntaxCoreTests",
            dependencies: ["SyntaxCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
