import Foundation

/// Read-only snapshot of a file's content for display in the file viewer.
/// Use the async `load(from:)` factory to read files off the main thread.
struct FileContent: Sendable {
    let url: URL
    let filename: String
    let fileSize: Int64

    enum ContentType: Sendable {
        case text(String, language: String?)
        case binary
        case tooLarge
        case error(String)
    }

    let contentType: ContentType

    /// Async factory -- reads file off the main thread.
    static func load(from url: URL) async -> FileContent {
        let filename = url.lastPathComponent
        let fileSize: Int64 = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int64) ?? 0

        // Size check
        let oneMB: Int64 = 1_048_576
        guard fileSize <= oneMB else {
            return FileContent(url: url, filename: filename,
                               fileSize: fileSize, contentType: .tooLarge)
        }

        // Read bytes
        guard let data = try? Data(contentsOf: url) else {
            return FileContent(url: url, filename: filename,
                               fileSize: fileSize, contentType: .error("Could not read file"))
        }

        // Binary detection: check for null bytes in first 8192 bytes
        let checkLength = min(data.count, 8192)
        if data.prefix(checkLength).contains(0x00) {
            return FileContent(url: url, filename: filename,
                               fileSize: fileSize, contentType: .binary)
        }

        // Decode: try UTF-8 first, fall back to ISO Latin-1 (never fails)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)!

        // Language is nil -- Highlightr will auto-detect from content
        return FileContent(url: url, filename: filename,
                           fileSize: fileSize, contentType: .text(text, language: nil))
    }
}
