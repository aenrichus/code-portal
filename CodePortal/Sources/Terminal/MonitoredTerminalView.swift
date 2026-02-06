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
/// This handles TUI apps correctly because we read the already-rendered screen content,
/// not the raw escape sequences used to draw it.
///
/// CRITICAL WARNINGS:
/// - Always call `super.dataReceived(slice:)` or terminal display breaks.
/// - `session` is a weak reference to avoid retain cycles (SessionManager owns both).
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

    /// Whether we've seen any real output yet (to distinguish initial launch from task completion).
    private var hasSeenOutput = false

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

        hasSeenOutput = true

        // Reset debounce timer — scan will fire when output settles
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: Self.scanDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanTerminalBuffer()
            }
        }
    }

    /// Read the visible terminal buffer and check for attention patterns.
    private func scanTerminalBuffer() {
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
        let matchedPattern = AttentionDetector.scanBuffer(visibleLines)
        var needsAttention = matchedPattern != nil

        // Also check if Claude finished its task and is waiting for the next input.
        // Only flag this if we've seen actual output (not on initial launch).
        if !needsAttention && hasSeenOutput {
            if AttentionDetector.isWaitingForInput(visibleLines) {
                needsAttention = true
            }
        }

        if needsAttention && !lastScanFoundAttention {
            // Transition: running → attention
            lastScanFoundAttention = true
            let pattern = matchedPattern ?? "Waiting for input"
            let capturedSession = self.session
            let capturedManager = self.sessionManager
            Task { @MainActor in
                guard let session = capturedSession else { return }
                if session.state == .running {
                    let oldState = session.state
                    session.state = .attention
                    session.emit(.attentionDetected(sessionId: session.id, pattern: pattern))
                    session.emit(.stateChanged(sessionId: session.id, newState: .attention))
                    capturedManager?.handleSessionStateChange(session: session, oldState: oldState, newState: .attention)
                }
            }
        } else if !needsAttention && lastScanFoundAttention {
            // Transition: attention → running (auto-recovery when Claude starts working again)
            lastScanFoundAttention = false
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

    /// Called when the process exits. Updates session state and finishes continuations.
    func handleProcessTerminated(exitCode: Int32?) {
        scanTimer?.invalidate()
        scanTimer = nil
        lastScanFoundAttention = false

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

    /// Reset state when starting a new process.
    func resetForNewProcess() {
        scanTimer?.invalidate()
        scanTimer = nil
        lastScanFoundAttention = false
        hasSeenOutput = false
    }
}
