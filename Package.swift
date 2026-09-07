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
        // exact, not `from:`. swift-tree-sitter's tag 0.25.0 is numerically the
        // highest but is CHRONOLOGICALLY OLDER (June 2025) than 0.10.0 (Feb
        // 2026), so `from:` silently resolves to the older, less capable
        // release. CotEditor pins the same way, for the same reason.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.10.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
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
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
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
