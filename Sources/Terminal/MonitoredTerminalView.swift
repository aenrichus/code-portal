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

    // MARK: - Theme

    /// Light-mode ANSI palette: 16 colors tuned for readability on a light background.
    /// Based on macOS Terminal.app colors with contrast adjustments.
    /// Uses SwiftTerm.Color(red:green:blue:) with 16-bit values (value * 257 maps 8-bit to 16-bit).
    private static let lightAnsiColors: [SwiftTerm.Color] = [
        // dark colors (0-7)
        SwiftTerm.Color(red: 0, green: 0, blue: 0),                                 // black
        SwiftTerm.Color(red: 194 * 257, green: 54 * 257, blue: 33 * 257),           // red
        SwiftTerm.Color(red: 37 * 257, green: 148 * 257, blue: 36 * 257),           // green (darkened)
        SwiftTerm.Color(red: 143 * 257, green: 133 * 257, blue: 0),                 // yellow (darkened)
        SwiftTerm.Color(red: 0, green: 30 * 257, blue: 195 * 257),                  // blue
        SwiftTerm.Color(red: 178 * 257, green: 0, blue: 178 * 257),                 // magenta
        SwiftTerm.Color(red: 0, green: 140 * 257, blue: 160 * 257),                 // cyan (darkened)
        SwiftTerm.Color(red: 100 * 257, green: 100 * 257, blue: 100 * 257),         // white (dimmed for light bg)
        // bright colors (8-15)
        SwiftTerm.Color(red: 86 * 257, green: 86 * 257, blue: 86 * 257),            // bright black (gray)
        SwiftTerm.Color(red: 220 * 257, green: 44 * 257, blue: 20 * 257),           // bright red
        SwiftTerm.Color(red: 28 * 257, green: 180 * 257, blue: 28 * 257),           // bright green
        SwiftTerm.Color(red: 186 * 257, green: 170 * 257, blue: 0),                 // bright yellow
        SwiftTerm.Color(red: 50 * 257, green: 50 * 257, blue: 220 * 257),           // bright blue
        SwiftTerm.Color(red: 200 * 257, green: 40 * 257, blue: 200 * 257),          // bright magenta
        SwiftTerm.Color(red: 0, green: 180 * 257, blue: 190 * 257),                 // bright cyan
        SwiftTerm.Color(red: 60 * 257, green: 60 * 257, blue: 60 * 257),            // bright white (darkened)
    ]

    /// Dark-mode ANSI palette: matches SwiftTerm's default installed colors.
    /// Reproduced here because `Color.defaultInstalledColors` is internal.
    private static let darkAnsiColors: [SwiftTerm.Color] = [
        SwiftTerm.Color(red: 0, green: 0, blue: 0),                                 // black
        SwiftTerm.Color(red: 153 * 257, green: 0, blue: 1 * 257),                   // red
        SwiftTerm.Color(red: 0, green: 166 * 257, blue: 3 * 257),                   // green
        SwiftTerm.Color(red: 153 * 257, green: 153 * 257, blue: 0),                 // yellow
        SwiftTerm.Color(red: 3 * 257, green: 0, blue: 178 * 257),                   // blue
        SwiftTerm.Color(red: 178 * 257, green: 0, blue: 178 * 257),                 // magenta
        SwiftTerm.Color(red: 0, green: 165 * 257, blue: 178 * 257),                 // cyan
        SwiftTerm.Color(red: 191 * 257, green: 191 * 257, blue: 191 * 257),         // white
        SwiftTerm.Color(red: 138 * 257, green: 137 * 257, blue: 138 * 257),         // bright black
        SwiftTerm.Color(red: 229 * 257, green: 0, blue: 1 * 257),                   // bright red
        SwiftTerm.Color(red: 0, green: 216 * 257, blue: 0),                         // bright green
        SwiftTerm.Color(red: 229 * 257, green: 229 * 257, blue: 0),                 // bright yellow
        SwiftTerm.Color(red: 7 * 257, green: 0, blue: 254 * 257),                   // bright blue
        SwiftTerm.Color(red: 229 * 257, green: 0, blue: 229 * 257),                 // bright magenta
        SwiftTerm.Color(red: 0, green: 229 * 257, blue: 229 * 257),                 // bright cyan
        SwiftTerm.Color(red: 229 * 257, green: 229 * 257, blue: 229 * 257),         // bright white
    ]

    /// Apply dark or light terminal theme.
    /// Sets foreground/background colors and installs the appropriate 16-color ANSI palette.
    func applyTheme(isDark: Bool) {
        if isDark {
            nativeForegroundColor = NSColor(white: 0.85, alpha: 1.0)
            nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
            installColors(Self.darkAnsiColors)
        } else {
            nativeForegroundColor = NSColor(white: 0.15, alpha: 1.0)
            nativeBackgroundColor = NSColor(white: 0.98, alpha: 1.0)
            installColors(Self.lightAnsiColors)
        }
        setNeedsDisplay(bounds)
    }

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
