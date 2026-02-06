import SwiftUI
import SwiftTerm

/// Detail view showing the terminal for the selected session.
/// Uses a view pool pattern: NSViewRepresentable wrapper swaps child views
/// from SessionManager.terminalViewPool instead of using .id() which destroys/recreates.
struct SessionDetailView: View {
    let session: TerminalSession
    @Bindable var sessionManager: SessionManager

    var body: some View {
        ZStack {
            // Terminal view from pool
            TerminalViewWrapper(
                sessionId: session.id,
                sessionManager: sessionManager
            )

            // Restart overlay when session is idle (process exited)
            if session.state == .idle {
                restartOverlay
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                statusLabel
            }
        }
    }

    // MARK: - Status Label (inline, ~15 lines)

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

// MARK: - Terminal View Wrapper (NSViewRepresentable, inline)

/// Bridges SwiftTerm's AppKit NSView into SwiftUI.
/// Uses view pool pattern: returns container in makeNSView, swaps child in updateNSView.
/// Tab switch drops to <5ms (view reparenting only, no view destruction/recreation).
///
/// CRITICAL: Never restart processes or recreate views in updateNSView.
/// Use for child view swapping only.
private struct TerminalViewWrapper: NSViewRepresentable {
    let sessionId: UUID
    let sessionManager: SessionManager

    func makeNSView(context: Context) -> NSView {
        // Container view that holds the terminal
        let container = NSView()
        container.autoresizesSubviews = true
        updateTerminalChild(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        updateTerminalChild(in: container)
    }

    private func updateTerminalChild(in container: NSView) {
        guard let terminalView = sessionManager.terminalViewPool[sessionId] else { return }

        // Only reparent if not already a child of this container
        if terminalView.superview !== container {
            // Remove from previous parent (if any)
            terminalView.removeFromSuperview()

            // Add to this container
            terminalView.frame = container.bounds
            terminalView.autoresizingMask = [.width, .height]
            container.addSubview(terminalView)
        }

        // Ensure the terminal view has keyboard focus
        if let window = container.window, window.firstResponder !== terminalView {
            window.makeFirstResponder(terminalView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Don't remove the terminal view — it lives in the pool.
        // Only remove the container's reference to it.
        for subview in nsView.subviews {
            subview.removeFromSuperview()
        }
    }
}
