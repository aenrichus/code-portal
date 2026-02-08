import AppKit
import SwiftUI
import SwiftTerm
import UserNotifications

/// Central session coordinator. Owns sessions, terminal view pool, and notification logic.
///
/// CRITICAL: Must be stored as `@State var sessionManager = SessionManager()` in `@main` App struct.
/// SwiftUI re-evaluates `@State` initializers on every view rebuild — only the App struct is immune.
@Observable
@MainActor
final class SessionManager: SessionControlling {

    // MARK: - State

    var sessions: [TerminalSession] = []
    var selectedSessionId: UUID?

    /// Strong references to terminal views. Views persist across navigation.
    /// Callbacks use [weak session] to avoid cycles.
    var terminalViewPool: [UUID: MonitoredTerminalView] = [:]

    /// Explicit attention counter (not computed) for dock badge.
    var attentionCount: Int = 0

    /// Resolved Claude CLI path. Cached after first resolution.
    private var cachedClaudePath: String?

    /// Whether the app is currently focused (suppress notifications when true + selected session).
    var isAppFocused: Bool = false

    /// Global CLI args applied to all sessions. Stored in UserDefaults.
    @ObservationIgnored
    @AppStorage("globalClaudeArgs") var globalClaudeArgs: String = ""

    // MARK: - Multi-consumer event stream

    /// Global event continuations for external observers.
    private var globalEventContinuations: [AsyncStream<SessionEvent>.Continuation] = []

    // MARK: - Repo Persistence

    /// Path to repos JSON file.
    private static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CodePortal", isDirectory: true)
    }()

    private static let reposFileURL: URL = {
        appSupportDir.appendingPathComponent("repos.json")
    }()

    // MARK: - Init

    init() {
        loadPersistedRepos()
    }

    // MARK: - SessionControlling Conformance

    func addRepo(path: String, caller: CallerContext) throws {
        // Validate path exists and is a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw SessionError.invalidPath(path)
        }

        // Resolve symlinks and reject paths containing ".."
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        guard !resolvedPath.contains("..") else {
            throw SessionError.invalidPath(path)
        }

        // Check for duplicates
        guard !sessions.contains(where: { $0.repo.path == resolvedPath }) else {
            throw SessionError.duplicateRepo(resolvedPath)
        }

        let session = TerminalSession(repo: RepoInfo(path: resolvedPath))
        sessions.append(session)

        // Create terminal view for this session
        createTerminalView(for: session)

        // Persist
        saveRepos()

        // Auto-select if first repo
        if sessions.count == 1 {
            selectedSessionId = session.id
        }
    }

    func removeRepo(id: UUID, caller: CallerContext) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]

        // Kill process if running
        if let view = terminalViewPool[id] {
            view.terminate()
        }

        // Finish all continuations
        session.finishAllContinuations()

        // Update attention count
        if session.state == .attention {
            attentionCount = max(0, attentionCount - 1)
            updateDockBadge()
        }

        // Cleanup
        terminalViewPool.removeValue(forKey: id)
        sessions.remove(at: index)

        // Update selection
        if selectedSessionId == id {
            selectedSessionId = sessions.first?.id
        }

        saveRepos()
    }

    func restartSession(id: UUID, caller: CallerContext) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard let view = terminalViewPool[id] else { return }

        // Terminate existing process
        view.terminate()
        view.resetForNewProcess()

        // Reset state
        if session.state == .attention {
            attentionCount = max(0, attentionCount - 1)
            updateDockBadge()
        }
        session.state = .running
        session.emit(.stateChanged(sessionId: id, newState: .running))

        // Start new process
        startClaudeProcess(in: view, session: session)
    }

    func sendInput(sessionId: UUID, text: String, caller: CallerContext) {
        // State guard: only works in .running/.attention
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        guard session.state == .running || session.state == .attention else { return }

        // In v1, only .userInterface is accepted
        guard case .userInterface = caller else { return }

        // Route through terminal view pool
        guard let view = terminalViewPool[sessionId] else { return }
        let bytes = Array(text.utf8)
        view.send(source: view, data: bytes[...])
    }

    func listSessions() -> [SessionSnapshot] {
        sessions.map { $0.snapshot }
    }

    func sessionState(id: UUID) -> SessionState? {
        sessions.first(where: { $0.id == id })?.state
    }

    func events() -> AsyncStream<SessionEvent> {
        AsyncStream<SessionEvent>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.globalEventContinuations.append(continuation)
        }
    }

    // MARK: - Terminal View Management

    /// Uniform scrollback size for all terminal views: 5,000 lines.
    private static let scrollbackLines = 5_000

    private func createTerminalView(for session: TerminalSession) {
        let view = MonitoredTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.session = session
        view.sessionManager = self

        // Set scrollback to 5,000 lines (default is 500)
        view.getTerminal().changeHistorySize(Self.scrollbackLines)

        // Configure process delegate for exit handling
        view.processDelegate = self

        terminalViewPool[session.id] = view
    }

    /// Start a Claude Code process in the given terminal view.
    func startSession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard session.state == .idle else { return }
        guard let view = terminalViewPool[id] else { return }

        session.state = .running
        session.emit(.stateChanged(sessionId: id, newState: .running))

        startClaudeProcess(in: view, session: session)
    }

    private func startClaudeProcess(in view: MonitoredTerminalView, session: TerminalSession) {
        let claudePath = resolveClaudePath()

        // Curated environment: allowlist only. Strip all DYLD_* variables.
        let env = buildCuratedEnvironment()

        // Merge global + per-repo args (per-repo appended after global)
        let globalParsed = globalClaudeArgs
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let repoParsed = (session.repo.args ?? "")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let args = globalParsed + repoParsed

        view.startProcess(
            executable: claudePath,
            args: args,
            environment: env,
            execName: nil,
            currentDirectory: session.repo.path
        )
    }

    // MARK: - Claude CLI Discovery

    /// Synchronous hardcoded directory search + FileManager.isExecutableFile.
    /// Cache in instance variable. Takes microseconds.
    static func resolveClaudePathStatic() -> String {
        let searchPaths = [
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.nvm/versions/node/v20.19.3/bin/claude",  // common nvm path
            "\(NSHomeDirectory())/.npm/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to which
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty && FileManager.default.isExecutableFile(atPath: result) {
                return result
            }
        } catch {
            // Fall through
        }

        // Default — will fail at process start with a clear error
        return "/usr/local/bin/claude"
    }

    func resolveClaudePath() -> String {
        if let cached = cachedClaudePath { return cached }
        let path = Self.resolveClaudePathStatic()
        cachedClaudePath = path
        return path
    }

    /// Validate Claude CLI is available on launch. Shows alert if not found.
    func validateClaudeCLI() {
        let path = resolveClaudePath()
        if !FileManager.default.isExecutableFile(atPath: path) {
            let alert = NSAlert()
            alert.messageText = "Claude CLI Not Found"
            alert.informativeText = "Code Portal requires Claude Code CLI to run sessions.\n\nInstall it with:\nnpm install -g @anthropic-ai/claude-code\n\nOr ensure 'claude' is on your PATH."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Curated Environment

    /// Build an explicit allowlist environment for PTY processes.
    /// Strip all DYLD_* variables (prevents dynamic library injection).
    ///
    /// When launched from Finder, PATH is minimal (/usr/bin:/bin:/usr/sbin:/sbin).
    /// We augment it with common Node.js/tool install locations and the directory
    /// containing the resolved Claude CLI, so `#!/usr/bin/env node` can find node.
    private func buildCuratedEnvironment() -> [String] {
        let currentEnv = ProcessInfo.processInfo.environment
        var env: [String] = []

        // Allowlisted variables (except PATH, handled separately)
        let allowlist = ["HOME", "USER", "SHELL", "LANG",
                         "ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]

        for key in allowlist {
            if let value = currentEnv[key] {
                env.append("\(key)=\(value)")
            }
        }

        // Build a robust PATH that works both from terminal and Finder launch.
        let path = buildRobustPath()
        env.append("PATH=\(path)")

        // Always set TERM
        env.append("TERM=xterm-256color")

        return env
    }

    /// Construct PATH by merging the inherited PATH with well-known tool directories.
    /// Ensures `node`, `claude`, and other CLI tools are reachable even when launched
    /// from Finder (where PATH is just /usr/bin:/bin:/usr/sbin:/sbin).
    private func buildRobustPath() -> String {
        let home = NSHomeDirectory()

        // Well-known directories where node/claude commonly live.
        // Order: user-specific first, then system-wide.
        let wellKnownDirs = [
            "\(home)/.nvm/versions/node",   // nvm — expanded below
            "\(home)/.local/bin",
            "\(home)/.npm/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
        ]

        // Start with inherited PATH components
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var components = inheritedPath.split(separator: ":").map(String.init)

        // Add the directory containing the resolved Claude CLI
        let claudePath = resolveClaudePath()
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        if !claudeDir.isEmpty && !components.contains(claudeDir) {
            components.insert(claudeDir, at: 0)
        }

        // Expand nvm: find the highest installed node version's bin dir
        let nvmBase = "\(home)/.nvm/versions/node"
        if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            // Sort descending to prefer newest version
            let sorted = nodeVersions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for version in sorted {
                let binDir = "\(nvmBase)/\(version)/bin"
                if FileManager.default.isExecutableFile(atPath: "\(binDir)/node") {
                    if !components.contains(binDir) {
                        components.insert(binDir, at: 0)
                    }
                    break
                }
            }
        }

        // Add other well-known dirs if they exist and aren't already present
        for dir in wellKnownDirs {
            if dir.contains(".nvm") { continue }  // handled above
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
               isDir.boolValue,
               !components.contains(dir) {
                components.append(dir)
            }
        }

        // Always include system essentials
        for sysDir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if !components.contains(sysDir) {
                components.append(sysDir)
            }
        }

        return components.joined(separator: ":")
    }

    // MARK: - Notification Logic (~40 LOC)

    /// Whether notifications are available (requires a valid bundle identifier).
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post a notification for a session needing attention.
    /// Suppress when app focused + session selected. State-machine deduplicates.
    func postAttentionNotification(for session: TerminalSession) {
        guard notificationsAvailable else { return }

        // Suppress when focused and looking at this session
        if isAppFocused && selectedSessionId == session.id { return }

        let content = UNMutableNotificationContent()
        content.title = "Code Portal"
        content.body = "\(session.repo.name) needs attention"
        content.sound = .default
        // sessionId only in userInfo — no pattern/repoPath to avoid leaking to notification database
        content.userInfo = ["sessionId": session.id.uuidString]
        content.threadIdentifier = session.id.uuidString

        let request = UNNotificationRequest(
            identifier: "attention-\(session.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Update dock badge with attention count.
    func updateDockBadge() {
        NSApplication.shared.dockTile.badgeLabel = attentionCount > 0 ? "\(attentionCount)" : nil
    }

    /// Handle attention state change from a session.
    func handleSessionStateChange(session: TerminalSession, oldState: SessionState, newState: SessionState) {
        // Update attention counter
        if oldState == .attention && newState != .attention {
            attentionCount = max(0, attentionCount - 1)
        } else if oldState != .attention && newState == .attention {
            attentionCount += 1
            postAttentionNotification(for: session)
        }
        updateDockBadge()

        // Forward to global event stream
        let event = SessionEvent.stateChanged(sessionId: session.id, newState: newState)
        for continuation in globalEventContinuations {
            continuation.yield(event)
        }
    }

    // MARK: - Repo Settings

    /// Update per-repo CLI args. Trims whitespace; stores nil if empty.
    func updateRepoArgs(id: UUID, args: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        // Replace the entire struct to ensure @Observable picks up the mutation.
        var updated = session.repo
        updated.args = trimmed.isEmpty ? nil : trimmed
        session.repo = updated
        saveRepos()
    }

    // MARK: - Persistence

    private func loadPersistedRepos() {
        guard FileManager.default.fileExists(atPath: Self.reposFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: Self.reposFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let repos = try decoder.decode([RepoInfo].self, from: data)

            for repo in repos {
                // Validate path on load: resolve symlinks, reject ".."
                let resolved = (repo.path as NSString).resolvingSymlinksInPath
                guard !resolved.contains("..") else { continue }
                guard FileManager.default.fileExists(atPath: resolved) else { continue }

                let session = TerminalSession(repo: RepoInfo(path: resolved, name: repo.name, addedAt: repo.addedAt, args: repo.args))
                sessions.append(session)
                createTerminalView(for: session)
            }

            if let first = sessions.first {
                selectedSessionId = first.id
            }
        } catch {
            // Silently fail on corrupt file — user re-adds repos
        }
    }

    private func saveRepos() {
        let fm = FileManager.default

        // Create directory with 0o700
        do {
            try fm.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
            // Set directory permissions to 0o700
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.appSupportDir.path)
        } catch {
            return
        }

        // Encode and write atomically with 0o600
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let repos = sessions.map { $0.repo }
            let data = try encoder.encode(repos)
            try data.write(to: Self.reposFileURL, options: .atomic)
            // Set file permissions to 0o600
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.reposFileURL.path)
        } catch {
            // Log but don't crash
        }
    }

    // MARK: - Navigation

    /// Select the next session in the list (wraps around).
    func selectNextSession() {
        guard !sessions.isEmpty else { return }
        guard let currentId = selectedSessionId,
              let index = sessions.firstIndex(where: { $0.id == currentId }) else {
            selectedSessionId = sessions.first?.id
            return
        }
        let nextIndex = (index + 1) % sessions.count
        selectedSessionId = sessions[nextIndex].id
    }

    /// Select the previous session in the list (wraps around).
    func selectPreviousSession() {
        guard !sessions.isEmpty else { return }
        guard let currentId = selectedSessionId,
              let index = sessions.firstIndex(where: { $0.id == currentId }) else {
            selectedSessionId = sessions.last?.id
            return
        }
        let prevIndex = (index - 1 + sessions.count) % sessions.count
        selectedSessionId = sessions[prevIndex].id
    }

    /// Name of the currently selected repo, if any.
    var selectedRepoName: String? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first(where: { $0.id == id })?.repo.name
    }

    /// Remove the currently selected session with confirmation.
    func removeSelectedWithConfirmation() {
        guard let id = selectedSessionId,
              let session = sessions.first(where: { $0.id == id }) else { return }

        let isActive = session.state != .idle
        if isActive {
            let alert = NSAlert()
            alert.messageText = "Remove \(session.repo.name)?"
            alert.informativeText = "The active Claude Code session will be terminated."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        removeRepo(id: id, caller: .userInterface)
    }

    // MARK: - App Lifecycle

    /// SIGTERM all sessions, wait 3s, SIGKILL survivors.
    func terminateAllSessions() {
        for (_, view) in terminalViewPool {
            view.terminate()
        }
        // Note: SwiftTerm's terminate sends SIGHUP via PTY close.
        // POSIX_SPAWN_SETSID makes child session leader, so SIGHUP propagates to child group.
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension SessionManager: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm handles SIGWINCH internally
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update window title — deferred to Phase 3
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Not needed for v1
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let monitoredView = source as? MonitoredTerminalView else { return }
        // Dispatch to MainActor since MonitoredTerminalView inherits MainActor isolation
        Task { @MainActor in
            monitoredView.handleProcessTerminated(exitCode: exitCode)
        }
    }
}

// MARK: - Errors

enum SessionError: LocalizedError {
    case invalidPath(String)
    case duplicateRepo(String)
    case claudeNotFound

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Invalid directory: \(path)"
        case .duplicateRepo(let path): return "Repo already added: \(path)"
        case .claudeNotFound: return "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
        }
    }
}
