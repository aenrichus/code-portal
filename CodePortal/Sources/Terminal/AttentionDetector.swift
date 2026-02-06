import Foundation

/// Pure-function attention detection logic, extracted for testability.
/// No AppKit or SwiftTerm dependency — can be tested without instantiating views.
///
/// Strategy: Claude Code is an Ink (React for CLI) TUI that renders via cursor
/// repositioning, NOT newline-delimited lines. We read the terminal's visible
/// buffer (already parsed by SwiftTerm) and scan it for attention patterns.
///
/// Real Claude Code terminal buffer patterns (from debug captures):
///
/// Multi-choice question:
///   ❯ 1. [ ] OpenAI (GPT-4, GPT-3.5)
///   Enter to select · Tab/Arrow keys to navigate · Esc to cancel
///
/// Permission prompt (tool approval):
///   Allow Bash(ls -la)?
///   Yes  No  Always
///
/// Working (NOT attention):
///   Thinking on (tab to toggle)
///   ⏺ Building the project...
enum AttentionDetector {

    /// ANSI escape sequence pattern for stripping terminal formatting.
    nonisolated(unsafe) static let ansiPattern = /\e\[[0-9;]*[a-zA-Z]/

    /// Strip ANSI escape sequences from a line.
    static func stripANSI(_ input: String) -> String {
        input.replacing(ansiPattern, with: "")
    }

    /// Patterns that indicate Claude Code needs user attention.
    /// Checked against each visible line of the terminal buffer.
    ///
    /// These are derived from actual Claude Code terminal buffer captures.
    static let attentionPatterns: [@Sendable (String) -> Bool] = [
        // Multi-choice / interactive question UI
        // "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"
        { $0.contains("Enter to select") },

        // Permission / tool approval prompts
        // "Allow Read /etc/hosts?" or "Allow Bash(ls -la)?"
        { $0.range(of: #"(?i)allow .+\?"#, options: .regularExpression) != nil },

        // Yes/No button row (permission prompt buttons)
        // "  Yes  No  Always" — but not inside normal prose
        { $0.range(of: #"^\s*(Yes|No|Always)\s+(Yes|No|Always)"#, options: .regularExpression) != nil },

        // Yes/no confirmation prompts (generic)
        { $0.contains("? (y/n)") },
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

    /// Maximum line buffer size: 64KB.
    static let lineBufferCap = 65_536

    /// Process raw terminal data against a line buffer.
    /// NOTE: This only fires on newline-delimited output. For TUI apps like Claude Code
    /// that use cursor repositioning, use scanBuffer() with timer-based polling instead.
    static func processData(
        _ data: ArraySlice<UInt8>,
        lineBuffer: inout Data
    ) -> [(line: String, isAttention: Bool)] {
        lineBuffer.append(contentsOf: data)

        if lineBuffer.count > lineBufferCap {
            lineBuffer.removeAll(keepingCapacity: true)
            return []
        }

        var results: [(String, Bool)] = []

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
