import Foundation

// MARK: - CallerContext

/// Identifies the origin of a mutating operation for security auditing.
/// In v1, only `.userInterface` is accepted. Future callers (URL scheme, XPC)
/// get their own variants for per-caller authorization decisions.
enum CallerContext: Sendable {
    case userInterface
    case urlScheme(sourceApp: String?)
    case xpc(auditToken: Data)
}

// MARK: - SessionState

/// Three visual states matching sidebar indicators:
/// gray dot (idle), green dot (running), orange dot (attention).
enum SessionState: Sendable, Equatable {
    case idle
    case running
    case attention
}

// MARK: - SessionEvent

/// Events emitted by sessions for external observation.
/// Multi-consumer safe via factory method on the protocol.
enum SessionEvent: Sendable {
    case stateChanged(sessionId: UUID, newState: SessionState)
    case attentionDetected(sessionId: UUID, pattern: String)
    case processExited(sessionId: UUID, exitCode: Int32?)
}

// MARK: - SessionSnapshot

/// Read-only snapshot of a session's current state, safe to pass across boundaries.
struct SessionSnapshot: Sendable, Identifiable {
    let id: UUID
    let repoPath: String
    let repoName: String
    let state: SessionState
}

// MARK: - SessionControlling Protocol

/// All session operations behind a protocol seam. SwiftUI views call through this.
/// Future XPC/URL scheme/AppleScript callers use the same interface.
/// `CallerContext` is required on all mutating methods for security boundary enforcement.
@MainActor
protocol SessionControlling: AnyObject {
    func addRepo(path: String, caller: CallerContext) throws
    func removeRepo(id: UUID, caller: CallerContext)
    func restartSession(id: UUID, caller: CallerContext)
    func sendInput(sessionId: UUID, text: String, caller: CallerContext)
    func listSessions() -> [SessionSnapshot]
    func sessionState(id: UUID) -> SessionState?
    func events() -> AsyncStream<SessionEvent>
}
