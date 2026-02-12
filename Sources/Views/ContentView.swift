import SwiftUI

/// Main app layout: NavigationSplitView with sidebar + detail.
/// The detail area uses HSplitView to optionally show a right panel (Files / Changes tabs).
struct ContentView: View {
    @Bindable var sessionManager: SessionManager
    var onFileOpen: ((URL) -> Void)?
    var onDiffOpen: ((FileDiff) -> Void)?
    @AppStorage("showFileTree") private var showFileTree: Bool = false
    @State private var rightPanelTab: String = "files"

    var body: some View {
        NavigationSplitView {
            SidebarView(sessionManager: sessionManager)
        } detail: {
            if let selectedId = sessionManager.selectedSessionId,
               let session = sessionManager.sessions.first(where: { $0.id == selectedId }) {
                HSplitView {
                    SessionDetailView(session: session, sessionManager: sessionManager)
                        .frame(minWidth: 400)

                    if showFileTree {
                        rightPanel(for: session)
                            .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                    }
                }
            } else {
                emptyState
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showFileTree.toggle() }) {
                    Image(systemName: "sidebar.trailing")
                }
                .help(showFileTree ? "Hide right panel" : "Show right panel")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToChangesTab)) { _ in
            rightPanelTab = "changes"
        }
    }

    // MARK: - Right Panel

    @ViewBuilder
    private func rightPanel(for session: TerminalSession) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $rightPanelTab) {
                Text("Files").tag("files")
                Text("Changes").tag("changes")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if rightPanelTab == "files" {
                FileTreeView(
                    rootURL: URL(fileURLWithPath: session.repo.path),
                    onFileOpen: onFileOpen
                )
            } else {
                GitChangesView(
                    repoPath: session.repo.path,
                    onDiffOpen: onDiffOpen
                )
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Project Selected")
                .font(.title2)
            Text("Add a project directory to get started")
                .foregroundStyle(.secondary)
            Button("Add Project") {
                addRepoViaOpenPanel()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addRepoViaOpenPanel() {
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
                // Show alert for errors
                let alert = NSAlert()
                alert.messageText = "Could not add project"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
