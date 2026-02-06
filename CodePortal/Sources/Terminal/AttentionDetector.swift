import Foundation

/// Pure-function attention detection logic, extracted for testability.
/// No AppKit or SwiftTerm dependency — can be tested without instantiating views.
///
/// Strategy: Claude Code is an Ink (React for CLI) TUI that renders via cursor
/// repositioning, NOT newline-delimited lines. We read the terminal's visible
/// buffer (already parsed by SwiftTerm) and scan it for attention patterns.
enum AttentionDetector {

    /// ANSI escape sequence pattern for stripping terminal formatting.
    /// Single-pass DFA scan. Matches CSI sequences like \e[0m, \e[32;1m, etc.
    /// nonisolated(unsafe): Regex<Substring> is not Sendable but this is immutable after init.
    nonisolated(unsafe) static let ansiPattern = /\e\[[0-9;]*[a-zA-Z]/

    /// Strip ANSI escape sequences from a line.
    static func stripANSI(_ input: String) -> String {
        input.replacing(ansiPattern, with: "")
    }

    /// Patterns that indicate Claude Code needs attention.
    /// Checked against each visible line of the terminal buffer (already ANSI-free
    /// since we read from SwiftTerm's parsed buffer, not raw bytes).
    ///
    /// Hardcoded for v1. If Claude Code changes output format, ship an app update.
    static let attentionPatterns: [@Sendable (String) -> Bool] = [
        // Claude Code permission prompts: "Allow Read file.txt?" / "Allow Bash(ls)?"
        { $0.range(of: #"(?i)allow .+\?"#, options: .regularExpression) != nil },
        // Yes/no confirmation prompts
        { $0.contains("? (y/n)") },
        // Capitalized yes prompts: "(Y)es / (N)o"
        { $0.contains("(Y)es") },
        // "Do you want to proceed?" style prompts
        { $0.range(of: #"(?i)do you want to .+\?"#, options: .regularExpression) != nil },
    ]

    /// Check if a single line matches any attention pattern.
    static func isAttention(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return attentionPatterns.contains(where: { $0(trimmed) })
    }

    /// Scan an array of visible terminal lines for attention patterns.
    /// Returns the first matching line (for logging/notification), or nil if no attention needed.
    ///
    /// Lines should come from SwiftTerm's `getLine(row:).translateToString()` —
    /// already decoded, no ANSI escapes.
    static func scanBuffer(_ lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if isAttention(trimmed) {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Legacy line-buffer processing (kept for raw-byte fallback)

    /// Maximum line buffer size: 64KB. Prevents OOM from binary/no-newline streams.
    static let lineBufferCap = 65_536

    /// Process raw terminal data against a line buffer.
    /// Returns an array of (stripped_line, is_attention) tuples for each complete line found.
    /// Mutates the lineBuffer in place.
    ///
    /// NOTE: This only fires on newline-delimited output. For TUI apps like Claude Code
    /// that use cursor repositioning, use scanBuffer() with timer-based polling instead.
    static func processData(
        _ data: ArraySlice<UInt8>,
        lineBuffer: inout Data
    ) -> [(line: String, isAttention: Bool)] {
        lineBuffer.append(contentsOf: data)

        // 64KB cap: prevents OOM from binary/no-newline output
        if lineBuffer.count > lineBufferCap {
            lineBuffer.removeAll(keepingCapacity: true)
            return []
        }

        var results: [(String, Bool)] = []

        // Process complete lines
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            let line = String(decoding: lineData, as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)

            let stripped = stripANSI(line)
            results.append((stripped, isAttention(stripped)))
        }

        return results
    }
}
