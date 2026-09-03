import EditorCore
import Foundation

enum JSONMode: String {
    case pretty
    case minify
    case validate
}

struct JSONToolError: Error {
    /// UTF-8 byte offset of the problem, or nil when the helper could not say.
    let byteOffset: Int?
    let message: String
}

/// Runs the bundled `jsonfmt` helper.
///
/// The helper exists because Foundation cannot pretty-print JSON without damage:
/// JSONSerialization destroys object key order and rewrites number literals.
/// Go's encoding/json.Indent is a byte-level re-emitter, so key order, duplicate
/// keys, number literals and string escapes all survive verbatim.
enum JSONTool {

    static func run(_ mode: JSONMode, on source: String) throws -> String {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "jsonfmt") else {
            throw JSONToolError(
                byteOffset: nil,
                message: "The jsonfmt helper is missing from the application bundle."
            )
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [mode.rawValue]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // Start draining before writing. A document larger than the ~64 KB pipe
        // buffer deadlocks otherwise: we block writing stdin while the helper
        // blocks writing stdout. This only ever bites on large files, which are
        // exactly the ones Format JSON is most useful for.
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        var outputData = Data()
        var errorData = Data()

        group.enter()
        queue.async {
            outputData = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // try? because the helper may already have exited on a usage error, and a
        // failed write is reported by the exit status below rather than here.
        try? input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try? input.fileHandleForWriting.close()

        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw parseFailure(errorData)
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    /// The helper reports failures as a single "<byteOffset>\t<message>" line.
    private static func parseFailure(_ data: Data) -> JSONToolError {
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let offset = Int(parts[0]) {
            return JSONToolError(
                byteOffset: offset >= 0 ? offset : nil,
                message: String(parts[1])
            )
        }
        return JSONToolError(
            byteOffset: nil,
            message: raw.isEmpty ? "The JSON helper failed without a message." : raw
        )
    }
}
