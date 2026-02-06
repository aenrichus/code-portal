import SwiftUI
import UserNotifications

/// Main app entry point.
///
/// CRITICAL: `@State var sessionManager` must live here (not in a child view).
/// SwiftUI re-evaluates `@State` initializers on every view rebuild — only the App struct is immune.
@main
struct CodePortalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView(sessionManager: sessionManager)
                .frame(minWidth: 700, minHeight: 500)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                    sessionManager.requestNotificationPermission()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project...") {
                    addRepoViaOpenPanel()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
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
                let alert = NSAlert()
                alert.messageText = "Could not add project"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

// MARK: - AppDelegate

/// Handles app lifecycle, notification delegate, and URL scheme events.
/// Must set UNUserNotificationCenter delegate before applicationDidFinishLaunching.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by CodePortalApp.onAppear. Used for notification tap handling.
    var sessionManager: SessionManager?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set notification delegate early (must be before applicationDidFinishLaunching)
        UNUserNotificationCenter.current().delegate = self

        // Register for URL scheme events
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            sessionManager?.isAppFocused = true
            // Clear dock badge when app is activated
            sessionManager?.attentionCount = sessionManager?.sessions.filter { $0.state == .attention }.count ?? 0
            sessionManager?.updateDockBadge()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { @MainActor in
            sessionManager?.isAppFocused = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sm = sessionManager else { return .terminateNow }

        let hasActiveSessions = sm.sessions.contains { $0.state != .idle }
        if hasActiveSessions {
            let alert = NSAlert()
            alert.messageText = "Quit Code Portal?"
            alert.informativeText = "Active Claude Code sessions will be terminated."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }

        sm.terminateAllSessions()
        return .terminateNow
    }

    // MARK: - URL Scheme Handler (no-op in v1)

    /// Registered `codeportal://` URL scheme with explicit no-op handler.
    /// Logs source app and drops all invocations in v1.
    /// Handlers with user confirmation added in v1.1.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }

        // Log the source app for audit trail
        let sourceApp = event.attributeDescriptor(forKeyword: keyAddressAttr)?.stringValue ?? "unknown"
        NSLog("[CodePortal] URL scheme invocation dropped (no-op in v1): url=%@ source=%@", urlString, sourceApp)

        // No-op: all invocations are dropped in v1
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show notifications even when app is in foreground (but our logic suppresses focused+selected).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Handle notification tap: activate window, navigate to session.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionIdString = userInfo["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdString) else { return }

        // Capture reference before crossing isolation boundary
        let sm = sessionManager
        await MainActor.run {
            // Navigate to the session
            sm?.selectedSessionId = sessionId
            // Bring app to front
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
