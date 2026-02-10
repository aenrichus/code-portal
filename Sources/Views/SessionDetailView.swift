import SwiftUI
import SwiftTerm

/// Detail view showing the terminal for the selected session.
/// The terminal view from the pool is returned directly from NSViewRepresentable
/// (no container wrapper) so keyboard events flow naturally to SwiftTerm.
struct SessionDetailView: View {
    let session: TerminalSession
    @Bindable var sessionManager: SessionManager

    var body: some View {
        ZStack {
            // Terminal view returned directly from pool.
            // .id() forces SwiftUI to call makeNSView when session changes,
            // but the pool retains the view so there's no actual destruction.
            TerminalViewWrapper(sessionManager: sessionManager, sessionId: session.id)
                .id("\(session.id)-\(session.restartCount)")

            // Restart overlay when session is idle (process exited)
            if session.state == .idle {
                restartOverlay
                    // Allow clicks through to the overlay buttons but not to steal
                    // focus from terminal when overlay is absent.
            }
        }
        .onAppear {
            // Fallback: request focus after a short delay to cover cases where
            // viewDidMoveToWindow fires before the window is fully ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                requestTerminalFocus()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                statusLabel
            }
        }
    }

    // MARK: - Status Label

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .idle: return .gray
        case .running: return .green
        case .attention: return .orange
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Idle"
        case .running: return "Running"
        case .attention: return "Needs Attention"
        }
    }

    // MARK: - Focus Helper

    /// Request keyboard focus on the terminal view for the current session.
    private func requestTerminalFocus() {
        guard let view = sessionManager.terminalViewPool[session.id],
              let window = view.window else { return }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
    }

    // MARK: - Restart Overlay

    private var restartOverlay: some View {
        VStack(spacing: 12) {
            Text("Session ended")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Restart") {
                sessionManager.restartSession(id: session.id, caller: .userInterface)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Terminal View Wrapper (NSViewRepresentable)

/// Returns the MonitoredTerminalView directly from makeNSView — no container.
/// This is critical: wrapping the terminal in a container NSView breaks keyboard
/// input because the container sits in SwiftUI's responder chain and intercepts
/// key events before they reach the terminal.
///
/// The view pool in SessionManager keeps the terminal alive across SwiftUI
/// view lifecycle. When .id() changes, SwiftUI calls dismantleNSView (no-op)
/// then makeNSView for the new session (returns existing pool view).
private struct TerminalViewWrapper: NSViewRepresentable {
    let sessionManager: SessionManager
    let sessionId: UUID

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Return the pool view directly. If missing, return a placeholder.
        guard let view = sessionManager.terminalViewPool[sessionId] else {
            return LocalProcessTerminalView(frame: .zero)
        }
        return view
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
        // Focus is managed by MonitoredTerminalView.viewDidMoveToWindow() and mouseDown().
        // Do NOT call makeFirstResponder here — updateNSView fires repeatedly during
        // SwiftUI layout and the view may not be in a window yet.
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        // No-op: the view pool retains the terminal view.
        // Do NOT remove from superview — SwiftUI handles that.
    }
}
