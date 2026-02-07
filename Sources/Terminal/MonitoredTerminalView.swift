import AppKit
import SwiftTerm

/// LocalProcessTerminalView subclass that monitors output for attention-needed patterns.
///
/// Strategy: Claude Code is an Ink (React for CLI) TUI — it renders via cursor
/// repositioning, not newline-delimited text. Raw PTY bytes don't contain reliable
/// newlines for prompt detection.
///
/// Instead of parsing raw bytes, we use a **debounced buffer scan**:
/// 1. `dataReceived` resets a short timer on every data chunk.
/// 2. When output settles (no new data for `scanDelay`), the timer fires.
/// 3. We read SwiftTerm's parsed visible buffer via `getTerminal().getLine(row:)`.
/// 4. Scan the visible text for attention patterns using `AttentionDetector`.
///
/// Recovery strategy: The debounced scan detects when the attention pattern has
/// disappeared from the visible buffer (Claude is working again) and clears
/// the attention state. We do NOT clear attention in dataReceived because
/// small data chunks (cursor blinks, TUI redraws on view reattach) would
/// falsely clear attention when switching between repos.
///
/// CRITICAL WARNINGS:
/// - Always call `super.dataReceived(slice:)` or terminal display breaks.
/// - `session` is a weak reference to avoid retain cycles (SessionManager owns both).
/// - State changes are synchronous (no Task) to avoid race conditions between
///   `lastScanFoundAttention` and `session.state`.
final class MonitoredTerminalView: LocalProcessTerminalView {

    /// Weak back-reference to the session. SessionManager.terminalViewPool owns the view strongly.
    weak var session: TerminalSession?

    /// Weak back-reference to session manager for state change notifications.
    weak var sessionManager: SessionManager?

    /// Debounce timer for buffer scanning. Reset on each dataReceived call.
    private var scanTimer: Timer?

    /// Delay after last output before scanning the buffer. 500ms balances responsiveness
    /// with avoiding false positives during rapid TUI redraws.
    private static let scanDelay: TimeInterval = 0.5

    /// Track whether we're currently in attention state to avoid redundant scans
    /// emitting duplicate transitions.
    private var lastScanFoundAttention = false

    // MARK: - Focus Management

    /// Request keyboard focus when the view enters a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.makeFirstResponder(self)
    }

    // MARK: - Output Monitoring (Debounced Buffer Scan)

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // MUST call super for terminal rendering
        super.dataReceived(slice: slice)

        // Reset debounce timer — scan will fire when output settles
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: Self.scanDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanTerminalBuffer()
            }
        }
    }

    /// Read the visible terminal buffer and check for attention patterns.
    ///
    /// IMPORTANT: All state changes are synchronous. Using `Task { @MainActor in }` here
    /// would defer execution to a later runloop tick, creating a race condition where
    /// `lastScanFoundAttention` resets before `session.state` updates. This causes the
    /// recovery branch to miss its guard check, leaving the session stuck in `.attention`.
    private func scanTerminalBuffer() {
        guard let session = session else { return }

        let terminal = getTerminal()
        let rowCount = terminal.rows

        var visibleLines: [String] = []
        for row in 0..<rowCount {
            if let bufferLine = terminal.getLine(row: row) {
                let text = bufferLine.translateToString(trimRight: true)
                visibleLines.append(text)
            }
        }

        // Check for explicit attention patterns (questions, permission prompts)
        // AND idle prompt (Claude finished, waiting for next command)
        let matchedPattern = AttentionDetector.scanBuffer(visibleLines)
        let isIdle = AttentionDetector.isIdlePrompt(visibleLines)
        let needsAttention = matchedPattern != nil || isIdle

        if needsAttention && !lastScanFoundAttention {
            // Transition: running → attention
            lastScanFoundAttention = true
            if session.state == .running {
                let oldState = session.state
                session.state = .attention
                let pattern = matchedPattern ?? (isIdle ? "idle prompt" : "")
                session.emit(.attentionDetected(sessionId: session.id, pattern: pattern))
                session.emit(.stateChanged(sessionId: session.id, newState: .attention))
                sessionManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .attention)
            }
        } else if !needsAttention && lastScanFoundAttention {
            // Transition: attention → running (backup recovery via debounced scan)
            lastScanFoundAttention = false
            if session.state == .attention {
                let oldState = session.state
                session.state = .running
                session.emit(.stateChanged(sessionId: session.id, newState: .running))
                sessionManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .running)
            }
        }
    }

    /// Called when the process exits. Updates session state and finishes continuations.
    func handleProcessTerminated(exitCode: Int32?) {
        scanTimer?.invalidate()
        scanTimer = nil
        lastScanFoundAttention = false

        guard let session = session else { return }
        let oldState = session.state
        session.state = .idle
        session.emit(.processExited(sessionId: session.id, exitCode: exitCode))
        session.emit(.stateChanged(sessionId: session.id, newState: .idle))
        sessionManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .idle)
    }

    /// Reset state when starting a new process.
    func resetForNewProcess() {
        scanTimer?.invalidate()
        scanTimer = nil
        lastScanFoundAttention = false
    }
}
