import SwiftUI
import SwiftTerm

/// Detail view showing the terminal for the selected session.
/// Uses a view pool pattern: NSViewControllerRepresentable wrapper swaps child views
/// from SessionManager.terminalViewPool instead of using .id() which destroys/recreates.
struct SessionDetailView: View {
    let session: TerminalSession
    @Bindable var sessionManager: SessionManager

    var body: some View {
        ZStack {
            // Terminal view from pool via NSViewControllerRepresentable
            TerminalViewControllerWrapper(
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

// MARK: - Terminal View Controller Wrapper (NSViewControllerRepresentable)

/// Bridges SwiftTerm's AppKit NSView into SwiftUI via NSViewControllerRepresentable.
///
/// Using NSViewControllerRepresentable instead of NSViewRepresentable is critical:
/// NSViewRepresentable embeds the NSView inside SwiftUI's own hosting view, which
/// intercepts keyboard events. NSViewControllerRepresentable gives the terminal its
/// own NSViewController with a proper AppKit responder chain, so keyDown events
/// flow directly to the TerminalView.
///
/// Uses view pool pattern: the coordinator tracks the current session, and
/// updateNSViewController swaps the terminal child view from the pool.
private struct TerminalViewControllerWrapper: NSViewControllerRepresentable {
    let sessionId: UUID
    let sessionManager: SessionManager

    func makeNSViewController(context: Context) -> TerminalHostViewController {
        let vc = TerminalHostViewController()
        vc.currentSessionId = sessionId
        installTerminalView(in: vc)
        return vc
    }

    func updateNSViewController(_ vc: TerminalHostViewController, context: Context) {
        if vc.currentSessionId != sessionId {
            vc.currentSessionId = sessionId
        }
        installTerminalView(in: vc)
    }

    private func installTerminalView(in vc: TerminalHostViewController) {
        guard let terminalView = sessionManager.terminalViewPool[sessionId] else { return }
        let container = vc.view

        // Only reparent if not already a child of this container
        if terminalView.superview !== container {
            // Remove all existing subviews (previous terminal)
            for subview in container.subviews {
                subview.removeFromSuperview()
            }

            // Add terminal view filling the container
            terminalView.frame = container.bounds
            terminalView.autoresizingMask = [.width, .height]
            container.addSubview(terminalView)
        }

        // Ensure the terminal view has keyboard focus.
        // Defer to next run loop iteration so the view is fully in the window.
        DispatchQueue.main.async {
            guard let window = terminalView.window else { return }
            if window.firstResponder !== terminalView {
                window.makeFirstResponder(terminalView)
            }
        }
    }

    static func dismantleNSViewController(_ vc: TerminalHostViewController, coordinator: ()) {
        // Remove terminal from container but don't destroy it (lives in pool)
        for subview in vc.view.subviews {
            subview.removeFromSuperview()
        }
    }
}

// MARK: - Terminal Host View Controller

/// Minimal NSViewController that hosts a terminal view.
/// Provides proper AppKit responder chain for keyboard input.
final class TerminalHostViewController: NSViewController {
    var currentSessionId: UUID?

    override func loadView() {
        // Create a plain NSView as the root — the terminal view will be added as a subview
        let root = NSView()
        root.autoresizesSubviews = true
        self.view = root
    }
}
