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
}
