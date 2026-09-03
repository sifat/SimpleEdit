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
    targets: [
        // Foundation only, no AppKit — so `swift test` can cover the parts where a
        // bug is silent and destroys the user's file, without launching an app.
        .target(
            name: "EditorCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "SimpleEdit",
            dependencies: ["EditorCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
