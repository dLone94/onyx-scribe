import Foundation
import os

/// Structured production diagnostics (os.Logger, visible in Console.app).
///
/// **Privacy contract:** release logs carry metadata ONLY — session ids, engine
/// names, language codes, timings, character/word counts, permission state, and
/// redacted error categories. They must NEVER contain dictated, selected,
/// drafted, translated, or cleaned text, clipboard contents, app-context text,
/// or vocabulary entries.
///
/// DEBUG builds additionally mirror events to stdout for terminal runs, and
/// only there may a `content:` payload (the actual text) appear. The payload
/// autoclosure is never evaluated in release. Explicit transcript output in
/// shipped binaries exists only in the developer CLI test commands
/// (`--test`, `--stream-test`, …), which the user invokes deliberately on
/// their own files.
enum Diag {
    static let pipeline = Logger(subsystem: "com.todor.flowclone", category: "pipeline")
    static let audio = Logger(subsystem: "com.todor.flowclone", category: "audio")
    static let store = Logger(subsystem: "com.todor.flowclone", category: "store")

    /// Metadata-only event — safe in release.
    static func event(_ message: String, logger: Logger = pipeline) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        print(message)
        #endif
    }

    /// An event with an associated user-content payload. Release logs the
    /// metadata message alone; the payload prints only in DEBUG terminals.
    static func content(_ message: String, content: @autoclosure () -> String,
                        logger: Logger = pipeline) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        print("\(message): \(content())")
        #endif
    }

    /// Errors: the stable `category` string is logged in release (error
    /// descriptions can embed user content, so the `error` itself is DEBUG-only).
    static func error(_ category: String, error: Error? = nil, logger: Logger = pipeline) {
        logger.error("\(category, privacy: .public)")
        #if DEBUG
        if let error { print("❌ \(category): \(error)") } else { print("❌ \(category)") }
        #endif
    }

    /// Sugar for the common pipeline-error shape.
    static func pipelineError(_ category: String, _ err: Error) {
        error(category, error: err)
    }
}
