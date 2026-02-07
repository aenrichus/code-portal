import Foundation
import Testing
@testable import CodePortal

// Pattern matching + ANSI stripping tests will be added in Phase 2.
// For now, verify the module compiles and basic types are accessible.

@Suite("MonitoredTerminalView Tests")
struct MonitoredTerminalViewTests {

    @Test("SessionState has 3 cases")
    func sessionStateValues() {
        let idle = SessionState.idle
        let running = SessionState.running
        let attention = SessionState.attention

        #expect(idle != running)
        #expect(running != attention)
    }

    @Test("SessionEvent carries session ID")
    func sessionEventCreation() {
        let id = UUID()
        let event = SessionEvent.stateChanged(sessionId: id, newState: .running)

        if case .stateChanged(let eventId, let state) = event {
            #expect(eventId == id)
            #expect(state == .running)
        } else {
            Issue.record("Expected stateChanged event")
        }
    }
}
