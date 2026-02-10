import Foundation

// MARK: - RepoInfo

/// Inline repo descriptor — no separate type needed for a few fields.
struct RepoInfo: Codable, Sendable {
    let path: String
    let name: String
    let addedAt: Date
    var args: String?  // Per-repo CLI args (nil = use global only)

    init(path: String) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.addedAt = Date()
        self.args = nil
    }

    init(path: String, name: String, addedAt: Date, args: String? = nil) {
        self.path = path
        self.name = name
        self.addedAt = addedAt
        self.args = args
    }
}

// MARK: - TerminalSession

/// Observable session model. One per repo.
/// All state mutations must happen on MainActor.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id: UUID
    var repo: RepoInfo
    var state: SessionState = .idle

    /// Incremented on each restart to force SwiftUI view recreation.
    var restartCount: Int = 0

    /// Multi-consumer event continuations. Factory method `events()` creates new ones.
    /// All continuations are `finish()`-ed on session removal.
    var eventContinuations: [AsyncStream<SessionEvent>.Continuation] = []

    init(repo: RepoInfo, id: UUID = UUID()) {
        self.id = id
        self.repo = repo
    }

    /// Create a new AsyncStream for observing this session's events.
    /// Each call returns an independent stream (multi-consumer safe).
    func events() -> AsyncStream<SessionEvent> {
        AsyncStream<SessionEvent>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.eventContinuations.append(continuation)
        }
    }

    /// Emit an event to all active consumers.
    func emit(_ event: SessionEvent) {
        for continuation in eventContinuations {
            continuation.yield(event)
        }
    }

    /// Finish all continuations (call on session removal).
    func finishAllContinuations() {
        for continuation in eventContinuations {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    /// Snapshot for read-only access across boundaries.
    var snapshot: SessionSnapshot {
        SessionSnapshot(
            id: id,
            repoPath: repo.path,
            repoName: repo.name,
            state: state
        )
    }
}
