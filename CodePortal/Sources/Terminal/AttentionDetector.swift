import Foundation

/// Pure-function attention detection logic, extracted for testability.
/// No AppKit or SwiftTerm dependency — can be tested without instantiating views.
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
    /// Hardcoded for v1. If Claude Code changes output format, ship an app update.
    static let attentionPatterns: [@Sendable (String) -> Bool] = [
        { $0.contains("? (y/n)") },
        { $0.contains("(Y)es") },
        { $0.range(of: #"Allow .+\?"#, options: .regularExpression) != nil },
        { $0.hasPrefix("Error:") },
        { $0.hasPrefix("error:") },
    ]

    /// Check if a stripped (ANSI-free) line matches any attention pattern.
    static func isAttention(_ strippedLine: String) -> Bool {
        attentionPatterns.contains(where: { $0(strippedLine) })
    }

    /// Maximum line buffer size: 64KB. Prevents OOM from binary/no-newline streams.
    static let lineBufferCap = 65_536

    /// Process raw terminal data against a line buffer.
    /// Returns an array of (stripped_line, is_attention) tuples for each complete line found.
    /// Mutates the lineBuffer in place.
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
