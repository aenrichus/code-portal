import Foundation

// MARK: - Model Types

enum FileChangeStatus: Sendable {
    case modified, added, deleted, renamed(from: String), untracked
}

struct FileChange: Sendable, Identifiable {
    let path: String
    let oldPath: String?
    let status: FileChangeStatus
    let isStaged: Bool
    let isBinary: Bool

    /// Unique across staged/unstaged sections (same file can appear in both when partially staged).
    var id: String { "\(isStaged ? "s" : "u"):\(path)" }
}

struct DiffHunk: Sendable {
    let header: String      // @@ -a,b +c,d @@ optional context
    let lines: [DiffLine]
}

struct DiffLine: Sendable {
    enum Kind: Sendable { case context, addition, deletion, noNewline }
    let kind: Kind
    let text: String        // display text (prefix stripped)
    let rawText: String     // original line including +/-/space prefix (for v2 patch extraction)
}

struct FileDiff: Sendable {
    let path: String
    let isBinary: Bool
    let hunks: [DiffHunk]
}

struct GitStatus: Sendable {
    let branch: String?
    let staged: [FileChange]
    let unstaged: [FileChange]
    let isGitRepo: Bool

    static let empty = GitStatus(branch: nil, staged: [], unstaged: [], isGitRepo: false)
}

// MARK: - GitService

/// Process-based git command execution with observable state.
/// Matches existing codebase pattern: @Observable @MainActor final class (like SessionManager).
/// Views bind directly to `status` — no ViewModel layer.
@Observable
@MainActor
final class GitService {

    // MARK: - Observable State

    private(set) var status: GitStatus = .empty
    private(set) var isBusy: Bool = false
    var currentError: String?

    // MARK: - Private

    private let repoPath: String
    private var cachedGitPath: String?
    private var lastStatusOutput: String = ""

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    // MARK: - Public Operations

    /// Refresh git status. Skips UI update if output is identical to last poll.
    func refreshStatus() async {
        do {
            let result = try await run([
                "-c", "core.quotePath=false",
                "status", "--porcelain=v2", "--branch", "-z"
            ])

            guard result.exitCode == 0 else {
                // Not a git repo or git error
                if result.stderr.contains("not a git repository") {
                    status = GitStatus(branch: nil, staged: [], unstaged: [], isGitRepo: false)
                    currentError = nil
                } else {
                    currentError = result.stderr
                }
                return
            }

            // Skip UI update if unchanged
            guard result.stdout != lastStatusOutput else { return }
            lastStatusOutput = result.stdout

            status = parseStatus(result.stdout)
            currentError = nil
        } catch {
            // Git not found or process error
            if status.isGitRepo {
                currentError = error.localizedDescription
            }
        }
    }

    /// Load diff for a specific file. Returns nil if no diff available.
    func diffForFile(_ path: String, staged: Bool) async -> FileDiff? {
        var args = ["-c", "core.quotePath=false",
                    "diff", "--no-ext-diff", "--no-color"]
        if staged { args.append("--cached") }
        args += ["--", path]

        do {
            let result = try await run(args)
            guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
            let diffs = parseDiff(result.stdout)
            return diffs.first
        } catch {
            return nil
        }
    }

    /// Stage a file. Covers both tracked and untracked (git add handles both).
    func stageFile(_ path: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await run(["add", "--", path])
            if result.exitCode != 0 { currentError = result.stderr }
            else { currentError = nil }
            await refreshStatus()
        } catch {
            currentError = error.localizedDescription
        }
    }

    /// Unstage a file.
    func unstageFile(_ path: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await run(["restore", "--staged", "--", path])
            if result.exitCode != 0 { currentError = result.stderr }
            else { currentError = nil }
            await refreshStatus()
        } catch {
            currentError = error.localizedDescription
        }
    }

    /// Stage all changes.
    func stageAll() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await run(["add", "-A"])
            if result.exitCode != 0 { currentError = result.stderr }
            else { currentError = nil }
            await refreshStatus()
        } catch {
            currentError = error.localizedDescription
        }
    }

    /// Unstage all changes.
    func unstageAll() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await run(["restore", "--staged", "--", "."])
            if result.exitCode != 0 { currentError = result.stderr }
            else { currentError = nil }
            await refreshStatus()
        } catch {
            currentError = error.localizedDescription
        }
    }

    /// Revert a file. For untracked files, moves to Trash (security: trashItem not removeItem).
    /// Throws because this is destructive — caller should confirm with user first.
    func revertFile(_ path: String, isUntracked: Bool) async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        if isUntracked {
            // Move to Trash instead of permanent deletion
            let fullPath = (repoPath as NSString).appendingPathComponent(path)
            let url = URL(fileURLWithPath: fullPath)

            // Security: validate path stays within repo
            let resolved = url.resolvingSymlinksInPath()
            let repoURL = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath()
            guard resolved.pathComponents.starts(with: repoURL.pathComponents) else {
                throw GitServiceError.pathOutsideRepo(path)
            }

            // lstat to detect symlinks
            var stat = stat()
            guard lstat(resolved.path, &stat) == 0 else {
                throw GitServiceError.fileNotFound(path)
            }

            try FileManager.default.trashItem(at: resolved, resultingItemURL: nil)
        } else {
            let result = try await run(["restore", "--", path])
            if result.exitCode != 0 {
                throw GitServiceError.gitError(result.stderr)
            }
        }

        currentError = nil
        await refreshStatus()
    }

    /// Create a commit with the given message.
    func commit(message: String) async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let result = try await run(["commit", "-m", message])
        if result.exitCode != 0 {
            let errorOutput = result.stderr.isEmpty ? result.stdout : result.stderr
            throw GitServiceError.gitError(errorOutput)
        }

        currentError = nil
        lastStatusOutput = ""  // Force full refresh after commit
        await refreshStatus()
    }

    // MARK: - Process Execution

    /// Run a git command and return stdout/stderr/exitCode.
    /// Uses terminationHandler + CheckedContinuation (not waitUntilExit which blocks thread pool).
    private func run(_ args: [String], input: String? = nil) async throws
        -> (stdout: String, stderr: String, exitCode: Int32)
    {
        let gitPath = resolveGitPath()
        let repoPath = self.repoPath
        let env = buildGitEnvironment()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if let input {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                stdinPipe.fileHandleForWriting.write(Data(input.utf8))
                stdinPipe.fileHandleForWriting.closeFile()
            }

            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(decoding: stdoutData, as: UTF8.self)
                let stderr = String(decoding: stderrData, as: UTF8.self)
                continuation.resume(returning: (stdout: stdout, stderr: stderr, exitCode: process.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Git Path Resolution

    /// Find git executable. Duplicates SessionManager pattern (small function, not shared abstraction).
    private func resolveGitPath() -> String {
        if let cached = cachedGitPath { return cached }

        let searchPaths = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "\(NSHomeDirectory())/.local/bin/git",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedGitPath = path
                return path
            }
        }

        // Fallback — will produce a clear error at process launch
        let fallback = "/usr/bin/git"
        cachedGitPath = fallback
        return fallback
    }

    /// Build curated environment for git processes.
    private func buildGitEnvironment() -> [String: String] {
        let currentEnv = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]

        let allowlist = [
            "HOME", "USER", "SHELL", "LANG",
            "SSH_AUTH_SOCK",
            "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
            "GPG_TTY",
        ]

        for key in allowlist {
            if let value = currentEnv[key] {
                env[key] = value
            }
        }

        // Build PATH with common tool locations
        let home = NSHomeDirectory()
        var pathComponents = (currentEnv["PATH"] ?? "").split(separator: ":").map(String.init)
        let extraDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
        ]
        for dir in extraDirs {
            if !pathComponents.contains(dir) {
                pathComponents.append(dir)
            }
        }
        for sysDir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if !pathComponents.contains(sysDir) {
                pathComponents.append(sysDir)
            }
        }
        env["PATH"] = pathComponents.joined(separator: ":")

        return env
    }

    // MARK: - Status Parsing

    /// Parse `git status --porcelain=v2 --branch -z` output.
    /// NUL-separated entries. Branch info prefixed with `#`.
    func parseStatus(_ raw: String) -> GitStatus {
        var branch: String?
        var staged: [FileChange] = []
        var unstaged: [FileChange] = []

        // Split on NUL. Last element may be empty.
        let entries = raw.split(separator: "\0", omittingEmptySubsequences: false)

        var i = 0
        while i < entries.count {
            let entry = String(entries[i])

            if entry.hasPrefix("# branch.head ") {
                let value = String(entry.dropFirst("# branch.head ".count))
                branch = (value == "(detached)") ? nil : value
                i += 1
                continue
            }

            // Skip other branch info lines
            if entry.hasPrefix("#") {
                i += 1
                continue
            }

            // Skip empty entries
            if entry.isEmpty {
                i += 1
                continue
            }

            // Ordinary changed entry: "1 XY sub mH mI mW hH hI path"
            if entry.hasPrefix("1 ") {
                let parts = entry.split(separator: " ", maxSplits: 8)
                guard parts.count >= 9 else { i += 1; continue }
                let xy = String(parts[1])
                let path = String(parts[8])
                let x = xy.first ?? "."
                let y = xy.last ?? "."

                if x != "." {
                    staged.append(FileChange(
                        path: path, oldPath: nil,
                        status: statusFromChar(x),
                        isStaged: true, isBinary: false
                    ))
                }
                if y != "." {
                    unstaged.append(FileChange(
                        path: path, oldPath: nil,
                        status: statusFromChar(y),
                        isStaged: false, isBinary: false
                    ))
                }
                i += 1
                continue
            }

            // Renamed/copied entry: "2 XY sub mH mI mW hH hI Xscore path\0origPath"
            if entry.hasPrefix("2 ") {
                let parts = entry.split(separator: " ", maxSplits: 9)
                guard parts.count >= 10 else { i += 1; continue }
                let xy = String(parts[1])
                let newPath = String(parts[9])
                let x = xy.first ?? "."
                let y = xy.last ?? "."

                // The original path follows as the next NUL-separated entry
                var origPath: String?
                if i + 1 < entries.count {
                    origPath = String(entries[i + 1])
                    i += 1  // consume the extra entry
                }

                if x != "." {
                    staged.append(FileChange(
                        path: newPath, oldPath: origPath,
                        status: .renamed(from: origPath ?? ""),
                        isStaged: true, isBinary: false
                    ))
                }
                if y != "." {
                    unstaged.append(FileChange(
                        path: newPath, oldPath: origPath,
                        status: statusFromChar(y),
                        isStaged: false, isBinary: false
                    ))
                }
                i += 1
                continue
            }

            // Untracked: "? path"
            if entry.hasPrefix("? ") {
                let path = String(entry.dropFirst(2))
                unstaged.append(FileChange(
                    path: path, oldPath: nil,
                    status: .untracked,
                    isStaged: false, isBinary: false
                ))
                i += 1
                continue
            }

            // Ignored or unmerged — skip for v1
            i += 1
        }

        return GitStatus(branch: branch, staged: staged, unstaged: unstaged, isGitRepo: true)
    }

    private func statusFromChar(_ c: Character) -> FileChangeStatus {
        switch c {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed(from: "")
        default: return .modified
        }
    }

    // MARK: - Diff Parsing

    /// Parse unified diff output into structured FileDiff objects.
    /// Line-oriented state machine matching VS Code / GitHub Desktop pattern.
    func parseDiff(_ raw: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var currentPath: String?
        var currentHunks: [DiffHunk] = []
        var currentIsBinary = false

        // Current hunk state
        var hunkHeader: String?
        var hunkLines: [DiffLine] = []

        func finishHunk() {
            if let header = hunkHeader {
                currentHunks.append(DiffHunk(header: header, lines: hunkLines))
                hunkHeader = nil
                hunkLines = []
            }
        }

        func finishFile() {
            if let path = currentPath {
                finishHunk()
                files.append(FileDiff(path: path, isBinary: currentIsBinary, hunks: currentHunks))
                currentPath = nil
                currentHunks = []
                currentIsBinary = false
            }
        }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in lines {
            // File boundary
            if line.hasPrefix("diff --git ") {
                finishFile()
                // Extract path from "diff --git a/path b/path"
                // Handle paths with spaces by looking for " b/" pattern
                if let bRange = line.range(of: " b/", options: .backwards) {
                    currentPath = String(line[bRange.upperBound...])
                }
                continue
            }

            // Binary detection
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                currentIsBinary = true
                continue
            }

            // Renamed file detection
            if line.hasPrefix("rename to ") {
                currentPath = String(line.dropFirst("rename to ".count))
                continue
            }

            // New file path (overrides the diff --git extraction for new files)
            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst("+++ b/".count))
                continue
            }

            // Deleted file
            if line.hasPrefix("+++ /dev/null") {
                // Keep path from --- line or diff --git
                continue
            }

            // Old file path for deleted files
            if line.hasPrefix("--- a/") {
                // If we haven't set a path yet, use this
                if currentPath == nil {
                    currentPath = String(line.dropFirst("--- a/".count))
                }
                continue
            }

            // Hunk header
            if line.hasPrefix("@@") {
                finishHunk()
                hunkHeader = line
                continue
            }

            // Diff lines (only valid inside a hunk)
            guard hunkHeader != nil else { continue }

            if line.hasPrefix("+") {
                let text = String(line.dropFirst())
                hunkLines.append(DiffLine(kind: .addition, text: text, rawText: line))
            } else if line.hasPrefix("-") {
                let text = String(line.dropFirst())
                hunkLines.append(DiffLine(kind: .deletion, text: text, rawText: line))
            } else if line.hasPrefix(" ") {
                let text = String(line.dropFirst())
                hunkLines.append(DiffLine(kind: .context, text: text, rawText: line))
            } else if line.hasPrefix("\\") {
                hunkLines.append(DiffLine(kind: .noNewline, text: line, rawText: line))
            }
        }

        finishFile()
        return files
    }
}

// MARK: - Errors

enum GitServiceError: LocalizedError {
    case gitError(String)
    case pathOutsideRepo(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .gitError(let msg): return msg
        case .pathOutsideRepo(let path): return "Path is outside the repository: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        }
    }
}
