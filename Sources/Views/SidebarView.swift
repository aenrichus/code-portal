import SwiftUI

/// Sidebar listing all projects with status indicators.
struct SidebarView: View {
    @Bindable var sessionManager: SessionManager

    var body: some View {
        List(selection: $sessionManager.selectedSessionId) {
            ForEach(sessionManager.sessions) { session in
                sessionRow(session)
                    .tag(session.id)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addRepo) {
                    Image(systemName: "plus")
                }
                .help("Add project directory")
            }
        }
        .navigationTitle("Projects")
        .onAppear {
            // Auto-start persisted sessions on launch.
            // onChange won't fire for the initial value set in loadPersistedRepos.
            if let id = sessionManager.selectedSessionId {
                sessionManager.startSession(id: id)
            }
        }
        .onChange(of: sessionManager.selectedSessionId) { _, newId in
            // Lazy session start: spawn PTY on first selection
            if let id = newId {
                sessionManager.startSession(id: id)
            }
        }
    }

    // MARK: - Session Row (inline, ~20 lines)

    @ViewBuilder
    private func sessionRow(_ session: TerminalSession) -> some View {
        HStack(spacing: 8) {
            statusDot(for: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.repo.name)
                    .font(.body)
                    .lineLimit(1)
                Text(session.repo.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Restart Session") {
                sessionManager.restartSession(id: session.id, caller: .userInterface)
            }
            .disabled(session.state == .idle)

            Divider()

            Button("Remove Project", role: .destructive) {
                sessionManager.removeRepo(id: session.id, caller: .userInterface)
            }
        }
    }

    /// Status indicator dot: gray (idle), green (running), orange (attention).
    private func statusDot(for state: SessionState) -> some View {
        Circle()
            .fill(statusColor(for: state))
            .frame(width: 8, height: 8)
    }

    private func statusColor(for state: SessionState) -> SwiftUI.Color {
        switch state {
        case .idle: return .gray
        case .running: return .green
        case .attention: return .orange
        }
    }

    // MARK: - Add Repo

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try sessionManager.addRepo(path: url.path, caller: .userInterface)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not add project"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
