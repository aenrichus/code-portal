import Foundation
import Testing
@testable import CodePortal

@Suite("Session Lifecycle Tests")
struct SessionLifecycleTests {

    // MARK: - TerminalSession

    @Test("Session initializes with idle state")
    @MainActor
    func sessionStartsIdle() {
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test-repo"))
        #expect(session.state == .idle)
    }

    @Test("Session snapshot reflects current state")
    @MainActor
    func snapshotReflectsState() {
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test-repo"))
        let snap = session.snapshot
        #expect(snap.id == session.id)
        #expect(snap.state == .idle)
        #expect(snap.repoName == "test-repo")
        #expect(snap.repoPath == "/tmp/test-repo")
    }

    @Test("Session emits events to all consumers")
    @MainActor
    func multiConsumerEvents() async {
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        let stream1 = session.events()
        let stream2 = session.events()

        #expect(session.eventContinuations.count == 2)

        // Emit an event
        session.emit(.stateChanged(sessionId: session.id, newState: .running))

        // Both streams should receive it
        var iter1 = stream1.makeAsyncIterator()
        var iter2 = stream2.makeAsyncIterator()

        // Finish continuations to close streams
        session.finishAllContinuations()

        let event1 = await iter1.next()
        let event2 = await iter2.next()

        if case .stateChanged(let id1, let state1) = event1 {
            #expect(id1 == session.id)
            #expect(state1 == .running)
        } else {
            Issue.record("Expected stateChanged from stream1")
        }

        if case .stateChanged(let id2, let state2) = event2 {
            #expect(id2 == session.id)
            #expect(state2 == .running)
        } else {
            Issue.record("Expected stateChanged from stream2")
        }
    }

    @Test("finishAllContinuations clears the array")
    @MainActor
    func finishClearsContinuations() {
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        _ = session.events()
        _ = session.events()
        #expect(session.eventContinuations.count == 2)

        session.finishAllContinuations()
        #expect(session.eventContinuations.isEmpty)
    }

    // MARK: - RepoInfo

    @Test("RepoInfo extracts name from path")
    func repoInfoName() {
        let repo = RepoInfo(path: "/Users/dev/my-awesome-project")
        #expect(repo.name == "my-awesome-project")
    }

    @Test("RepoInfo preserves name in full init")
    func repoInfoFullInit() {
        let date = Date()
        let repo = RepoInfo(path: "/tmp/foo", name: "custom-name", addedAt: date)
        #expect(repo.name == "custom-name")
        #expect(repo.addedAt == date)
    }

    // MARK: - SessionState

    @Test("SessionState equality works correctly")
    func sessionStateEquality() {
        #expect(SessionState.idle == SessionState.idle)
        #expect(SessionState.running == SessionState.running)
        #expect(SessionState.attention == SessionState.attention)
        #expect(SessionState.idle != SessionState.running)
        #expect(SessionState.running != SessionState.attention)
        #expect(SessionState.idle != SessionState.attention)
    }

    // MARK: - SessionEvent

    @Test("SessionEvent stateChanged carries correct data")
    func eventStateChanged() {
        let id = UUID()
        let event = SessionEvent.stateChanged(sessionId: id, newState: .attention)
        if case .stateChanged(let eventId, let state) = event {
            #expect(eventId == id)
            #expect(state == .attention)
        } else {
            Issue.record("Expected stateChanged")
        }
    }

    @Test("SessionEvent attentionDetected carries pattern")
    func eventAttentionDetected() {
        let id = UUID()
        let event = SessionEvent.attentionDetected(sessionId: id, pattern: "Error: oops")
        if case .attentionDetected(let eventId, let pattern) = event {
            #expect(eventId == id)
            #expect(pattern == "Error: oops")
        } else {
            Issue.record("Expected attentionDetected")
        }
    }

    @Test("SessionEvent processExited carries exit code")
    func eventProcessExited() {
        let id = UUID()
        let event = SessionEvent.processExited(sessionId: id, exitCode: 42)
        if case .processExited(let eventId, let code) = event {
            #expect(eventId == id)
            #expect(code == 42)
        } else {
            Issue.record("Expected processExited")
        }
    }

    @Test("SessionEvent processExited nil exit code for signal")
    func eventProcessExitedNil() {
        let id = UUID()
        let event = SessionEvent.processExited(sessionId: id, exitCode: nil)
        if case .processExited(_, let code) = event {
            #expect(code == nil)
        } else {
            Issue.record("Expected processExited")
        }
    }

    // MARK: - SessionSnapshot

    @Test("SessionSnapshot is Identifiable")
    func snapshotIdentifiable() {
        let id = UUID()
        let snap = SessionSnapshot(id: id, repoPath: "/tmp/a", repoName: "a", state: .running)
        #expect(snap.id == id)
    }

    // MARK: - CallerContext

    @Test("CallerContext variants construct correctly")
    func callerContextVariants() {
        let ui = CallerContext.userInterface
        let url = CallerContext.urlScheme(sourceApp: "com.example.app")
        let xpc = CallerContext.xpc(auditToken: Data([1, 2, 3]))

        if case .userInterface = ui {} else { Issue.record("Expected userInterface") }
        if case .urlScheme(let app) = url {
            #expect(app == "com.example.app")
        } else {
            Issue.record("Expected urlScheme")
        }
        if case .xpc(let token) = xpc {
            #expect(token == Data([1, 2, 3]))
        } else {
            Issue.record("Expected xpc")
        }
    }

    // MARK: - State Machine Transitions

    @Test("State transitions: idle -> running -> attention -> running -> idle")
    @MainActor
    func stateTransitions() {
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        #expect(session.state == .idle)

        session.state = .running
        #expect(session.state == .running)

        session.state = .attention
        #expect(session.state == .attention)

        // Output resumes -> back to running
        session.state = .running
        #expect(session.state == .running)

        // Process exits -> idle
        session.state = .idle
        #expect(session.state == .idle)
    }

    @Test("Session emits processExited event")
    @MainActor
    func emitsProcessExited() async {
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        let stream = session.events()

        session.emit(.processExited(sessionId: session.id, exitCode: 0))
        session.finishAllContinuations()

        var iter = stream.makeAsyncIterator()
        let event = await iter.next()
        if case .processExited(let id, let code) = event {
            #expect(id == session.id)
            #expect(code == 0)
        } else {
            Issue.record("Expected processExited")
        }
    }

    // MARK: - SessionManager sendInput State Guards

    @Test("sendInput is silently ignored when session is idle")
    @MainActor
    func sendInputRejectedWhenIdle() {
        let manager = SessionManager()
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        manager.sessions.append(session)
        // Session is .idle — sendInput should silently return without crashing
        // (No PTY view exists, so it returns at state guard)
        manager.sendInput(sessionId: session.id, text: "hello", caller: .userInterface)
        #expect(session.state == .idle)  // State unchanged
    }

    @Test("sendInput is rejected for non-userInterface callers")
    @MainActor
    func sendInputRejectedForNonUI() {
        let manager = SessionManager()
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        session.state = .running
        manager.sessions.append(session)
        // URL scheme callers rejected in v1
        manager.sendInput(sessionId: session.id, text: "hello", caller: .urlScheme(sourceApp: "evil"))
        // Should not crash — state guard rejects silently
        #expect(session.state == .running)
    }

    @Test("sendInput is rejected for unknown session ID")
    @MainActor
    func sendInputRejectedForUnknownId() {
        let manager = SessionManager()
        // No sessions exist — should silently return
        manager.sendInput(sessionId: UUID(), text: "hello", caller: .userInterface)
    }

    // MARK: - SessionManager Session Management

    @Test("listSessions returns snapshots of all sessions")
    @MainActor
    func listSessionsReturnsSnapshots() {
        let manager = SessionManager()
        // Clear any persisted sessions loaded from disk
        manager.sessions.removeAll()
        manager.terminalViewPool.removeAll()

        let s1 = TerminalSession(repo: RepoInfo(path: "/tmp/a"))
        let s2 = TerminalSession(repo: RepoInfo(path: "/tmp/b"))
        s2.state = .running
        manager.sessions.append(s1)
        manager.sessions.append(s2)

        let snapshots = manager.listSessions()
        #expect(snapshots.count == 2)
        #expect(snapshots[0].repoName == "a")
        #expect(snapshots[0].state == .idle)
        #expect(snapshots[1].repoName == "b")
        #expect(snapshots[1].state == .running)
    }

    @Test("sessionState returns correct state for known ID")
    @MainActor
    func sessionStateKnownId() {
        let manager = SessionManager()
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        session.state = .attention
        manager.sessions.append(session)

        #expect(manager.sessionState(id: session.id) == .attention)
    }

    @Test("sessionState returns nil for unknown ID")
    @MainActor
    func sessionStateUnknownId() {
        let manager = SessionManager()
        #expect(manager.sessionState(id: UUID()) == nil)
    }

    // MARK: - Navigation

    @Test("selectNextSession wraps around")
    @MainActor
    func selectNextWraps() {
        let manager = SessionManager()
        let s1 = TerminalSession(repo: RepoInfo(path: "/tmp/a"))
        let s2 = TerminalSession(repo: RepoInfo(path: "/tmp/b"))
        let s3 = TerminalSession(repo: RepoInfo(path: "/tmp/c"))
        manager.sessions = [s1, s2, s3]
        manager.selectedSessionId = s3.id

        manager.selectNextSession()
        #expect(manager.selectedSessionId == s1.id)  // wrapped
    }

    @Test("selectPreviousSession wraps around")
    @MainActor
    func selectPreviousWraps() {
        let manager = SessionManager()
        let s1 = TerminalSession(repo: RepoInfo(path: "/tmp/a"))
        let s2 = TerminalSession(repo: RepoInfo(path: "/tmp/b"))
        manager.sessions = [s1, s2]
        manager.selectedSessionId = s1.id

        manager.selectPreviousSession()
        #expect(manager.selectedSessionId == s2.id)  // wrapped
    }

    @Test("selectedRepoName returns name of selected session")
    @MainActor
    func selectedRepoNameWorks() {
        let manager = SessionManager()
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/my-project"))
        manager.sessions.append(session)
        manager.selectedSessionId = session.id
        #expect(manager.selectedRepoName == "my-project")
    }

    @Test("selectedRepoName returns nil when nothing selected")
    @MainActor
    func selectedRepoNameNil() {
        let manager = SessionManager()
        // Clear persisted sessions and selection
        manager.sessions.removeAll()
        manager.selectedSessionId = nil
        #expect(manager.selectedRepoName == nil)
    }

    // MARK: - Attention Counter

    @Test("handleSessionStateChange updates attention count")
    @MainActor
    func attentionCountTracking() {
        let manager = SessionManager()
        let session = TerminalSession(repo: RepoInfo(path: "/tmp/test"))
        manager.sessions.append(session)

        // running -> attention: count increments
        manager.handleSessionStateChange(session: session, oldState: .running, newState: .attention)
        #expect(manager.attentionCount == 1)

        // attention -> running: count decrements
        manager.handleSessionStateChange(session: session, oldState: .attention, newState: .running)
        #expect(manager.attentionCount == 0)

        // Count never goes below 0
        manager.handleSessionStateChange(session: session, oldState: .attention, newState: .idle)
        #expect(manager.attentionCount == 0)
    }

    // MARK: - Claude CLI Resolution

    @Test("resolveClaudePathStatic finds claude or returns default")
    @MainActor
    func claudePathResolution() {
        let path = SessionManager.resolveClaudePathStatic()
        // Should either find a real path or return the fallback
        #expect(!path.isEmpty)
        #expect(path.hasSuffix("claude"))
    }

    // MARK: - RepoInfo Codable

    @Test("RepoInfo round-trips through JSON encoding/decoding")
    func repoInfoCodable() throws {
        let original = RepoInfo(path: "/tmp/my-project", name: "my-project", addedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RepoInfo.self, from: data)

        #expect(decoded.path == original.path)
        #expect(decoded.name == original.name)
        // Date comparison with some tolerance (ISO8601 drops sub-second precision)
        #expect(abs(decoded.addedAt.timeIntervalSince(original.addedAt)) < 1.0)
    }
}
