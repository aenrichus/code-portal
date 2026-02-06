import AppKit
import SwiftTerm

/// LocalProcessTerminalView subclass that monitors output for attention-needed patterns.
/// The line buffer + ANSI strip + pattern match logic is ~20 lines inline in `dataReceived`.
///
/// CRITICAL WARNINGS:
/// - Always call `super.dataReceived(slice:)` or terminal display breaks.
/// - lineBuffer is capped at 64KB to prevent OOM from binary/no-newline output.
/// - `session` is a weak reference to avoid retain cycles (SessionManager owns both).
final class MonitoredTerminalView: LocalProcessTerminalView {

    /// Weak back-reference to the session. SessionManager.terminalViewPool owns the view strongly.
    /// View callbacks capture [weak session] to avoid cycles.
    weak var session: TerminalSession?

    /// Line buffer for accumulating partial lines between dataReceived calls.
    /// Capped at 64KB — if binary or no-newline output exceeds this, the buffer is cleared.
    private var lineBuffer = Data()

    /// Maximum line buffer size: 64KB. Prevents OOM from binary/no-newline streams.
    private static let lineBufferCap = 65_536

    /// ANSI escape sequence pattern for stripping terminal formatting.
    /// Single-pass DFA scan. Matches CSI sequences like \e[0m, \e[32;1m, etc.
    private static let ansiPattern = /\e\[[0-9;]*[a-zA-Z]/

    /// Patterns that indicate Claude Code needs attention.
    /// Hardcoded for v1. If Claude Code changes output format, ship an app update.
    private static let attentionPatterns: [(String) -> Bool] = [
        { $0.contains("? (y/n)") },
        { $0.contains("(Y)es") },
        { $0.range(of: #"Allow .+\?"#, options: .regularExpression) != nil },
        { $0.hasPrefix("Error:") },
        { $0.hasPrefix("error:") },
    ]

    // MARK: - Output Monitoring

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // MUST call super for terminal rendering
        super.dataReceived(slice: slice)

        lineBuffer.append(contentsOf: slice)

        // 64KB cap: prevents OOM from binary/no-newline output
        if lineBuffer.count > Self.lineBufferCap {
            lineBuffer.removeAll(keepingCapacity: true)
            return
        }

        // Process complete lines
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            let line = String(decoding: lineData, as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)

            // Strip ANSI escape sequences for pattern matching
            let stripped = line.replacing(Self.ansiPattern, with: "")

            // Check for attention patterns
            if Self.attentionPatterns.contains(where: { $0(stripped) }) {
                let matchedPattern = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                let capturedSession = self.session
                Task { @MainActor in
                    guard let session = capturedSession else { return }
                    if session.state == .running {
                        session.state = .attention
                        session.emit(.attentionDetected(sessionId: session.id, pattern: matchedPattern))
                        session.emit(.stateChanged(sessionId: session.id, newState: .attention))
                    }
                }
            } else {
                // Any non-attention output while in .attention means Claude is working again
                let capturedSession = self.session
                Task { @MainActor in
                    guard let session = capturedSession else { return }
                    if session.state == .attention {
                        session.state = .running
                        session.emit(.stateChanged(sessionId: session.id, newState: .running))
                    }
                }
            }
        }
    }

    /// Called when the process exits. Updates session state and finishes continuations.
    func handleProcessTerminated(exitCode: Int32?) {
        let capturedSession = self.session
        Task { @MainActor in
            guard let session = capturedSession else { return }
            session.state = .idle
            session.emit(.processExited(sessionId: session.id, exitCode: exitCode))
            session.emit(.stateChanged(sessionId: session.id, newState: .idle))
        }
    }

    /// Reset line buffer when starting a new process.
    func resetLineBuffer() {
        lineBuffer.removeAll(keepingCapacity: true)
    }
}
