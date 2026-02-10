import SwiftUI

/// Main app layout: NavigationSplitView with sidebar + detail.
/// The detail area uses HSplitView to optionally show a file tree panel on the right.
struct ContentView: View {
    @Bindable var sessionManager: SessionManager
    @AppStorage("showFileTree") private var showFileTree: Bool = false

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
                        FileTreeView(rootURL: URL(fileURLWithPath: session.repo.path))
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
                .help(showFileTree ? "Hide file browser" : "Show file browser")
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
