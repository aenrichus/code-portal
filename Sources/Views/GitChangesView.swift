import SwiftUI

/// Right panel "Changes" tab showing git status, file list with staging controls,
/// and a commit bar. Auto-refreshes on a 2-second timer when visible.
struct GitChangesView: View {
    let repoPath: String
    var onDiffOpen: ((FileDiff) -> Void)?
    @State private var gitService: GitService?
    @State private var commitMessage: String = ""
    @State private var showCommitField: Bool = false
    @State private var revertTarget: FileChange?

    var body: some View {
        VStack(spacing: 0) {
            if let service = gitService {
                if !service.status.isGitRepo {
                    notARepoView
                } else {
                    changesList(service: service)
                    Divider()
                    commitBar(service: service)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: repoPath) {
            let service = GitService(repoPath: repoPath)
            gitService = service
            await service.refreshStatus()
        }
        .task(id: repoPath) {
            // Auto-refresh polling every 2 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await gitService?.refreshStatus()
            }
        }
        .alert("Revert File?", isPresented: .init(
            get: { revertTarget != nil },
            set: { if !$0 { revertTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { revertTarget = nil }
            Button("Revert", role: .destructive) {
                if let target = revertTarget {
                    revertTarget = nil
                    Task {
                        let isUntracked: Bool
                        if case .untracked = target.status { isUntracked = true }
                        else { isUntracked = false }
                        try? await gitService?.revertFile(
                            target.path,
                            isUntracked: isUntracked
                        )
                    }
                }
            }
        } message: {
            if let target = revertTarget {
                Text("This will discard all changes to \"\(target.path)\". This cannot be undone.")
            }
        }
    }

    // MARK: - Changes List

    @ViewBuilder
    private func changesList(service: GitService) -> some View {
        if service.status.staged.isEmpty && service.status.unstaged.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Working tree clean")
                    .foregroundStyle(.secondary)
                if let branch = service.status.branch {
                    Text("On branch \(branch)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                // Branch header
                if let branch = service.status.branch {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Text(branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)
                }

                // Error banner
                if let error = service.currentError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .listRowSeparator(.hidden)
                }

                // Staged section
                if !service.status.staged.isEmpty {
                    Section {
                        ForEach(service.status.staged) { file in
                            fileRow(file, service: service)
                        }
                    } header: {
                        HStack {
                            Text("Staged")
                            Spacer()
                            Button("Unstage All") {
                                Task { await service.unstageAll() }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                }

                // Unstaged section
                if !service.status.unstaged.isEmpty {
                    Section {
                        ForEach(service.status.unstaged) { file in
                            fileRow(file, service: service)
                        }
                    } header: {
                        HStack {
                            Text("Changes")
                            Spacer()
                            Button("Stage All") {
                                Task { await service.stageAll() }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - File Row

    private func fileRow(_ file: FileChange, service: GitService) -> some View {
        HStack(spacing: 6) {
            statusBadge(file.status)

            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task {
                if let diff = await service.diffForFile(file.path, staged: file.isStaged) {
                    onDiffOpen?(diff)
                }
            }
        }
        .contextMenu {
            if file.isStaged {
                Button("Unstage") {
                    Task { await service.unstageFile(file.path) }
                }
            } else {
                Button("Stage") {
                    Task { await service.stageFile(file.path) }
                }
            }

            Button("View Diff") {
                Task {
                    if let diff = await service.diffForFile(file.path, staged: file.isStaged) {
                        onDiffOpen?(diff)
                    }
                }
            }

            Divider()

            Button("Revert", role: .destructive) {
                revertTarget = file
            }
        }
    }

    // MARK: - Status Badge

    private func statusBadge(_ status: FileChangeStatus) -> some View {
        Text(statusLetter(status))
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundStyle(statusColor(status))
            .frame(width: 16)
    }

    private func statusLetter(_ status: FileChangeStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        }
    }

    private func statusColor(_ status: FileChangeStatus) -> Color {
        switch status {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .secondary
        }
    }

    // MARK: - Commit Bar

    @ViewBuilder
    private func commitBar(service: GitService) -> some View {
        VStack(spacing: 6) {
            if showCommitField {
                TextField("Commit message...", text: $commitMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { commitAction(service: service) }

                HStack {
                    Button("Cancel") {
                        showCommitField = false
                        commitMessage = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Commit") { commitAction(service: service) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
                                  || service.status.staged.isEmpty
                                  || service.isBusy)
                }
            } else {
                Button {
                    showCommitField = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Commit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(service.status.staged.isEmpty || service.isBusy)
            }
        }
        .padding(8)
    }

    private func commitAction(service: GitService) {
        let msg = commitMessage.trimmingCharacters(in: .whitespaces)
        guard !msg.isEmpty else { return }
        commitMessage = ""
        showCommitField = false
        Task {
            do {
                try await service.commit(message: msg)
            } catch {
                service.currentError = error.localizedDescription
            }
        }
    }

    // MARK: - Not a Repo

    private var notARepoView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Not a Git Repository")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
