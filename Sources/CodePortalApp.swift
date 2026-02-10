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
    @AppStorage("appearance") private var appearance: String = "auto"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil  // nil = follow system
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(sessionManager: sessionManager)
                .frame(minWidth: 700, minHeight: 500)
                .navigationTitle("Code Portal")
                .preferredColorScheme(colorScheme)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                    sessionManager.requestNotificationPermission()
                    sessionManager.validateClaudeCLI()
                    sessionManager.updateTerminalThemes()
                }
                .onChange(of: appearance) { _, _ in
                    sessionManager.updateTerminalThemes()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Code Portal") {
                    showAboutWindow()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Add Project...") {
                    addRepoViaOpenPanel()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Close Project") {
                    sessionManager.removeSelectedWithConfirmation()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(sessionManager.selectedSessionId == nil)

                Divider()

                Button("Next Project") {
                    sessionManager.selectNextSession()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(sessionManager.sessions.count < 2)

                Button("Previous Project") {
                    sessionManager.selectPreviousSession()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(sessionManager.sessions.count < 2)
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle File Browser") {
                    let current = UserDefaults.standard.bool(forKey: "showFileTree")
                    UserDefaults.standard.set(!current, forKey: "showFileTree")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func showAboutWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Code Portal"
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // App icon
        let iconView = NSImageView(frame: NSRect(x: 118, y: 110, width: 64, height: 64))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "Code Portal")
        nameLabel.frame = NSRect(x: 0, y: 82, width: 300, height: 24)
        nameLabel.alignment = .center
        nameLabel.font = .boldSystemFont(ofSize: 16)
        contentView.addSubview(nameLabel)

        // Version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.frame = NSRect(x: 0, y: 60, width: 300, height: 18)
        versionLabel.alignment = .center
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        contentView.addSubview(versionLabel)

        // Attribution — "Built by" prefix + clickable name (centered)
        let builtByPrefix = "Built by "
        let authorName = "Henry Wolf VII"
        let fullText = builtByPrefix + authorName
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributedString = NSMutableAttributedString(
            string: fullText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let nameRange = NSRange(location: builtByPrefix.count, length: authorName.count)
        attributedString.addAttributes([
            .link: URL(string: "https://github.com/aenrichus")!,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ], range: nameRange)

        let attributionField = NSTextField(labelWithAttributedString: attributedString)
        attributionField.isSelectable = true  // Required for clickable links
        attributionField.allowsEditingTextAttributes = true
        attributionField.frame = NSRect(x: 0, y: 28, width: 300, height: 20)
        contentView.addSubview(attributionField)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // UNUserNotificationCenter requires a valid bundle identifier.
        // `swift run` launches a bare executable without one — guard to prevent crash.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        // Register for URL scheme events
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app and bring its window to the front.
        // Critical when launched via `swift run` — without this the terminal
        // that spawned the process retains keyboard focus.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            sessionManager?.isAppFocused = true
            // Clear dock badge when app is activated
            sessionManager?.attentionCount = sessionManager?.sessions.filter { $0.state == .attention }.count ?? 0
            sessionManager?.updateDockBadge()
            // Re-apply terminal themes in case system appearance changed while inactive
            sessionManager?.updateTerminalThemes()
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
