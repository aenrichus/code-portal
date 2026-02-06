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

    /// Weak back-reference to session manager for state change notifications.
    weak var sessionManager: SessionManager?

    /// Line buffer for accumulating partial lines between dataReceived calls.
    private var lineBuffer = Data()

    // MARK: - Focus Management

    /// Request keyboard focus when the view enters a window.
    /// This is the reliable callback — `updateNSView` in NSViewRepresentable fires
    /// before the view is in a window, so `makeFirstResponder` silently fails.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.makeFirstResponder(self)
    }

    // MARK: - Output Monitoring

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // MUST call super for terminal rendering
        super.dataReceived(slice: slice)

        let results = AttentionDetector.processData(slice, lineBuffer: &lineBuffer)

        for (stripped, isAttention) in results {
            if isAttention {
                let matchedPattern = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                let capturedSession = self.session
                let capturedManager = self.sessionManager
                Task { @MainActor in
                    guard let session = capturedSession else { return }
                    if session.state == .running {
                        let oldState = session.state
                        session.state = .attention
                        session.emit(.attentionDetected(sessionId: session.id, pattern: matchedPattern))
                        session.emit(.stateChanged(sessionId: session.id, newState: .attention))
                        capturedManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .attention)
                    }
                }
            } else {
                // Any non-attention output while in .attention means Claude is working again
                let capturedSession = self.session
                let capturedManager = self.sessionManager
                Task { @MainActor in
                    guard let session = capturedSession else { return }
                    if session.state == .attention {
                        let oldState = session.state
                        session.state = .running
                        session.emit(.stateChanged(sessionId: session.id, newState: .running))
                        capturedManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .running)
                    }
                }
            }
        }
    }

    /// Called when the process exits. Updates session state and finishes continuations.
    func handleProcessTerminated(exitCode: Int32?) {
        let capturedSession = self.session
        let capturedManager = self.sessionManager
        Task { @MainActor in
            guard let session = capturedSession else { return }
            let oldState = session.state
            session.state = .idle
            session.emit(.processExited(sessionId: session.id, exitCode: exitCode))
            session.emit(.stateChanged(sessionId: session.id, newState: .idle))
            capturedManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .idle)
        }
    }

    /// Reset line buffer when starting a new process.
    func resetLineBuffer() {
        lineBuffer.removeAll(keepingCapacity: true)
    }
}
